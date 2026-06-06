`timescale 1ns / 1ps
// PU (preset 8_8 unroll) : recursive single PU, i_layer_cnt selects L1 / L2 / L3.
//
//   Datapath unified to 32-bit signed Q16.16 (pre-shift) / Q24.8 (post-shift).
//   No automatic functions; sign extension via inline {sign, value} concatenation.
//
//   Layer behaviour:
//     L1 (layer=0): 8 oc parallel. line_buffer ch0 broadcast -> 8 pe_group.
//                   Per group : (>>>8) + sext(bias[g]) -> ReLU + upper sat ->
//                   8 oc packed into one 128-bit output word.
//     L2 (layer=1): 8 ic parallel. line_buffer[g] = uram_data slot g -> 8 pe_group.
//                   pair sum (4 pairs) -> 4-way sum (>>>8) + sext(bias[oc_sel])
//                   -> ReLU + upper sat -> slot 0 output.
//     L3 (layer=2): 8 ic parallel. Same accumulation as L2 with bias[0] and
//                   bidirectional sat (no ReLU).
//
//   Weight word : 128-bit = 8 x 16-bit slot. slot s = bits[16*(MAX_CH-1-s) +: 16].
//
//   Pipeline (after pe_group 3-clk latency):
//     Stage 1 : partial / pair sum            (32-bit Q16.16)
//     Stage 2 : (>>>8) + sext(bias)           (32-bit Q24.8 wide form)
//     Stage 3 : Q8.8 saturation (inline ? :)  (16-bit per slot, packed to output)
//
//   o_img_done : pe_done[0] delayed by 3 stages to align with pipeline output.

module PU #(
    parameter MAX_CH = 8
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_dispatch_rst,

    input  wire [1:0]                 i_layer_cnt,    // 0:L1, 1:L2, 2:L3
    input  wire [2:0]                 i_out_ch_cnt,   // L2 oc selector (bias mux)

    input  wire                       i_input_valid,
    input  wire [MAX_CH*16-1:0]       i_uram_data,
    input  wire                       i_is_pad_valid,

    input  wire                       i_w_rd_en,
    input  wire [MAX_CH*16-1:0]       i_weight_bram_data,
    input  wire                       i_bias_en,

    output reg                        o_pixel_valid,
    output reg  [MAX_CH*16-1:0]       o_pixel_data,
    output wire                       o_img_done
);
    // ------------------------------------------------------------------
    // Weight tap dispatcher
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
    // Per-channel input mux (L1 broadcasts slot 0; L2/L3 use slot g).
    // ------------------------------------------------------------------
    wire w_is_L1 = (i_layer_cnt == 2'd0);

    wire signed [15:0] w_lb_data  [0:MAX_CH-1];
    wire               w_lb_valid [0:MAX_CH-1];

    genvar g;
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_mux
            wire signed [15:0] ch_raw =
                w_is_L1 ? $signed(i_uram_data[16*(MAX_CH-1) +: 16])
                        : $signed(i_uram_data[16*((MAX_CH-1)-g) +: 16]);
            assign w_lb_data[g]  = i_is_pad_valid ? 16'sd0 : ch_raw;
            assign w_lb_valid[g] = i_is_pad_valid ? 1'b1   : i_input_valid;
        end
    endgenerate

    // ------------------------------------------------------------------
    // 8 x line_buffer_improved (3x3 window per channel)
    // ------------------------------------------------------------------
    wire [16*9-1:0] w_line_data    [0:MAX_CH-1];
    wire            w_line_valid   [0:MAX_CH-1];
    wire            w_line_rd_done [0:MAX_CH-1];
    wire            w_line_img_done[0:MAX_CH-1];

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb
            line_buffer_improved #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(3), .DATA_BIT(16)
            ) u_line_buffer (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (w_lb_valid[g]),
                .i_input_data   (w_lb_data[g]),
                .o_line_data    (w_line_data[g]),
                .o_line_valid   (w_line_valid[g]),
                .o_line_rd_done (w_line_rd_done[g]),
                .o_img_done     (w_line_img_done[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 8 x pe_group (32-bit Q16.16 output)
    // ------------------------------------------------------------------
    wire               w_pe_valid [0:MAX_CH-1];
    wire signed [31:0] w_partial  [0:MAX_CH-1];
    wire               w_pe_done  [0:MAX_CH-1];

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_pe
            pe_group u_pe_group (
                .i_clk           (i_clk),
                .i_rstn          (i_rstn),
                .i_line_valid    (w_line_valid[g]),
                .i_line_data     (w_line_data[g]),
                .i_weight        (w_weight[g]),
                .i_w_tap_en      (w_tap_en),
                .i_line_img_done (w_line_img_done[g]),
                .o_valid         (w_pe_valid[g]),
                .o_partial       (w_partial[g]),
                .o_pe_done       (w_pe_done[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Pipeline registers (3 stages, all 32-bit signed Q16.16 / Q24.8)
    // ------------------------------------------------------------------
    reg signed [31:0] r_add_stage1 [0:MAX_CH-1];   // L1: pass, L2/L3: pair sum
    reg signed [31:0] r_add_total  [0:MAX_CH-1];   // (>>>8) + sext bias
    reg [1:0]         r_layer_s1, r_layer_s2;
    reg               r_valid_s1, r_valid_s2;

    integer si;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (si = 0; si < MAX_CH; si = si + 1) begin
                r_add_stage1[si] <= 0;
                r_add_total[si]  <= 0;
            end
            { r_valid_s1, r_valid_s2 } <= 2'b0;
            { r_layer_s1, r_layer_s2 } <= 4'b0;
        end else begin
            // Valid / layer pipeline
            r_valid_s1 <= w_pe_valid[0];
            r_valid_s2 <= r_valid_s1;
            r_layer_s1 <= i_layer_cnt;
            r_layer_s2 <= r_layer_s1;

            // ---- Stage 1 : partial / pair sum (Q16.16) ----
            case (i_layer_cnt)
                2'd0: begin // L1 : pass through, per-oc
                    r_add_stage1[0] <= w_partial[0];
                    r_add_stage1[1] <= w_partial[1];
                    r_add_stage1[2] <= w_partial[2];
                    r_add_stage1[3] <= w_partial[3];
                    r_add_stage1[4] <= w_partial[4];
                    r_add_stage1[5] <= w_partial[5];
                    r_add_stage1[6] <= w_partial[6];
                    r_add_stage1[7] <= w_partial[7];
                end
                2'd1, 2'd2: begin // L2 / L3 : pair sum
                    r_add_stage1[0] <= w_partial[0] + w_partial[1];
                    r_add_stage1[1] <= w_partial[2] + w_partial[3];
                    r_add_stage1[2] <= w_partial[4] + w_partial[5];
                    r_add_stage1[3] <= w_partial[6] + w_partial[7];
                    r_add_stage1[4] <= 0;
                    r_add_stage1[5] <= 0;
                    r_add_stage1[6] <= 0;
                    r_add_stage1[7] <= 0;
                end
                default: begin
                    for (si = 0; si < MAX_CH; si = si + 1) r_add_stage1[si] <= 0;
                end
            endcase

            // ---- Stage 2 : (>>>8) + sext(bias)  (Q24.8 wide form) ----
            case (r_layer_s1)
                2'd0: begin // L1 : per-oc shift + bias
                    r_add_total[0] <= (r_add_stage1[0] >>> 8) + {{16{r_bias[0][15]}}, r_bias[0]};
                    r_add_total[1] <= (r_add_stage1[1] >>> 8) + {{16{r_bias[1][15]}}, r_bias[1]};
                    r_add_total[2] <= (r_add_stage1[2] >>> 8) + {{16{r_bias[2][15]}}, r_bias[2]};
                    r_add_total[3] <= (r_add_stage1[3] >>> 8) + {{16{r_bias[3][15]}}, r_bias[3]};
                    r_add_total[4] <= (r_add_stage1[4] >>> 8) + {{16{r_bias[4][15]}}, r_bias[4]};
                    r_add_total[5] <= (r_add_stage1[5] >>> 8) + {{16{r_bias[5][15]}}, r_bias[5]};
                    r_add_total[6] <= (r_add_stage1[6] >>> 8) + {{16{r_bias[6][15]}}, r_bias[6]};
                    r_add_total[7] <= (r_add_stage1[7] >>> 8) + {{16{r_bias[7][15]}}, r_bias[7]};
                end
                2'd1: begin // L2 : 4-way sum, bias[oc_sel]
                    r_add_total[0] <= ((r_add_stage1[0] + r_add_stage1[1]
                                      + r_add_stage1[2] + r_add_stage1[3]) >>> 8)
                                    + {{16{w_L2_bias[15]}}, w_L2_bias};
                    for (si = 1; si < MAX_CH; si = si + 1) r_add_total[si] <= 0;
                end
                2'd2: begin // L3 : 4-way sum, bias[0]
                    r_add_total[0] <= ((r_add_stage1[0] + r_add_stage1[1]
                                      + r_add_stage1[2] + r_add_stage1[3]) >>> 8)
                                    + {{16{r_bias[0][15]}}, r_bias[0]};
                    for (si = 1; si < MAX_CH; si = si + 1) r_add_total[si] <= 0;
                end
                default: begin
                    for (si = 0; si < MAX_CH; si = si + 1) r_add_total[si] <= 0;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Stage 3 / Output : inline Q8.8 saturation, then pack into 128-bit word.
    //   L1 / L2 : ReLU + upper sat  ([0, 0x7FFF])
    //   L3      : bidirectional sat ([-0x8000, 0x7FFF])
    // ------------------------------------------------------------------
    integer oi;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            o_pixel_valid <= r_valid_s2;
            o_pixel_data  <= 0;
            case (r_layer_s2)
                2'd0: begin // L1 : 8 oc packed, ReLU + upper sat
                    for (oi = 0; oi < MAX_CH; oi = oi + 1) begin
                        o_pixel_data[16*((MAX_CH-1)-oi) +: 16] <=
                            (r_add_total[oi][31])              ? 16'sd0      :
                            (r_add_total[oi] > 32'sd32767)     ? 16'sd32767  :
                                                                 r_add_total[oi][15:0];
                    end
                end
                2'd1: begin // L2 : slot 0, ReLU + upper sat
                    o_pixel_data[16*(MAX_CH-1) +: 16] <=
                        (r_add_total[0][31])              ? 16'sd0      :
                        (r_add_total[0] > 32'sd32767)     ? 16'sd32767  :
                                                            r_add_total[0][15:0];
                end
                2'd2: begin // L3 : slot 0, bidirectional sat
                    o_pixel_data[16*(MAX_CH-1) +: 16] <=
                        (r_add_total[0] >  32'sd32767)  ? 16'sh7FFF :
                        (r_add_total[0] < -32'sd32768)  ? 16'sh8000 :
                                                          r_add_total[0][15:0];
                end
                default: o_pixel_data <= 0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // o_img_done : pe_done[0] (+3 from line_buffer) + 3 (Stage1/2/3)
    // ------------------------------------------------------------------
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0]),
        .dout (o_img_done)
    );
endmodule
