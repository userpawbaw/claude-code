`timescale 1ns / 1ps
// L2_PU : 4 in_ch -> 2 out_ch (out_ch 시분할).
//   - 4 line_buffer + 4 pe_group + 4-way adder tree.
//   - bias addr 28 (out_ch_cnt=0 pass 의 마지막 weight word 직후) 에서 한 번에 두 oc bias latch.
//   - i_out_ch_cnt 로 active bias 선택.
//   - ReLU 적용. 출력 16-bit per pixel.
module L2_PU #(
    parameter IN_CH = 4
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_dispatch_rst,

    // 4 in_ch packed input from FIFOs
    input  wire                       i_ch_valid,
    input  wire [IN_CH*16-1:0]        i_ch_data,
    input  wire                       i_is_pad_valid,   // padding cycle

    // weight / bias from BRAM
    input  wire                       i_w_rd_valid,
    input  wire                       i_bias_en,
    input  wire [63:0]                i_w_word,

    // active out_ch (0/1) — bias 선택
    input  wire                       i_out_ch_cnt,

    // output
    output reg                        o_pixel_valid,
    output reg  signed [15:0]         o_pixel_data,
    output wire                       o_img_done
);
    // ------------------------------------------------------------------
    // weight tap counter -> 9-bit one-hot (sub_max=1)
    // ------------------------------------------------------------------
    reg [3:0] tap_cnt;
    wire [8:0] tap_en =
        (i_w_rd_valid && !i_bias_en && tap_cnt < 4'd9) ? (9'd1 << tap_cnt) : 9'd0;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)             tap_cnt <= 0;
        else if (i_dispatch_rst) tap_cnt <= 0;
        else if (i_w_rd_valid && !i_bias_en && tap_cnt < 4'd9)
            tap_cnt <= tap_cnt + 4'd1;
    end

    // ------------------------------------------------------------------
    // bias latch (2 oc)
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias [0:1];
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias[0] <= 0;
            r_bias[1] <= 0;
        end else if (i_bias_en) begin
            r_bias[0] <= i_w_word[48 +: 16];   // [63:48]
            r_bias[1] <= i_w_word[32 +: 16];   // [47:32]
        end
    end
    wire signed [15:0] w_active_bias = r_bias[i_out_ch_cnt];

    // ------------------------------------------------------------------
    // 4-channel line buffers + PE groups
    // ------------------------------------------------------------------
    wire [16*9-1:0]    w_line_data  [0:IN_CH-1];
    wire               w_line_valid [0:IN_CH-1];
    wire               w_line_img_done [0:IN_CH-1];
    wire               w_line_rd_done  [0:IN_CH-1];

    wire               w_pe_valid [0:IN_CH-1];
    wire signed [20:0] w_partial  [0:IN_CH-1];
    wire               w_pe_done  [0:IN_CH-1];

    genvar g;
    generate
        for (g = 0; g < IN_CH; g = g + 1) begin : gen_ch
            // padding mux
            wire signed [15:0] w_ch_data  = i_is_pad_valid ? 16'sd0 :
                                             $signed(i_ch_data[16*((IN_CH-1)-g) +: 16]);
            wire               w_ch_valid = i_is_pad_valid ? 1'b1 : i_ch_valid;

            line_buffer_improved #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(3), .DATA_BIT(16)
            ) u_lb (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (w_ch_valid),
                .i_input_data   (w_ch_data),
                .o_line_data    (w_line_data[g]),
                .o_line_valid   (w_line_valid[g]),
                .o_line_rd_done (w_line_rd_done[g]),
                .o_img_done     (w_line_img_done[g])
            );

            pe_group u_pe (
                .i_clk           (i_clk),
                .i_rstn          (i_rstn),
                .i_line_valid    (w_line_valid[g]),
                .i_line_data     (w_line_data[g]),
                .i_weight        (i_w_word[48 - 16*g +: 16]),
                .i_w_tap_en      (tap_en),
                .i_line_img_done (w_line_img_done[g]),
                .o_valid         (w_pe_valid[g]),
                .o_partial       (w_partial[g]),
                .o_pe_done       (w_pe_done[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 4-way adder tree (1 stage) + bias + ReLU
    //   stage1 = (p0+p1)+(p2+p3)  -> 23bit
    //   + bias                     -> 24bit
    //   refine = {sign, [14:0]}, ReLU = (sign?0:refined)
    // ------------------------------------------------------------------
    reg  signed [21:0] r_sum_pair_a, r_sum_pair_b;
    reg                r_valid_s1;
    reg  signed [22:0] r_sum_total;
    reg                r_valid_s2;
    reg  signed [23:0] r_sum_biased;
    reg                r_valid_s3;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_sum_pair_a <= 0;
            r_sum_pair_b <= 0;
            r_sum_total  <= 0;
            r_sum_biased <= 0;
            r_valid_s1   <= 0;
            r_valid_s2   <= 0;
            r_valid_s3   <= 0;
        end else begin
            r_sum_pair_a <= w_partial[0] + w_partial[1];
            r_sum_pair_b <= w_partial[2] + w_partial[3];
            r_valid_s1   <= w_pe_valid[0];

            r_sum_total  <= r_sum_pair_a + r_sum_pair_b;
            r_valid_s2   <= r_valid_s1;

            r_sum_biased <= r_sum_total + $signed({{8{w_active_bias[15]}}, w_active_bias});
            r_valid_s3   <= r_valid_s2;
        end
    end

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            o_pixel_valid <= r_valid_s3;
            // ReLU + refine
            if (r_sum_biased[23]) o_pixel_data <= 16'sd0;
            else                  o_pixel_data <= {r_sum_biased[23], r_sum_biased[14:0]};
        end
    end

    // o_img_done : pe_done + 3 추가 단 (adder + bias + final)
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0]),
        .dout (o_img_done)
    );
endmodule
