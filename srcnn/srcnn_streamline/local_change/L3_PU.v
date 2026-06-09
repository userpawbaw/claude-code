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

    // 1. Feature Map Input (From L2 intermid2_3 URAMs, ch??1 URAM)
    // L3_top?�?�? 4 URAM dout(16bit 媛곴�?)????��굹濡??��?���? 64bit packed�???꾨떖.
    // packing ??���?: LSB媛�? ch0 (L2_PU.i_uram_data ?꾩쟾 ??��?�� ?�⑤�???
    input  wire                          i_input_valid,
    input  wire [IN_CH*DATA_BIT-1:0]     i_uram_data,
    input  wire                          i_is_pad_valid,

    // 2. Weight & Bias Input (From FSM & L3 Weight BRAM)
    // L3 weight ???? in_ch(4) * 3x3 * 16bit -> word(64bit)??4ch ??��?��, 1 word/tap
    //   addr 0: w00 w10 w20 w30   (tap 0, in_ch 0~3)
    //   addr 1: w01 w11 w21 w31   (tap 1)
    //   ...
    //   addr 8: w08 w18 w28 w38   (tap 8)
    //   addr 9: b000 0000 0000 0000 (out_ch0 bias, zero packing, MSB ?꾩튂)
    // -> 10 word/iter, out_ch=1????�??iter ??1??(??��?��????��?��)
    input  wire                          i_w_rd_en,
    input  wire [W_BRAM_WIDTH-1:0]       i_weight_bram_data,
    input  wire                          i_bias_en,

    // 3. Status outputs to FSM
    output wire                          o_line_rd_done,
    output wire                          o_pe_done,

    // 4. Final Output (?�???�?�? ?꾩쿂?��? ??��?��??���??? ??�━ URAM ?곌린 ??��?�� 16bit + valid �???꾨떖)
    // ReLU ??��?��. saturation?? ??��?��????�븿 (Q8.8 踰붿?�� 踰�?�뼱??��?�� sat).
    output reg                           o_pixel_valid,
    output reg  [15:0]                   o_pixel_data,
    output wire                          o_img_done
);

    // --------------------------------------------------------
    // per-channel arrays
    // --------------------------------------------------------
    wire [143:0]       w_line_data       [0:IN_CH-1];
    wire               w_line_valid      [0:IN_CH-1];
    wire signed [31:0] w_partial         [0:IN_CH-1];
    wire               w_pe_valid        [0:IN_CH-1];
    wire               w_pe_done         [0:IN_CH-1];
    wire [IN_CH-1:0]   w_line_rd_done_ch;
    wire [IN_CH-1:0]   w_img_done_ch;
    wire               w_line_rd_done = w_line_rd_done_ch[0];
    wire               w_img_done     = w_img_done_ch[0];

    // --------------------------------------------------------
    // Weight Address Generation
    // --------------------------------------------------------
    // L3: 1 word/tap ????�??�??cycle tap_en shift, group_en ?��?�텇 ?꾩슂 ??��?��.
    // 4ch ?�?? 媛숈? tap_en??諛쏆�? ?�?�? lane??weight�??latch.
    // weight_addr 0~8: tap 0~8 / weight_addr 9: bias word (PE??�?�??�� ???? FSM i_bias_en??���? r_bias�??latch)
    reg [3:0]       weight_addr;
    reg [8:0]       r_weight_tap_en;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr     <= 0;
            r_weight_tap_en <= 9'b1;
        end else begin
            if (i_w_rd_en) begin
                weight_addr     <= weight_addr + 1;
                r_weight_tap_en <= r_weight_tap_en << 1; // 9bit????�??tap 8 ??��?�� shift??��?�� ?�?�? ??��?��
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
            // padding mux per channel (FSM pad ?곸뿭?�?�? zero 二쇱?��)
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
                .o_line_rd_done (w_line_rd_done_ch[i]),
                .o_img_done     (w_img_done_ch[i])
            );

            pe_group pe_inst (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_line_valid   (w_line_valid[i]),
                .i_line_data    (w_line_data[i]),
                .i_weight       (i_weight_bram_data[16*i +: 16]), // �?꾨꼸�???�좎?�� lane
                .i_w_tap_en     (r_weight_tap_en),                  // 4ch ?�듯?��
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
    // [3] Channel Integration Adder Tree (4ch -> 1, 2 stage)
    // --------------------------------------------------------
    reg signed [31:0] r_add_stage1 [0:1];
    reg signed [31:0] r_add_stage2;
    reg               r_valid_stage1, r_valid_stage2;

    always @(posedge i_clk) begin
        r_add_stage1[0] <= $signed(w_partial[0]) + $signed(w_partial[1]);
        r_add_stage1[1] <= $signed(w_partial[2]) + $signed(w_partial[3]);
        r_valid_stage1  <= w_pe_valid[0];

        r_add_stage2    <= $signed(r_add_stage1[0]) + $signed(r_add_stage1[1]);
        r_valid_stage2  <= r_valid_stage1;
    end

    // --------------------------------------------------------
    // [4] Bias Latch & Saturation Truncate (no ReLU)
    // --------------------------------------------------------
    // bias ?꾩튂: L2_PU?? ??��?��??���? MSB 16bit (i_weight_bram_data[63 -: DATA_BIT])
    // sum -> Q8.8 window {sign[31], [22:8]} ?��붿텧. ?????묒そ ??���???���???sat.
    reg signed [15:0] r_bias;
    wire signed [31:0] w_final_sum_q8_8 = ( $signed(r_add_stage2)>>>8 ) + $signed(r_bias);

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias        <= 0;
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            if (i_bias_en) r_bias <= i_weight_bram_data[63 -: DATA_BIT];

            o_pixel_valid <= r_valid_stage2;

            if (w_final_sum_q8_8 > 32'sd32767) begin
                o_pixel_data <= 16'h7FFF;
            end else if (w_final_sum_q8_8 < -32'sd32768) begin
                o_pixel_data <= 16'h8000;
            end else begin
                o_pixel_data <= w_final_sum_q8_8[15:0];
            end
        end
    end

    // --------------------------------------------------------
    // [5] img_done propagation (for FSM i_adder_done)
    //  pipeline: pe_group 3 + adder tree 2 + bias+output 2 = 7clk
    // --------------------------------------------------------
    delay_shift #(
        .DELAY(3+2+1)
    ) d_l3_img_done (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(w_img_done),
        .dout(o_img_done)
    );

endmodule

