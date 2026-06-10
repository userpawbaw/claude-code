`timescale 1ns / 1ps
// PU (preset 4_2 UNROLL) : 8x8 pe_group grid shared across L1, L2, L3.
//
// Channel config: L1 1->4, L2 4->2, L3 2->1.
//
// pe_group grid layout per layer (g = row index 0..7, k = lane index 0..7):
//   L1 : row g=0..3 → out_ch 0..3 (single in_ch, broadcast). row g=4..7 unused.
//   L2 : row g=0..3 → out_ch=0 with in_ch=g.
//        row g=4..7 → out_ch=1 with in_ch=(g-4).  All 8 rows active.
//   L3 : row g=0..1 → in_ch 0..1 (summed in Stage 1). row g=2..7 unused.
//
// Total PE instances: 8 × 8 × 9 = 576.
//
// Input routing (done in top.v before arriving here):
//   i_uram_data_wide [MAX_CH*128-1:0] : slot 0 = MSB. slot index = g.
//     L1 : slot 0 carries the input pixel, broadcast to all line buffers.
//     L2 : slot 0..3 = in_ch 0..3 (same data replicated to slots 4..7 by top.v).
//   i_uram_data_l3 [MAX_CH*64-1:0] : slot 0..1 = in_ch 0..1 (4 px per slot).
//
// Weight BRAM slot mapping (slot 0 = MSB of 128-bit word):
//   L1 tap n : slot 0..3 = W1[oc=0..3, tap=n].  slot 4..7 = 0 (zero-padded).
//   L2 tap n : slot 0..3 = W2[oc=0, ic=0..3, n]. slot 4..7 = W2[oc=1, ic=0..3, n].
//   L3 tap n : slot 0..1 = W3[ic=0..1, tap=n].   slot 2..7 = 0 (zero-padded).
//   PU uses w_weight[g] = slot g, so the mapping matches naturally.
//
// Output:
//   o_oc_valid_mask : L1=8'b00001111 (4 oc), L2=8'b00000011 (2 oc), L3=8'b00000001.
//
// Pipeline: line_buffer 2 clk + pe_group 3 clk + Stage 1/2/3 3 clk = 8 clk total.

module PU #(
    parameter MAX_CH     = 8,
    parameter LANES_WIDE = 8,
    parameter LANES_L3   = 4,
    parameter WIDE_BITS  = 128,   // 8 px × 16 bit (L1/L2)
    parameter L3_BITS    = 64     // 4 px × 16 bit (L3)
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_IDLE_rst,
    input  wire                          i_dispatch_rst,

    input  wire [1:0]                    i_layer_cnt,
    input  wire [2:0]                    i_out_ch_cnt,

    input  wire                          i_input_valid,
    input  wire [MAX_CH*WIDE_BITS-1:0]   i_uram_data_wide,
    input  wire [MAX_CH*L3_BITS-1:0]     i_uram_data_l3,

    input  wire                          i_w_rd_en,
    input  wire [MAX_CH*16-1:0]          i_weight_bram_data,
    input  wire                          i_bias_en,

    output reg                           o_emit_valid,
    output reg  [MAX_CH-1:0]             o_oc_valid_mask,
    output reg  [MAX_CH*LANES_WIDE-1:0]  o_lane_valid_mask,
    output reg  [MAX_CH*LANES_WIDE*16-1:0] o_pixel_data,
    output wire                          o_img_done
);
    localparam WIN_BITS_WIDE = 10*16;   // 160 b per row
    localparam WIN_BITS_L3   = 6*16;    // 96 b per row
    localparam WIN_SIZE_WIDE = 3*WIN_BITS_WIDE;  // 480
    localparam WIN_SIZE_L3   = 3*WIN_BITS_L3;    // 288

    wire w_is_L1 = (i_layer_cnt == 2'd0);
    wire w_is_L2 = (i_layer_cnt == 2'd1);
    wire w_is_L3 = (i_layer_cnt == 2'd2);

    // ------------------------------------------------------------------
    // Weight tap dispatcher: 9 taps + 1 bias, 1-hot enable per tap.
    // ------------------------------------------------------------------
    reg [3:0]  r_tap_cnt;
    wire [8:0] w_tap_en =
        (i_w_rd_en && !i_bias_en && (r_tap_cnt < 4'd9)) ? (9'd1 << r_tap_cnt) : 9'd0;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)              r_tap_cnt <= 0;
        else if (i_dispatch_rst)  r_tap_cnt <= 0;
        else if (i_w_rd_en && !i_bias_en && (r_tap_cnt < 4'd9))
            r_tap_cnt <= r_tap_cnt + 4'd1;
    end

    // Per-row weight slot: slot 0 = MSB of 128-bit word, slot g at bits [(MAX_CH-1-g)*16 +: 16].
    wire signed [15:0] w_weight [0:MAX_CH-1];
    genvar gw;
    generate
        for (gw = 0; gw < MAX_CH; gw = gw + 1) begin : gen_w_slot
            assign w_weight[gw] = i_weight_bram_data[16*((MAX_CH-1)-gw) +: 16];
        end
    endgenerate

    // ------------------------------------------------------------------
    // Bias latch: 8 slots, loaded from weight BRAM bias word.
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias [0:MAX_CH-1];
    integer bi;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (bi = 0; bi < MAX_CH; bi = bi + 1) r_bias[bi] <= 0;
        end else if (i_bias_en) begin
            for (bi = 0; bi < MAX_CH; bi = bi + 1)
                r_bias[bi] <= i_weight_bram_data[16*((MAX_CH-1)-bi) +: 16];
        end
    end

    // L2 has 2 out_ch → bias slot 0 for oc=0, slot 1 for oc=1.
    wire signed [15:0] w_bias_L2_oc0 = r_bias[0];
    wire signed [15:0] w_bias_L2_oc1 = r_bias[1];

    // ------------------------------------------------------------------
    // Per-channel input mux + line buffers.
    //   L1 : slot 0 of i_uram_data_wide broadcast to all 8 line_buffer_wide.
    //   L2 : g=0..3 → in_ch g.  g=4..7 → in_ch (g-4), replicating for oc=1 rows.
    //   L3 : slot g of i_uram_data_l3 → line_buffer_wide_l3[g].
    // ------------------------------------------------------------------
    wire [WIDE_BITS-1:0] w_lb_wide_in   [0:MAX_CH-1];
    wire [L3_BITS-1:0]   w_lb_l3_in     [0:MAX_CH-1];

    wire [WIN_SIZE_WIDE-1:0] w_lb_wide_data  [0:MAX_CH-1];
    wire [LANES_WIDE-1:0]    w_lb_wide_lane_v[0:MAX_CH-1];
    wire                     w_lb_wide_valid [0:MAX_CH-1];
    wire                     w_lb_wide_done  [0:MAX_CH-1];
    wire                     w_lb_wide_imgd  [0:MAX_CH-1];

    wire [WIN_SIZE_L3-1:0]   w_lb_l3_data   [0:MAX_CH-1];
    wire [LANES_L3-1:0]      w_lb_l3_lane_v [0:MAX_CH-1];
    wire                     w_lb_l3_valid  [0:MAX_CH-1];
    wire                     w_lb_l3_done   [0:MAX_CH-1];
    wire                     w_lb_l3_imgd   [0:MAX_CH-1];

    genvar g;
    // L2 in_ch index: rows g=0..3 read in_ch=g, rows g=4..7 read in_ch=(g-4).
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_mux
            wire [3:0] l2_in_ch = g[2] ? (g - 4) : g;
            assign w_lb_wide_in[g] = w_is_L1
                ? i_uram_data_wide[(MAX_CH-1)*WIDE_BITS +: WIDE_BITS]               // L1: broadcast slot 0
                : i_uram_data_wide[((MAX_CH-1)-l2_in_ch)*WIDE_BITS +: WIDE_BITS];   // L2: per in_ch
            assign w_lb_l3_in[g] =
                i_uram_data_l3[((MAX_CH-1)-g)*L3_BITS +: L3_BITS];
        end
    endgenerate

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb
            // line_buffer_wide (3×10, 8-px shift) — used for L1 and L2.
            line_buffer_wide #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(10),
                .SHIFT_STEP(8), .DATA_BIT(16), .LANE_NUM(LANES_WIDE)
            ) u_lb_wide (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (i_input_valid && !w_is_L3),
                .i_input_data   (w_lb_wide_in[g]),
                .o_line_data    (w_lb_wide_data[g]),
                .o_lane_valid   (w_lb_wide_lane_v[g]),
                .o_line_valid   (w_lb_wide_valid[g]),
                .o_line_rd_done (w_lb_wide_done[g]),
                .o_img_done     (w_lb_wide_imgd[g])
            );

            // line_buffer_wide_l3 (3×6, 4-px shift) — used for L3 only.
            line_buffer_wide_l3 #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(6),
                .SHIFT_STEP(4), .DATA_BIT(16), .LANE_NUM(LANES_L3)
            ) u_lb_l3 (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (i_input_valid && w_is_L3),
                .i_input_data   (w_lb_l3_in[g]),
                .o_line_data    (w_lb_l3_data[g]),
                .o_lane_valid   (w_lb_l3_lane_v[g]),
                .o_line_valid   (w_lb_l3_valid[g]),
                .o_line_rd_done (w_lb_l3_done[g]),
                .o_img_done     (w_lb_l3_imgd[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 3×3 sub-window extraction per (ch, lane).
    //   line_buffer_wide   (3×10 window):
    //     lane k → cols (9-k, 8-k, 7-k). Packed as {top, mid, bot} row-major.
    //   line_buffer_wide_l3 (3×6 window):
    //     lane k (k<4) → cols (5-k, 4-k, 3-k).  lane k>=4 → zero (L3 uses 4 lanes only).
    //
    //   Sub-window bit order for pe_group (tap 0..8, MSB first):
    //     {tl, tc, tr,  ml, mc, mr,  bl, bc, br}  (top-left to bottom-right).
    //   row_idx 0 = newest (bottom), 2 = oldest (top).
    // ------------------------------------------------------------------
    wire [143:0] w_subwin [0:MAX_CH-1][0:LANES_WIDE-1];

    genvar k;
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_subwin_ch
            wire [WIN_BITS_WIDE-1:0] s_wide_r0 = w_lb_wide_data[g][0*WIN_BITS_WIDE +: WIN_BITS_WIDE];
            wire [WIN_BITS_WIDE-1:0] s_wide_r1 = w_lb_wide_data[g][1*WIN_BITS_WIDE +: WIN_BITS_WIDE];
            wire [WIN_BITS_WIDE-1:0] s_wide_r2 = w_lb_wide_data[g][2*WIN_BITS_WIDE +: WIN_BITS_WIDE];
            wire [WIN_BITS_L3-1:0]   s_l3_r0   = w_lb_l3_data[g][0*WIN_BITS_L3 +: WIN_BITS_L3];
            wire [WIN_BITS_L3-1:0]   s_l3_r1   = w_lb_l3_data[g][1*WIN_BITS_L3 +: WIN_BITS_L3];
            wire [WIN_BITS_L3-1:0]   s_l3_r2   = w_lb_l3_data[g][2*WIN_BITS_L3 +: WIN_BITS_L3];

            for (k = 0; k < LANES_WIDE; k = k + 1) begin : gen_subwin_lane
                // L1/L2: lane k → cols (9-k, 8-k, 7-k) of 10-col window.
                wire [15:0] wide_tl = s_wide_r2[(9-k)*16 +: 16];
                wire [15:0] wide_tc = s_wide_r2[(8-k)*16 +: 16];
                wire [15:0] wide_tr = s_wide_r2[(7-k)*16 +: 16];
                wire [15:0] wide_ml = s_wide_r1[(9-k)*16 +: 16];
                wire [15:0] wide_mc = s_wide_r1[(8-k)*16 +: 16];
                wire [15:0] wide_mr = s_wide_r1[(7-k)*16 +: 16];
                wire [15:0] wide_bl = s_wide_r0[(9-k)*16 +: 16];
                wire [15:0] wide_bc = s_wide_r0[(8-k)*16 +: 16];
                wire [15:0] wide_br = s_wide_r0[(7-k)*16 +: 16];
                wire [143:0] sub_wide = { wide_tl, wide_tc, wide_tr,
                                          wide_ml, wide_mc, wide_mr,
                                          wide_bl, wide_bc, wide_br };

                // L3: lane k (k<4) → cols (5-k, 4-k, 3-k) of 6-col window.
                wire [143:0] sub_l3;
                if (k < LANES_L3) begin : gen_l3_active
                    wire [15:0] l3_tl = s_l3_r2[(5-k)*16 +: 16];
                    wire [15:0] l3_tc = s_l3_r2[(4-k)*16 +: 16];
                    wire [15:0] l3_tr = s_l3_r2[(3-k)*16 +: 16];
                    wire [15:0] l3_ml = s_l3_r1[(5-k)*16 +: 16];
                    wire [15:0] l3_mc = s_l3_r1[(4-k)*16 +: 16];
                    wire [15:0] l3_mr = s_l3_r1[(3-k)*16 +: 16];
                    wire [15:0] l3_bl = s_l3_r0[(5-k)*16 +: 16];
                    wire [15:0] l3_bc = s_l3_r0[(4-k)*16 +: 16];
                    wire [15:0] l3_br = s_l3_r0[(3-k)*16 +: 16];
                    assign sub_l3 = { l3_tl, l3_tc, l3_tr,
                                      l3_ml, l3_mc, l3_mr,
                                      l3_bl, l3_bc, l3_br };
                end else begin : gen_l3_zero
                    assign sub_l3 = 144'd0;
                end

                assign w_subwin[g][k] = w_is_L3 ? sub_l3 : sub_wide;
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // pe_group instances: 8 ch × 8 lanes = 64 total.
    // ------------------------------------------------------------------
    wire               w_pe_valid   [0:MAX_CH-1][0:LANES_WIDE-1];
    wire signed [31:0] w_pe_partial [0:MAX_CH-1][0:LANES_WIDE-1];
    wire               w_pe_done    [0:MAX_CH-1][0:LANES_WIDE-1];

    wire w_line_valid_ch [0:MAX_CH-1];
    wire w_line_imgd_ch  [0:MAX_CH-1];
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_valid_mux
            assign w_line_valid_ch[g] = w_is_L3 ? w_lb_l3_valid[g] : w_lb_wide_valid[g];
            assign w_line_imgd_ch[g]  = w_is_L3 ? w_lb_l3_imgd[g]  : w_lb_wide_imgd[g];
        end
    endgenerate

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_pe_ch
            for (k = 0; k < LANES_WIDE; k = k + 1) begin : gen_pe_lane
                pe_group u_pe_group (
                    .i_clk           (i_clk),
                    .i_rstn          (i_rstn),
                    .i_line_valid    (w_line_valid_ch[g]),
                    .i_line_data     (w_subwin[g][k]),
                    .i_weight        (w_weight[g]),
                    .i_w_tap_en      (w_tap_en),
                    .i_line_img_done (w_line_imgd_ch[g]),
                    .o_valid         (w_pe_valid[g][k]),
                    .o_partial       (w_pe_partial[g][k]),
                    .o_pe_done       (w_pe_done[g][k])
                );
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Stage 1/2/3 pipeline.
    //   Stage 1: partial sums across pe_group rows (in_ch reduction).
    //   Stage 2: arithmetic right-shift by 8 (Q16.16 → Q8.8) + bias add.
    //   Stage 3: saturation and output pack.
    // ------------------------------------------------------------------
    reg signed [31:0] r_add_stage1 [0:MAX_CH-1][0:LANES_WIDE-1];
    reg signed [31:0] r_add_total  [0:MAX_CH-1][0:LANES_WIDE-1];
    reg [1:0]         r_layer_s1, r_layer_s2;
    reg               r_valid_s1, r_valid_s2;

    // L3 lane_valid delayed to align with Stage 3 output (3 clk pe_group + 2 clk stage1/2 = 5 clk).
    reg [LANES_L3-1:0] r_l3_lane_v_s1, r_l3_lane_v_s2;
    wire [LANES_L3-1:0] w_lv_l3_pe;
    delay_shift #(.WIDTH(LANES_L3), .DELAY(3)) u_lv_l3_pe_dly (
        .clk(i_clk), .rst(~i_rstn), .en(1'b1),
        .din(w_lb_l3_lane_v[0]),
        .dout(w_lv_l3_pe)
    );

    // L1/L2 lane_valid: same 3+2 clk delay path.
    wire [LANES_WIDE-1:0] w_lv_wide_pe;
    delay_shift #(.WIDTH(LANES_WIDE), .DELAY(3)) u_lv_pe_dly (
        .clk(i_clk), .rst(~i_rstn), .en(1'b1),
        .din(w_lb_wide_lane_v[0]),
        .dout(w_lv_wide_pe)
    );
    reg [LANES_WIDE-1:0] r_lv_wide_s1, r_lv_wide_s2;

    integer si, sk;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (si = 0; si < MAX_CH; si = si + 1)
                for (sk = 0; sk < LANES_WIDE; sk = sk + 1) begin
                    r_add_stage1[si][sk] <= 0;
                    r_add_total[si][sk]  <= 0;
                end
            r_valid_s1     <= 0;
            r_valid_s2     <= 0;
            r_layer_s1     <= 0;
            r_layer_s2     <= 0;
            r_l3_lane_v_s1 <= 0;
            r_l3_lane_v_s2 <= 0;
            r_lv_wide_s1   <= 0;
            r_lv_wide_s2   <= 0;
        end else begin
            r_valid_s1     <= w_pe_valid[0][0];
            r_valid_s2     <= r_valid_s1;
            r_layer_s1     <= i_layer_cnt;
            r_layer_s2     <= r_layer_s1;
            r_l3_lane_v_s1 <= w_lv_l3_pe;
            r_l3_lane_v_s2 <= r_l3_lane_v_s1;
            r_lv_wide_s1   <= w_lv_wide_pe;
            r_lv_wide_s2   <= r_lv_wide_s1;

            // ---- Stage 1: partial sum across pe_group rows ----
            for (sk = 0; sk < LANES_WIDE; sk = sk + 1) begin
                case (i_layer_cnt)
                    2'd0: begin // L1: no in_ch reduction, pass partial per oc.
                        r_add_stage1[0][sk] <= w_pe_partial[0][sk];
                        r_add_stage1[1][sk] <= w_pe_partial[1][sk];
                        r_add_stage1[2][sk] <= w_pe_partial[2][sk];
                        r_add_stage1[3][sk] <= w_pe_partial[3][sk];
                        r_add_stage1[4][sk] <= w_pe_partial[4][sk];
                        r_add_stage1[5][sk] <= w_pe_partial[5][sk];
                        r_add_stage1[6][sk] <= w_pe_partial[6][sk];
                        r_add_stage1[7][sk] <= w_pe_partial[7][sk];
                    end
                    2'd1: begin // L2: pair sum within each oc half.
                        // stage1[0] = oc=0 (ic0+ic1), stage1[1] = oc=0 (ic2+ic3)
                        // stage1[2] = oc=1 (ic0+ic1), stage1[3] = oc=1 (ic2+ic3)
                        r_add_stage1[0][sk] <= w_pe_partial[0][sk] + w_pe_partial[1][sk];
                        r_add_stage1[1][sk] <= w_pe_partial[2][sk] + w_pe_partial[3][sk];
                        r_add_stage1[2][sk] <= w_pe_partial[4][sk] + w_pe_partial[5][sk];
                        r_add_stage1[3][sk] <= w_pe_partial[6][sk] + w_pe_partial[7][sk];
                        r_add_stage1[4][sk] <= 0;
                        r_add_stage1[5][sk] <= 0;
                        r_add_stage1[6][sk] <= 0;
                        r_add_stage1[7][sk] <= 0;
                    end
                    2'd2: begin // L3: sum g=0,1 (ic0+ic1) → stage1[0].
                        r_add_stage1[0][sk] <= w_pe_partial[0][sk] + w_pe_partial[1][sk];
                        r_add_stage1[1][sk] <= 0;
                        r_add_stage1[2][sk] <= 0;
                        r_add_stage1[3][sk] <= 0;
                        r_add_stage1[4][sk] <= 0;
                        r_add_stage1[5][sk] <= 0;
                        r_add_stage1[6][sk] <= 0;
                        r_add_stage1[7][sk] <= 0;
                    end
                    default: begin
                        for (si = 0; si < MAX_CH; si = si + 1) r_add_stage1[si][sk] <= 0;
                    end
                endcase
            end

            // ---- Stage 2: 4-way sum (where needed) + >>8 + bias ----
            for (sk = 0; sk < LANES_WIDE; sk = sk + 1) begin
                case (r_layer_s1)
                    2'd0: begin // L1: >>8 + per-oc bias. Slots 4..7 inactive.
                        r_add_total[0][sk] <= (r_add_stage1[0][sk] >>> 8) + $signed({{16{r_bias[0][15]}}, r_bias[0]});
                        r_add_total[1][sk] <= (r_add_stage1[1][sk] >>> 8) + $signed({{16{r_bias[1][15]}}, r_bias[1]});
                        r_add_total[2][sk] <= (r_add_stage1[2][sk] >>> 8) + $signed({{16{r_bias[2][15]}}, r_bias[2]});
                        r_add_total[3][sk] <= (r_add_stage1[3][sk] >>> 8) + $signed({{16{r_bias[3][15]}}, r_bias[3]});
                        r_add_total[4][sk] <= 0;
                        r_add_total[5][sk] <= 0;
                        r_add_total[6][sk] <= 0;
                        r_add_total[7][sk] <= 0;
                    end
                    2'd1: begin // L2: 4-way sum (stage1[0..1] → oc=0, stage1[2..3] → oc=1) + >>8 + bias.
                        r_add_total[0][sk] <= ((r_add_stage1[0][sk] + r_add_stage1[1][sk]) >>> 8)
                                            + $signed({{16{w_bias_L2_oc0[15]}}, w_bias_L2_oc0});
                        r_add_total[1][sk] <= ((r_add_stage1[2][sk] + r_add_stage1[3][sk]) >>> 8)
                                            + $signed({{16{w_bias_L2_oc1[15]}}, w_bias_L2_oc1});
                        for (si = 2; si < MAX_CH; si = si + 1) r_add_total[si][sk] <= 0;
                    end
                    2'd2: begin // L3: stage1[0] (ic0+ic1 already summed) + >>8 + bias.
                        r_add_total[0][sk] <= (r_add_stage1[0][sk] >>> 8)
                                            + $signed({{16{r_bias[0][15]}}, r_bias[0]});
                        for (si = 1; si < MAX_CH; si = si + 1) r_add_total[si][sk] <= 0;
                    end
                    default: begin
                        for (si = 0; si < MAX_CH; si = si + 1) r_add_total[si][sk] <= 0;
                    end
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 3: saturation clamp and output pack into 1024-bit word.
    //   Pixel order in each 128-bit oc slot: lane 0 at MSB, lane 7 at LSB.
    // ------------------------------------------------------------------
    integer oi, ok;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_emit_valid       <= 0;
            o_oc_valid_mask    <= 0;
            o_lane_valid_mask  <= 0;
            o_pixel_data       <= 0;
        end else begin
            o_emit_valid <= r_valid_s2;
            o_pixel_data <= 0;
            o_oc_valid_mask    <= 0;
            o_lane_valid_mask  <= 0;

            case (r_layer_s2)
                2'd0: begin // L1: 4 oc × 8 lane, ReLU sat. Slots 0..3 active.
                    o_oc_valid_mask <= 8'b00001111;
                    for (oi = 0; oi < 4; oi = oi + 1) begin
                        o_lane_valid_mask[oi*LANES_WIDE +: LANES_WIDE] <= r_lv_wide_s2;
                    end
                    for (oi = 0; oi < 4; oi = oi + 1) begin
                        for (ok = 0; ok < LANES_WIDE; ok = ok + 1) begin
                            o_pixel_data[oi*128 + (LANES_WIDE-1-ok)*16 +: 16] <=
                                (~r_lv_wide_s2[ok])                    ? 16'sd0      :
                                (r_add_total[oi][ok][31])              ? 16'sd0      :
                                (r_add_total[oi][ok] > 32'sd32767)     ? 16'sd32767  :
                                                                         r_add_total[oi][ok][15:0];
                        end
                    end
                end
                2'd1: begin // L2: 2 oc × 8 lane, ReLU sat. Slots 0..1 active.
                    o_oc_valid_mask <= 8'b00000011;
                    o_lane_valid_mask[0*LANES_WIDE +: LANES_WIDE] <= r_lv_wide_s2;
                    o_lane_valid_mask[1*LANES_WIDE +: LANES_WIDE] <= r_lv_wide_s2;
                    for (oi = 0; oi < 2; oi = oi + 1) begin
                        for (ok = 0; ok < LANES_WIDE; ok = ok + 1) begin
                            o_pixel_data[oi*128 + (LANES_WIDE-1-ok)*16 +: 16] <=
                                (~r_lv_wide_s2[ok])                ? 16'sd0     :
                                (r_add_total[oi][ok][31])          ? 16'sd0     :
                                (r_add_total[oi][ok] > 32'sd32767) ? 16'sd32767 :
                                                                     r_add_total[oi][ok][15:0];
                        end
                    end
                end
                2'd2: begin // L3: slot 0 × 4 lanes, bidirectional sat (no ReLU).
                    o_oc_valid_mask <= 8'b00000001;
                    o_lane_valid_mask[LANES_WIDE-1:0] <= { {(LANES_WIDE-LANES_L3){1'b0}}, r_l3_lane_v_s2 };
                    for (ok = 0; ok < LANES_L3; ok = ok + 1) begin
                        o_pixel_data[0*128 + (LANES_WIDE-1-ok)*16 +: 16] <=
                            (r_add_total[0][ok] >  32'sd32767) ? 16'sh7FFF :
                            (r_add_total[0][ok] < -32'sd32768) ? 16'sh8000 :
                                                                 r_add_total[0][ok][15:0];
                    end
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // o_img_done: delay pe_done[0][0] by 3 clk to align with Stage 3 output.
    // ------------------------------------------------------------------
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0][0]),
        .dout (o_img_done)
    );
endmodule
