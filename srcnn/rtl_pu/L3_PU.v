`timescale 1ns / 1ps
// L3_PU : 2 in_ch -> 1 out_ch. NO ReLU (마지막 layer).
//   - 2 line_buffer + 2 pe_group (각 ic).
//   - weight 는 sub_max=2 (word 당 2 sub-slot: ic0 의 tap 2k/2k+1, ic1 의 tap 2k/2k+1).
//   - bias addr 34 (5 weight word 후) word=[b,0,0,0] 에서 latch.
//   - 출력: refine16 ({sign, [14:0]}).
module L3_PU #(
    parameter IN_CH = 2
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_dispatch_rst,

    input  wire                       i_ch_valid,
    input  wire [IN_CH*16-1:0]        i_ch_data,
    input  wire                       i_is_pad_valid,

    input  wire                       i_w_rd_valid,
    input  wire                       i_bias_en,
    input  wire [63:0]                i_w_word,

    output reg                        o_pixel_valid,
    output reg  signed [15:0]         o_pixel_data,
    output wire                       o_img_done
);
    // ------------------------------------------------------------------
    // bias latch (1 oc)
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)        r_bias <= 0;
        else if (i_bias_en) r_bias <= i_w_word[48 +: 16];   // [63:48]
    end

    // ------------------------------------------------------------------
    // weight dispatch (sub_max=2)
    //   word_k = [ic0_t2k][ic0_t2k+1][ic1_t2k][ic1_t2k+1]
    //   cycle 0 (sub0): tap = 2k.    g0<=slot0, g1<=slot2.
    //   cycle 1 (sub1): tap = 2k+1.  g0<=slot1, g1<=slot3.
    // ------------------------------------------------------------------
    reg [3:0] tap_cnt;     // 0..9 (9 = done)
    reg       sub_state;   // 0 = expect new word (sub0), 1 = serving sub1
    reg [63:0] r_word_lat;
    reg [8:0] tap_en;
    reg signed [15:0] w_g0, w_g1;

    wire w_can_sub0 = (i_w_rd_valid && !i_bias_en) && (tap_cnt < 4'd9);
    wire w_can_sub1 = (sub_state == 1'b1)          && (tap_cnt < 4'd9);

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            tap_cnt    <= 0;
            sub_state  <= 0;
            r_word_lat <= 0;
            tap_en     <= 9'd0;
            w_g0       <= 0;
            w_g1       <= 0;
        end else if (i_dispatch_rst) begin
            tap_cnt    <= 0;
            sub_state  <= 0;
            r_word_lat <= 0;
            tap_en     <= 9'd0;
            w_g0       <= 0;
            w_g1       <= 0;
        end else begin
            tap_en <= 9'd0;
            if (w_can_sub0) begin
                tap_en     <= (9'd1 << tap_cnt);
                tap_cnt    <= tap_cnt + 4'd1;
                r_word_lat <= i_w_word;
                sub_state  <= 1'b1;
                w_g0       <= i_w_word[48 +: 16];   // [63:48]
                w_g1       <= i_w_word[16 +: 16];   // [31:16]
            end else if (w_can_sub1) begin
                tap_en    <= (9'd1 << tap_cnt);
                tap_cnt   <= tap_cnt + 4'd1;
                sub_state <= 1'b0;
                w_g0      <= r_word_lat[32 +: 16];  // [47:32]
                w_g1      <= r_word_lat[0  +: 16];  // [15:0]
            end else begin
                sub_state <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 2-channel line buffers + PE groups
    // ------------------------------------------------------------------
    wire [16*9-1:0]    w_line_data  [0:IN_CH-1];
    wire               w_line_valid [0:IN_CH-1];
    wire               w_line_img_done [0:IN_CH-1];
    wire               w_line_rd_done  [0:IN_CH-1];

    wire               w_pe_valid [0:IN_CH-1];
    wire signed [20:0] w_partial  [0:IN_CH-1];
    wire               w_pe_done  [0:IN_CH-1];

    wire signed [15:0] w_g_bus [0:IN_CH-1];
    assign w_g_bus[0] = w_g0;
    assign w_g_bus[1] = w_g1;

    genvar g;
    generate
        for (g = 0; g < IN_CH; g = g + 1) begin : gen_ch
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
                .i_weight        (w_g_bus[g]),
                .i_w_tap_en      (tap_en),
                .i_line_img_done (w_line_img_done[g]),
                .o_valid         (w_pe_valid[g]),
                .o_partial       (w_partial[g]),
                .o_pe_done       (w_pe_done[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 2-way sum + bias + refine (NO ReLU)
    // ------------------------------------------------------------------
    reg  signed [21:0] r_sum_total;
    reg                r_valid_s1;
    reg  signed [22:0] r_sum_biased;
    reg                r_valid_s2;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_sum_total  <= 0;
            r_sum_biased <= 0;
            r_valid_s1   <= 0;
            r_valid_s2   <= 0;
        end else begin
            r_sum_total <= w_partial[0] + w_partial[1];
            r_valid_s1  <= w_pe_valid[0];

            r_sum_biased <= r_sum_total + $signed({{7{r_bias[15]}}, r_bias});
            r_valid_s2   <= r_valid_s1;
        end
    end

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            o_pixel_valid <= r_valid_s2;
            o_pixel_data  <= {r_sum_biased[22], r_sum_biased[14:0]};  // refine16
        end
    end

    delay_shift #(.DELAY(2)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0]),
        .dout (o_img_done)
    );
endmodule
