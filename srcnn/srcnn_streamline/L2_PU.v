`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// L2 PU (refactored)
//   - FSM_pad 인스턴스 제거 (이제 L2_top이 instantiate)
//   - i_is_pad_valid를 외부에서 받아 내부 padding mux 구동
//   - o_line_rd_done, o_pe_done을 FSM으로 전달하기 위해 노출
//   - bias latch: 외부 i_bias_en 사용 (FSM의 o_bias_en 출력)
//   - ReLU saturation: 16'h7FFF 적용 (이전 16'h8FFF은 2's complement으로 음수이므로 수정)
// -----------------------------------------------------------------------------

module L2_PU #(
    parameter IN_CH        = 8,
    parameter W_PIXEL_NUM  = 4,
    parameter DATA_BIT     = 16,
    parameter W_BRAM_WIDTH = W_PIXEL_NUM * DATA_BIT
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_IDLE_rst,

    // 1. Feature Map Input (from L2_top: URAM read data, 128-bit packed 8ch)
    input  wire                          i_input_valid,
    input  wire [IN_CH*DATA_BIT-1:0]     i_uram_data,
    input  wire                          i_is_pad_valid, // FSM의 o_is_pad_valid 연결

    // 2. Weight & Bias Input (from L2_local_FSM + Weight BRAM)
    input  wire                          i_w_rd_en,         // 1clk-delayed weight valid (= o_weight_bram_rd_en delayed)
    input  wire [W_BRAM_WIDTH-1:0]       i_weight_bram_data,
    input  wire                          i_bias_en,         // FSM o_bias_en (1clk-delayed bias word indicator)

    // 3. Status outputs to FSM
    output wire                          o_line_rd_done,
    output wire                          o_pe_done,

    // 4. Final Output (to L2_top → intermid2_3 URAM)
    output reg                           o_pixel_valid,
    output reg  [15:0]                   o_pixel_data,
    output wire                          o_img_done
);

    // --- per-channel arrays ---
    wire [143:0]       w_line_data  [0:IN_CH-1];
    wire               w_line_valid [0:IN_CH-1];
    wire signed [20:0] w_partial    [0:IN_CH-1];
    wire               w_pe_valid   [0:IN_CH-1];
    wire               w_pe_done    [0:IN_CH-1];
    wire               w_line_rd_done;
    wire               w_img_done;

    // =========================================================================
    // Weight Address Generation
    //   - i_w_rd_en이 유지되는 동안 구간 카운터로 PE 슬롯 제어
    // =========================================================================
    reg [5:0]       weight_addr;
    reg [IN_CH-1:0] r_weight_group_en;
    reg [8:0]       r_weight_tap_en;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr         <= 0;
            r_weight_group_en   <= 0;
            r_weight_tap_en     <= 9'b1;
        end else begin
            if (i_w_rd_en) begin
                weight_addr         <= weight_addr + 1;
                r_weight_group_en   <= { {4{weight_addr[0]}} , {4{~weight_addr[0]}} };
                r_weight_tap_en     <= weight_addr[0] ? (r_weight_tap_en << 1) : r_weight_tap_en;
            end else begin
                weight_addr         <= 0;
                r_weight_group_en   <= 0;
                r_weight_tap_en     <= 9'b1;
            end
        end
    end

    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_ch
            // padding mux per channel (패딩 영역에서 채널별로 zero 주입)
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
                .i_weight       (i_weight_bram_data[16*(i[1:0]) +: 16]),
                .i_w_tap_en     ({9{r_weight_group_en[i]}} & r_weight_tap_en),
                .i_line_done    (w_line_rd_done),
                .o_valid        (w_pe_valid[i]),
                .o_partial      (w_partial[i]),
                .o_pe_done      (w_pe_done[i])
            );
        end
    endgenerate

    // Status outputs (all channels aligned -> use ch0)
    assign o_line_rd_done = w_line_rd_done;
    assign o_pe_done      = w_pe_done[0];

    // =========================================================================
    // [3] Channel Integration Adder Tree (공간 병렬 8채널 합산)
    // =========================================================================
    reg signed [22:0] r_add_stage1 [0:3];
    reg signed [23:0] r_add_stage2 [0:1];
    reg signed [24:0] r_add_stage3;
    reg               r_valid_stage1, r_valid_stage2, r_valid_stage3;

    always @(posedge i_clk) begin
        r_add_stage1[0] <= w_partial[0] + w_partial[1];
        r_add_stage1[1] <= w_partial[2] + w_partial[3];
        r_add_stage1[2] <= w_partial[4] + w_partial[5];
        r_add_stage1[3] <= w_partial[6] + w_partial[7];
        r_valid_stage1  <= w_pe_valid[0];

        r_add_stage2[0] <= r_add_stage1[0] + r_add_stage1[1];
        r_add_stage2[1] <= r_add_stage1[2] + r_add_stage1[3];
        r_valid_stage2  <= r_valid_stage1;

        r_add_stage3    <= r_add_stage2[0] + r_add_stage2[1];
        r_valid_stage3  <= r_valid_stage2;
    end

    // =========================================================================
    // [4] Bias Latch & ReLU + Saturation Pipeline
    // =========================================================================
    reg signed [15:0] r_bias;
    reg signed [31:0] r_final_sum;
    reg               r_final_valid;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias        <= 0;
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            if (i_bias_en) r_bias <= i_weight_bram_data[63 -: DATA_BIT];

            r_final_sum   <= r_add_stage3 + r_bias;
            r_final_valid <= r_valid_stage3;

            o_pixel_valid <= r_final_valid;

            // ReLU + Q8.8 saturation (이전 16'h8FFF 좌측 타임 → 16'h7FFF로 수정)
            if (r_final_sum[31]) begin
                o_pixel_data <= 16'd0;
            end else begin
                o_pixel_data <= (r_final_sum[24] == 1'b1) ? 16'h7FFF : {r_final_sum[31], r_final_sum[22:8]};
            end
        end
    end

    // =========================================================================
    // [5] img_done propagation (for FSM)
    // =========================================================================
    delay_shift #(
        .DELAY(3+3+2)
    ) d3_line_buff_done_to_PU (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(w_img_done),
        .dout(o_img_done)
    );

endmodule
