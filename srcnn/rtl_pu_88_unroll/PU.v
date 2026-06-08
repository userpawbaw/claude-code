`timescale 1ns / 1ps
// PU (preset 8_8 unroll) : 8-way (L1/L2) / 4-way (L3) parallel PE.
//
//   채널 = 8 (MAX_CH). 각 채널마다 line_buffer_wide (3×10, 8-px shift) +
//   line_buffer_wide_l3 (3×6, 4-px shift) 동시 인스턴스. 활성 layer 에 따라
//   3-row × WIN_COL 윈도우 출력에서 8 개 (L1/L2) 또는 4 개 (L3) 의 3×3
//   sub-window 를 추출해 pe_group 8 개 (per ch) 로 분배.
//
//   PE 총량 :
//     L1/L2 : 8 ch × 8 lane × 9 tap = 576 PE.
//     L3    : 8 ch × 4 lane × 9 tap = 288 PE (lane 4..7 = 0, 결과 무시).
//
//   입력 (top.v 에서 분리 공급) :
//     - i_uram_data_wide [MAX_CH*128-1:0] : 8 ch × 8 px (= 128 bit per ch).
//         * L1 mode 에서는 slot[0] (= 가장 MSB 의 128 bit) 만 의미.
//         * L2 mode 에서는 8 ch 모두 의미 (8 px × 8 ch = 1024 bit).
//     - i_uram_data_l3  [MAX_CH*64-1:0]   : 8 ch × 4 px (= 64 bit per ch).
//         * L3 mode 에서만 의미.
//
//   출력 :
//     - o_emit_valid : 1 clk emit pulse (per cycle).
//     - o_oc_valid_mask [7:0] : 활성 oc slot mask. L1=0xFF, L2/L3=0x01.
//     - o_lane_valid_mask [63:0] : (oc, lane) 별 valid (8 oc × 8 lane).
//         * L1/L2 : oc 별로 lane 0..7 (line_buffer_wide 내부에서 col-padding 마스킹 처리됨).
//         * L3    : oc 0 slot 의 lane 0..3 만 active, line_buffer_wide_l3
//                   o_lane_valid 따라.
//     - o_pixel_data [1023:0] : 8 oc × 8 lane × 16 bit. oc 슬롯 = bits [oc*128 +: 128].
//                               그 안에서 lane 0 = MSB 16 bit, lane 7 = LSB 16 bit.
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

    wire signed [15:0] w_L2_bias = r_bias[i_out_ch_cnt];

    // ------------------------------------------------------------------
    // Per-channel input mux + line buffers
    //   L1 : ch 0 (= MSB slot of i_uram_data_wide) broadcast to all 8 ch.
    //   L2 : ch g = i_uram_data_wide[ g-th 128b ].
    //   L3 : ch g = i_uram_data_l3 [ g-th 64b ].
    // ------------------------------------------------------------------
    wire [WIDE_BITS-1:0] w_lb_wide_in   [0:MAX_CH-1];
    wire [L3_BITS-1:0]   w_lb_l3_in     [0:MAX_CH-1];

    wire [WIN_SIZE_WIDE-1:0] w_lb_wide_data [0:MAX_CH-1];
    wire                     w_lb_wide_valid [0:MAX_CH-1];
    wire                     w_lb_wide_done  [0:MAX_CH-1];
    wire                     w_lb_wide_imgd  [0:MAX_CH-1];

    wire [WIN_SIZE_L3-1:0]   w_lb_l3_data   [0:MAX_CH-1];
    wire [LANES_L3-1:0]      w_lb_l3_lane_v [0:MAX_CH-1];
    wire                     w_lb_l3_valid  [0:MAX_CH-1];
    wire                     w_lb_l3_done   [0:MAX_CH-1];
    wire                     w_lb_l3_imgd   [0:MAX_CH-1];

    genvar g;
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_mux
            // L1 broadcast : slot 0 = MSB 128b of i_uram_data_wide.
            assign w_lb_wide_in[g] = w_is_L1
                ? i_uram_data_wide[(MAX_CH-1)*WIDE_BITS +: WIDE_BITS]
                : i_uram_data_wide[((MAX_CH-1)-g)*WIDE_BITS +: WIDE_BITS];
            // L3 path : ch g = g-th 64b slot.
            assign w_lb_l3_in[g] =
                i_uram_data_l3[((MAX_CH-1)-g)*L3_BITS +: L3_BITS];
        end
    endgenerate

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb
            // line_buffer_wide (3×10, 8-px shift) — active L1/L2.
            line_buffer_wide #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(10),
                .SHIFT_STEP(8), .DATA_BIT(16)
            ) u_lb_wide (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (i_input_valid && !w_is_L3),
                .i_input_data   (w_lb_wide_in[g]),
                .o_line_data    (w_lb_wide_data[g]),
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
        end else begin
            r_valid_s1     <= w_pe_valid[0][0];
            r_valid_s2     <= r_valid_s1;
            r_layer_s1     <= i_layer_cnt;
            r_layer_s2     <= r_layer_s1;
            r_l3_lane_v_s1 <= w_lb_l3_lane_v[0];
            r_l3_lane_v_s2 <= r_l3_lane_v_s1;

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
                    2'd1, 2'd2: begin // L2/L3 : pair sum across ch.
                        r_add_stage1[0][sk] <= w_pe_partial[0][sk] + w_pe_partial[1][sk];
                        r_add_stage1[1][sk] <= w_pe_partial[2][sk] + w_pe_partial[3][sk];
                        r_add_stage1[2][sk] <= w_pe_partial[4][sk] + w_pe_partial[5][sk];
                        r_add_stage1[3][sk] <= w_pe_partial[6][sk] + w_pe_partial[7][sk];
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
                    2'd0: begin // L1 : per-oc bias.
                        r_add_total[0][sk] <= (r_add_stage1[0][sk] >>> 8) + {{16{r_bias[0][15]}}, r_bias[0]};
                        r_add_total[1][sk] <= (r_add_stage1[1][sk] >>> 8) + {{16{r_bias[1][15]}}, r_bias[1]};
                        r_add_total[2][sk] <= (r_add_stage1[2][sk] >>> 8) + {{16{r_bias[2][15]}}, r_bias[2]};
                        r_add_total[3][sk] <= (r_add_stage1[3][sk] >>> 8) + {{16{r_bias[3][15]}}, r_bias[3]};
                        r_add_total[4][sk] <= (r_add_stage1[4][sk] >>> 8) + {{16{r_bias[4][15]}}, r_bias[4]};
                        r_add_total[5][sk] <= (r_add_stage1[5][sk] >>> 8) + {{16{r_bias[5][15]}}, r_bias[5]};
                        r_add_total[6][sk] <= (r_add_stage1[6][sk] >>> 8) + {{16{r_bias[6][15]}}, r_bias[6]};
                        r_add_total[7][sk] <= (r_add_stage1[7][sk] >>> 8) + {{16{r_bias[7][15]}}, r_bias[7]};
                    end
                    2'd1: begin // L2 : 4-way sum + bias[oc_sel] (slot 0).
                        r_add_total[0][sk] <= ((r_add_stage1[0][sk] + r_add_stage1[1][sk]
                                              + r_add_stage1[2][sk] + r_add_stage1[3][sk]) >>> 8)
                                            + {{16{w_L2_bias[15]}}, w_L2_bias};
                        for (si = 1; si < MAX_CH; si = si + 1) r_add_total[si][sk] <= 0;
                    end
                    2'd2: begin // L3 : 4-way sum + bias[0] (slot 0).
                        r_add_total[0][sk] <= ((r_add_stage1[0][sk] + r_add_stage1[1][sk]
                                              + r_add_stage1[2][sk] + r_add_stage1[3][sk]) >>> 8)
                                            + {{16{r_bias[0][15]}}, r_bias[0]};
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
                2'd0: begin // L1 : 8 oc × 8 lane all valid (line_buffer 내부 mask 처리).
                    o_oc_valid_mask <= 8'hFF;
                    o_lane_valid_mask <= {(MAX_CH*LANES_WIDE){1'b1}};
                    for (oi = 0; oi < MAX_CH; oi = oi + 1) begin
                        for (ok = 0; ok < LANES_WIDE; ok = ok + 1) begin
                            // oc slot = bits[oi*128 +: 128], lane order MSB→LSB inside slot.
                            o_pixel_data[oi*128 + (LANES_WIDE-1-ok)*16 +: 16] <=
                                (r_add_total[oi][ok][31])              ? 16'sd0      :
                                (r_add_total[oi][ok] > 32'sd32767)     ? 16'sd32767  :
                                                                         r_add_total[oi][ok][15:0];
                        end
                    end
                end
                2'd1: begin // L2 : oc slot 0 × 8 lane.
                    o_oc_valid_mask <= 8'b00000001;
                    o_lane_valid_mask[LANES_WIDE-1:0] <= {LANES_WIDE{1'b1}};
                    for (ok = 0; ok < LANES_WIDE; ok = ok + 1) begin
                        o_pixel_data[0*128 + (LANES_WIDE-1-ok)*16 +: 16] <=
                            (r_add_total[0][ok][31])          ? 16'sd0     :
                            (r_add_total[0][ok] > 32'sd32767) ? 16'sd32767 :
                                                                r_add_total[0][ok][15:0];
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
