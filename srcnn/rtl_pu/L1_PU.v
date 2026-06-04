`timescale 1ns / 1ps
// L1_PU : 1 in_ch -> 4 out_ch.
//   - 1 line_buffer + 4 pe_group (각 oc).
//   - bias 는 weight BRAM 의 10번째 word(addr 9) = [b0,b1,b2,b3] 에서 latch.
//   - ReLU 적용 (음수 -> 0).
//   - 출력: 4 oc 픽셀을 64-bit packed (oc0=[63:48], oc1=[47:32], oc2=[31:16], oc3=[15:0]).
module L1_PU #(
    parameter OUT_CH = 4
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,

    // pixel input (1 in_ch)
    input  wire                       i_input_valid,
    input  wire signed [15:0]         i_pixel_data,

    // weight / bias from BRAM (64-bit word)
    input  wire                       i_w_rd_valid,    // BRAM rd_valid (1clk after rd_en)
    input  wire                       i_bias_en,       // 1-clk pulse at bias word
    input  wire [63:0]                i_w_word,
    input  wire                       i_dispatch_rst,  // out_ch/layer 전환 시 tap_cnt 초기화

    // output (4 oc packed)
    output reg                        o_pixel_valid,
    output reg  [OUT_CH*16-1:0]       o_pixel_data,
    output wire                       o_img_done       // pipeline-aligned with last o_pixel_valid
);
    // ------------------------------------------------------------------
    // weight tap counter -> 9-bit one-hot
    // ------------------------------------------------------------------
    reg [3:0] tap_cnt;
    wire [8:0] tap_en =
        (i_w_rd_valid && !i_bias_en && tap_cnt < 4'd9) ? (9'd1 << tap_cnt) : 9'd0;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)            tap_cnt <= 0;
        else if (i_dispatch_rst) tap_cnt <= 0;
        else if (i_w_rd_valid && !i_bias_en && tap_cnt < 4'd9)
            tap_cnt <= tap_cnt + 4'd1;
    end

    // ------------------------------------------------------------------
    // bias latch (4 oc)
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias [0:OUT_CH-1];
    integer ii;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (ii = 0; ii < OUT_CH; ii = ii + 1) r_bias[ii] <= 0;
        end else if (i_bias_en) begin
            for (ii = 0; ii < OUT_CH; ii = ii + 1)
                r_bias[ii] <= i_w_word[48 - 16*ii +: 16];
        end
    end

    // ------------------------------------------------------------------
    // line_buffer (단일 in_ch)
    // ------------------------------------------------------------------
    wire [16*9-1:0]    w_line_data;
    wire               w_line_valid;
    wire               w_line_rd_done;
    wire               w_line_img_done;
    line_buffer_improved #(
        .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(3), .DATA_BIT(16)
    ) u_lb (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (i_IDLE_rst),
        .i_input_valid  (i_input_valid),
        .i_input_data   (i_pixel_data),
        .o_line_data    (w_line_data),
        .o_line_valid   (w_line_valid),
        .o_line_rd_done (w_line_rd_done),
        .o_img_done     (w_line_img_done)
    );

    // ------------------------------------------------------------------
    // 4 PE groups (one per oc)
    // ------------------------------------------------------------------
    wire               w_pe_valid [0:OUT_CH-1];
    wire signed [20:0] w_partial  [0:OUT_CH-1];
    wire               w_pe_done  [0:OUT_CH-1];

    genvar g;
    generate
        for (g = 0; g < OUT_CH; g = g + 1) begin : gen_pe
            pe_group u_pe (
                .i_clk           (i_clk),
                .i_rstn          (i_rstn),
                .i_line_valid    (w_line_valid),
                .i_line_data     (w_line_data),
                .i_weight        (i_w_word[48 - 16*g +: 16]),
                .i_w_tap_en      (tap_en),
                .i_line_img_done (w_line_img_done),
                .o_valid         (w_pe_valid[g]),
                .o_partial       (w_partial[g]),
                .o_pe_done       (w_pe_done[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // bias add + ReLU + Q7.8 refine (4 oc 병렬)
    // ------------------------------------------------------------------
    generate
        for (g = 0; g < OUT_CH; g = g + 1) begin : gen_refine
            wire signed [21:0] w_sum = $signed({{1{w_partial[g][20]}}, w_partial[g]}) + $signed({{6{r_bias[g][15]}}, r_bias[g]});
            wire signed [15:0] w_refined = {w_sum[21], w_sum[14:0]};
            wire               w_neg = w_sum[21];  // sign

            always @(posedge i_clk or negedge i_rstn) begin
                if (~i_rstn) begin
                    o_pixel_data[16*((OUT_CH-1)-g) +: 16] <= 16'sd0;
                end else begin
                    // ReLU
                    o_pixel_data[16*((OUT_CH-1)-g) +: 16] <= w_neg ? 16'sd0 : w_refined;
                end
            end
        end
    endgenerate

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) o_pixel_valid <= 1'b0;
        else         o_pixel_valid <= w_pe_valid[0];
    end

    assign o_img_done = w_pe_done[0];   // 모든 채널 동일
endmodule
