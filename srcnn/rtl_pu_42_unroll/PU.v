`timescale 1ns / 1ps
// PU (preset 4_2 UNROLL) : L1 4-oc / L2 2-oc / L3 1-oc spatial parallel.
//
//   pe_group grid = 8 × 8 = 64 instances (= MAX_CH × LANES_WIDE). 유지.
//   각 layer 별 grid 의미 :
//     L1 : g=0..3 = oc 0..3 (in_ch=1 broadcast). g=4..7 사용 안함.
//     L2 : g=0..3 = oc=0 in_ch=0..3.  g=4..7 = oc=1 in_ch=0..3.
//     L3 : g=0..1 = in_ch=0..1 (4 lane). g=2..7 사용 안함.
//
//   PE 총량 (max instance) : 8 × 8 × 9 = 576 PE.
//
//   입력 (top.v 에서 layer별 적절히 라우팅) :
//     - i_uram_data_wide [MAX_CH*128-1:0] : MAX_CH slot, slot 0 = MSB.
//         L1 : slot[0] = 입력 broadcast, 나머지는 무시.
//         L2 : slot[0..3] = in_ch 0..3, slot[4..7] = 0 (top.v 에서 0 으로 채움).
//                PU 가 slot[g mod 4] 를 oc=1 용 line_buffer (g=4..7) 에도 라우팅.
//     - i_uram_data_l3  [MAX_CH*64-1:0]   : L3 시 slot[0..1] = in_ch 0..1.
//
//   weight BRAM data (i_weight_bram_data, 128b) 의 slot 매핑 :
//     L1 tap n : slot[0..3] = W1[oc=0..3, 0, n].
//     L2 tap n : slot[0..3] = W2[oc=0, ic=0..3, n].  slot[4..7] = W2[oc=1, ic=0..3, n].
//     L3 tap n : slot[0..1] = W3[0, ic=0..1, n].
//   PU 는 w_weight[g] = slot[g] (이미 그렇게 wiring) → 그대로 매핑.
//
//   출력 :
//     - o_oc_valid_mask : L1=4'b1111, L2=2'b11, L3=1'b1 (slot 0 만).
//
//   Pipeline (line_buffer 2-clk + pe_group 3-clk + PU Stage A/B/C 3-clk = 8-clk).

module PU #(
    parameter MAX_CH     = 8,
    parameter LANES_WIDE = 8,
    parameter LANES_L3   = 4,
    parameter WIDE_BITS  = 128,   // 8 px × 16 (L1/L2)
    parameter L3_BITS    = 64     // 4 px × 16 (L3)
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
    // Weight tap dispatcher (동일 : 9 taps + bias, 1-hot tap_en)
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

    // Per-channel weight slot (slot 0 = MSB).
    wire signed [15:0] w_weight [0:MAX_CH-1];
    genvar gw;
    generate
        for (gw = 0; gw < MAX_CH; gw = gw + 1) begin : gen_w_slot
            assign w_weight[gw] = i_weight_bram_data[16*((MAX_CH-1)-gw) +: 16];
        end
    endgenerate

    // ------------------------------------------------------------------
    // Bias latch (8 slot)
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

    // L2 bias : slot 0 = oc=0 bias, slot 1 = oc=1 bias.
    wire signed [15:0] w_L2_bias0 = r_bias[0];
    wire signed [15:0] w_L2_bias1 = r_bias[1];

    // ------------------------------------------------------------------
    // Per-channel input mux + line buffers
    //   L1 : ch 0 (= MSB slot of i_uram_data_wide) broadcast to all 8 ch.
    //   L2 : ch g = i_uram_data_wide[ g-th 128b ].
    //   L3 : ch g = i_uram_data_l3 [ g-th 64b ].
    // ------------------------------------------------------------------
    wire [WIDE_BITS-1:0] w_lb_wide_in   [0:MAX_CH-1];
    wire [L3_BITS-1:0]   w_lb_l3_in     [0:MAX_CH-1];

    wire [WIN_SIZE_WIDE-1:0] w_lb_wide_data [0:MAX_CH-1];
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
    // L2 in_ch mux : g=0..3 → in_ch g, g=4..7 → in_ch (g-4) (replicated for oc=1).
    //   slot ordering : slot index 0 = MSB. ch g lives at slot index g
    //                 → bits [(MAX_CH-1-g)*WIDE_BITS +: WIDE_BITS].
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_mux
            wire [3:0] l2_ic_idx = g[2] ? (g - 4) : g;   // 0..3 for both halves
            assign w_lb_wide_in[g] = w_is_L1
                ? i_uram_data_wide[(MAX_CH-1)*WIDE_BITS +: WIDE_BITS]            // L1 broadcast
                : i_uram_data_wide[((MAX_CH-1)-l2_ic_idx)*WIDE_BITS +: WIDE_BITS]; // L2
            assign w_lb_l3_in[g] =
                i_uram_data_l3[((MAX_CH-1)-g)*L3_BITS +: L3_BITS];
        end
    endgenerate

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb
            // line_buffer_wide (3×10, 8-px shift) — active L1/L2.
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

            // line_buffer_wide_l3 (3×6, 4-px shift) — active L3.
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
    // Window mux + 3×3 sub-window extraction (per ch, per lane).
    //   line_buffer_wide   : 3×10 win. lane k (k=0..7) sub-window cols win[9-k, 8-k, 7-k].
    //   line_buffer_wide_l3: 3×6  win. lane k (k=0..3) sub-window cols win[5-k, 4-k, 3-k]
    //                                  lane k (k=4..7) → 0.
    // ------------------------------------------------------------------
    // Per-row 160-bit (wide) / 96-bit (l3) slice access helper :
    //   row_idx 0 = bottom (newest), 1 = middle, 2 = top (oldest).
    //   col_idx 0 = LSB pixel (newest), max = MSB pixel (oldest).
    //
    //   sub-window pack order for pe_group (= tap 0..8, MSB→LSB) :
    //     {tl, tc, tr, ml, mc, mr, bl, bc, br}   (row-major top→bot, left→right).

    // window data per (ch, lane), 144-bit each.
    wire [143:0] w_subwin [0:MAX_CH-1][0:LANES_WIDE-1];

    // helper macros expand in generate.
    genvar k;
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_subwin_ch
            // Slices per row from each line buffer.
            wire [WIN_BITS_WIDE-1:0] s_wide_r0 = w_lb_wide_data[g][0*WIN_BITS_WIDE +: WIN_BITS_WIDE];
            wire [WIN_BITS_WIDE-1:0] s_wide_r1 = w_lb_wide_data[g][1*WIN_BITS_WIDE +: WIN_BITS_WIDE];
            wire [WIN_BITS_WIDE-1:0] s_wide_r2 = w_lb_wide_data[g][2*WIN_BITS_WIDE +: WIN_BITS_WIDE];
            wire [WIN_BITS_L3-1:0]   s_l3_r0   = w_lb_l3_data[g][0*WIN_BITS_L3 +: WIN_BITS_L3];
            wire [WIN_BITS_L3-1:0]   s_l3_r1   = w_lb_l3_data[g][1*WIN_BITS_L3 +: WIN_BITS_L3];
            wire [WIN_BITS_L3-1:0]   s_l3_r2   = w_lb_l3_data[g][2*WIN_BITS_L3 +: WIN_BITS_L3];

            for (k = 0; k < LANES_WIDE; k = k + 1) begin : gen_subwin_lane
                // L1/L2 path : lane k → cols (9-k, 8-k, 7-k) of 10-col slice.
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

                // L3 path : lane k (k<4) → cols (5-k, 4-k, 3-k) of 6-col slice.
                //          lane k (k≥4) → zero (unused).
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
    // pe_group : 8 per ch × 8 ch = 64 instances (per-lane).
    // ------------------------------------------------------------------
    wire               w_pe_valid     [0:MAX_CH-1][0:LANES_WIDE-1];
    wire signed [31:0] w_pe_partial   [0:MAX_CH-1][0:LANES_WIDE-1];
    wire               w_pe_done      [0:MAX_CH-1][0:LANES_WIDE-1];

    // line_buffer_valid (active per layer) drives pe_group.
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
    // Stage 1/2/3 pipeline — per (oc/ch, lane).
    //   L1 : oc g = ch g. Per (oc, lane) : partial → bias add → sat.
    //   L2/L3 : oc = i_out_ch_cnt. Per lane : sum over 8 ch → bias add → sat.
    // ------------------------------------------------------------------
    reg signed [31:0] r_add_stage1 [0:MAX_CH-1][0:LANES_WIDE-1];
    reg signed [31:0] r_add_total  [0:MAX_CH-1][0:LANES_WIDE-1];
    reg [1:0]         r_layer_s1, r_layer_s2;
    reg               r_valid_s1, r_valid_s2;

    // L3 lane valid pipelined to align with stage 3.
    reg [LANES_L3-1:0] r_l3_lane_v_s1, r_l3_lane_v_s2;

    // L1/L2 lane valid (from line_buffer_wide ch 0). Same emit pattern across ch.
    // PE+adder = 3 clk delay then Stage A/B = 2 more = 5 clk before Stage 3 uses it.
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
            r_l3_lane_v_s1 <= w_lb_l3_lane_v[0];
            r_l3_lane_v_s2 <= r_l3_lane_v_s1;
            r_lv_wide_s1   <= w_lv_wide_pe;
            r_lv_wide_s2   <= r_lv_wide_s1;

            // ---- Stage 1 : per (oc, lane) pair sum or pass ----
            for (sk = 0; sk < LANES_WIDE; sk = sk + 1) begin
                case (i_layer_cnt)
                    2'd0: begin // L1 : pass through per oc.
                        r_add_stage1[0][sk] <= w_pe_partial[0][sk];
                        r_add_stage1[1][sk] <= w_pe_partial[1][sk];
                        r_add_stage1[2][sk] <= w_pe_partial[2][sk];
                        r_add_stage1[3][sk] <= w_pe_partial[3][sk];
                        r_add_stage1[4][sk] <= w_pe_partial[4][sk];
                        r_add_stage1[5][sk] <= w_pe_partial[5][sk];
                        r_add_stage1[6][sk] <= w_pe_partial[6][sk];
                        r_add_stage1[7][sk] <= w_pe_partial[7][sk];
                    end
                    2'd1: begin // L2 : pair sum within each oc half.
                        //   stage1[0] = oc=0 (ic0+ic1), stage1[1] = oc=0 (ic2+ic3)
                        //   stage1[2] = oc=1 (ic0+ic1), stage1[3] = oc=1 (ic2+ic3)
                        r_add_stage1[0][sk] <= w_pe_partial[0][sk] + w_pe_partial[1][sk];
                        r_add_stage1[1][sk] <= w_pe_partial[2][sk] + w_pe_partial[3][sk];
                        r_add_stage1[2][sk] <= w_pe_partial[4][sk] + w_pe_partial[5][sk];
                        r_add_stage1[3][sk] <= w_pe_partial[6][sk] + w_pe_partial[7][sk];
                        r_add_stage1[4][sk] <= 0;
                        r_add_stage1[5][sk] <= 0;
                        r_add_stage1[6][sk] <= 0;
                        r_add_stage1[7][sk] <= 0;
                    end
                    2'd2: begin // L3 : pair sum (g=0,1 only) → stage1[0] = ic0+ic1.
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

            // ---- Stage 2 : (>>>8) + bias ----
            for (sk = 0; sk < LANES_WIDE; sk = sk + 1) begin
                case (r_layer_s1)
                    2'd0: begin // L1 : 4 oc per-oc bias. slot 4..7 unused (= 0).
                        r_add_total[0][sk] <= (r_add_stage1[0][sk] >>> 8) + $signed({{16{r_bias[0][15]}}, r_bias[0]});
                        r_add_total[1][sk] <= (r_add_stage1[1][sk] >>> 8) + $signed({{16{r_bias[1][15]}}, r_bias[1]});
                        r_add_total[2][sk] <= (r_add_stage1[2][sk] >>> 8) + $signed({{16{r_bias[2][15]}}, r_bias[2]});
                        r_add_total[3][sk] <= (r_add_stage1[3][sk] >>> 8) + $signed({{16{r_bias[3][15]}}, r_bias[3]});
                        r_add_total[4][sk] <= 0;
                        r_add_total[5][sk] <= 0;
                        r_add_total[6][sk] <= 0;
                        r_add_total[7][sk] <= 0;
                    end
                    2'd1: begin // L2 : 2 oc spatial. oc=0 = stage1[0]+stage1[1], oc=1 = stage1[2]+stage1[3].
                        r_add_total[0][sk] <= ((r_add_stage1[0][sk] + r_add_stage1[1][sk]) >>> 8)
                                            + $signed({{16{w_L2_bias0[15]}}, w_L2_bias0});
                        r_add_total[1][sk] <= ((r_add_stage1[2][sk] + r_add_stage1[3][sk]) >>> 8)
                                            + $signed({{16{w_L2_bias1[15]}}, w_L2_bias1});
                        for (si = 2; si < MAX_CH; si = si + 1) r_add_total[si][sk] <= 0;
                    end
                    2'd2: begin // L3 : 1 oc, ic 0+1 = stage1[0].
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
    // Stage 3 / Output : per (oc, lane) saturation, pack to 1024-bit.
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
                2'd0: begin // L1 : 4 oc spatial × 8 lane. slot 0..3 active.
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
                2'd1: begin // L2 : 2 oc spatial × 8 lane. slot 0,1 active.
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
                2'd2: begin // L3 : oc slot 0 × 4 lane (with per-lane mask from line buffer).
                    o_oc_valid_mask <= 8'b00000001;
                    // L3 lane 0..3 valid from r_l3_lane_v_s2, lane 4..7 invalid.
                    o_lane_valid_mask[LANES_WIDE-1:0] <= { {(LANES_WIDE-LANES_L3){1'b0}}, r_l3_lane_v_s2 };
                    for (ok = 0; ok < LANES_L3; ok = ok + 1) begin
                        // L3 = bidirectional sat (no ReLU).
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
    // o_img_done : ch 0 lane 0 의 pe_done 을 Stage 3 alignment 까지 지연 (+3).
    // ------------------------------------------------------------------
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0][0]),
        .dout (o_img_done)
    );
endmodule
