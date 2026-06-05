`timescale 1ns / 1ps

module L3_PU #(
    parameter IN_CH        = 4,
    parameter W_PIXEL_NUM  = 4,
    parameter DATA_BIT     = 16,
    parameter W_BRAM_WIDTH = W_PIXEL_NUM * DATA_BIT  // 64bit (4 * 16)
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_IDLE_rst,

    // 1. Feature Map Input (From L2 intermid2_3 URAMs, ch당 1 URAM)
    // L3_top에서 4 URAM dout(16bit 각각)을 하나로 묶어 64bit packed로 전달.
    // packing 순서: LSB가 ch0 (L2_PU.i_uram_data 완전 동일 컨벤션)
    input  wire                          i_input_valid,
    input  wire [IN_CH*DATA_BIT-1:0]     i_uram_data,
    input  wire                          i_is_pad_valid,

    // 2. Weight & Bias Input (From FSM & L3 Weight BRAM)
    // L3 weight 저장: in_ch(4) * 3x3 * 16bit -> word(64bit)당 4ch 동시, 1 word/tap
    //   addr 0: w00 w10 w20 w30   (tap 0, in_ch 0~3)
    //   addr 1: w01 w11 w21 w31   (tap 1)
    //   ...
    //   addr 8: w08 w18 w28 w38   (tap 8)
    //   addr 9: b000 0000 0000 0000 (out_ch0 bias, zero packing, MSB 위치)
    // -> 10 word/iter, out_ch=1이므로 iter 단 1회 (시분할 없음)
    input  wire                          i_w_rd_en,
    input  wire [W_BRAM_WIDTH-1:0]       i_weight_bram_data,
    input  wire                          i_bias_en,

    // 3. Status outputs to FSM
    output wire                          o_line_rd_done,
    output wire                          o_pe_done,

    // 4. Final Output (외부에서 후처리. 앞레이어와 달리 URAM 쓰기 없이 16bit + valid 만 전달)
    // ReLU 없음. saturation은 안전상 포함 (Q8.8 범위 벗어나면 sat).
    output reg                           o_pixel_valid,
    output reg  [15:0]                   o_pixel_data,
    output wire                          o_img_done
);

    // --------------------------------------------------------
    // per-channel arrays
    // --------------------------------------------------------
    wire [143:0]       w_line_data  [0:IN_CH-1];
    wire               w_line_valid [0:IN_CH-1];
    wire signed [35:0] w_partial    [0:IN_CH-1];   // ★ Q16.16 (36-bit)
    wire               w_pe_valid   [0:IN_CH-1];
    wire               w_pe_done    [0:IN_CH-1];
    wire               w_line_rd_done;
    wire               w_img_done;

    // --------------------------------------------------------
    // Weight Address Generation
    // --------------------------------------------------------
    // L3: 1 word/tap 이므로 매 cycle tap_en shift, group_en 구분 필요 없음.
    // 4ch 전부 같은 tap_en을 받아 자기 lane의 weight만 latch.
    // weight_addr 0~8: tap 0~8 / weight_addr 9: bias word (PE는 캐치 안 함, FSM i_bias_en으로 r_bias만 latch)
    reg [3:0]       weight_addr;
    reg [8:0]       r_weight_tap_en;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr     <= 0;
            r_weight_tap_en <= 9'b1;
        end else begin
            if (i_w_rd_en) begin
                weight_addr     <= weight_addr + 1;
                r_weight_tap_en <= r_weight_tap_en << 1; // 9bit이므로 tap 8 다음 shift하면 자연 소멸
            end else begin
                weight_addr     <= 0;
                r_weight_tap_en <= 9'b1;
            end
        end
    end

    // --------------------------------------------------------
    // 4-Channel Line Buffers & PE Groups Generate
    // --------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_ch
            // padding mux per channel (FSM pad 영역에서 zero 주입)
            wire signed [15:0] w_lb_data;
            wire               w_lb_valid;
            assign w_lb_data  = i_is_pad_valid ? 16'h0 : i_uram_data[16*i +: 16];
            assign w_lb_valid = i_is_pad_valid ? 1'b1 : i_input_valid;

            line_buffer_improved #(
                .IMG_WIDTH(152),
                .WIN_ROW(3),
                .WIN_COL(3),
                .DATA_BIT(16)
            ) u_line_buffer (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (w_lb_valid),
                .i_input_data   (w_lb_data),
                .o_line_data    (w_line_data[i]),
                .o_line_valid   (w_line_valid[i]),
                .o_line_rd_done (w_line_rd_done),
                .o_img_done     (w_img_done)
            );

            pe_group pe_inst (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_line_valid   (w_line_valid[i]),
                .i_line_data    (w_line_data[i]),
                .i_weight       (i_weight_bram_data[16*i +: 16]), // 채널별 고정 lane
                .i_w_tap_en     (r_weight_tap_en),                  // 4ch 공통
                .i_line_done    (w_line_rd_done),
                .o_valid        (w_pe_valid[i]),
                .o_partial      (w_partial[i]),
                .o_pe_done      (w_pe_done[i])
            );
        end
    endgenerate

    assign o_line_rd_done = w_line_rd_done;
    assign o_pe_done      = w_pe_done[0];

    // --------------------------------------------------------
    // [3] Channel Integration Adder Tree (4ch -> 1, 2 stage, Q16.16)
    //     stage1 : pair sum 2 × 37-bit
    //     stage2 : sum     1 × 38-bit Q16.16
    // --------------------------------------------------------
    reg signed [36:0] r_add_stage1 [0:1];
    reg signed [37:0] r_add_stage2;
    reg               r_valid_stage1, r_valid_stage2;

    always @(posedge i_clk) begin
        r_add_stage1[0] <= {w_partial[0][35], w_partial[0]} + {w_partial[1][35], w_partial[1]};
        r_add_stage1[1] <= {w_partial[2][35], w_partial[2]} + {w_partial[3][35], w_partial[3]};
        r_valid_stage1  <= w_pe_valid[0];

        r_add_stage2    <= {r_add_stage1[0][36], r_add_stage1[0]} + {r_add_stage1[1][36], r_add_stage1[1]};
        r_valid_stage2  <= r_valid_stage1;
    end

    // --------------------------------------------------------
    // [4] (>>>8) + bias(Q8.8) → bidirectional saturate (no ReLU)
    //   README spec : (sum_q1616 >>> 8) + sext(bias_q88) → sat_bidir
    //   r_add_stage2 (38-bit) >>> 8 = 30-bit Q8.8 → sext to 32-bit → +bias_q88
    // --------------------------------------------------------
    function automatic [15:0] sat_bidir(input signed [31:0] v);
        if      (~v[31] &&  (|v[30:15])) sat_bidir = 16'h7FFF;
        else if ( v[31] && ~(&v[30:15])) sat_bidir = 16'h8000;
        else                             sat_bidir = v[15:0];
    endfunction

    reg signed [15:0] r_bias;
    reg signed [31:0] r_sum_q88;
    reg               r_final_valid;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias        <= 0;
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
            r_sum_q88     <= 0;
            r_final_valid <= 0;
        end else begin
            if (i_bias_en) r_bias <= i_weight_bram_data[63 -: DATA_BIT];

            // 38-bit Q16.16 >>>8 → take low 32 bits as Q8.8 sext + bias
            r_sum_q88     <= $signed(r_add_stage2[37:8])
                           + {{16{r_bias[15]}}, r_bias};
            r_final_valid <= r_valid_stage2;

            o_pixel_valid <= r_final_valid;
            o_pixel_data  <= sat_bidir(r_sum_q88);
        end
    end

    // --------------------------------------------------------
    // [5] img_done propagation (for FSM i_adder_done)
    //  pipeline: pe_group 3 + adder tree 2 + bias+output 2 = 7clk
    // --------------------------------------------------------
    delay_shift #(
        .DELAY(3+2+2)
    ) d_l3_img_done (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(w_img_done),
        .dout(o_img_done)
    );

endmodule
