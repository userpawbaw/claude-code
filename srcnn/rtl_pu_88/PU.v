`timescale 1ns / 1ps
// PU (preset 8_8) : recursive 단일 PU. i_layer_cnt 로 L1/L2/L3 모드 전환.
//   HW: 8 line_buffer + 8 pe_group + 8 bias reg + 통일 파이프라인.
//   각 layer 별 동작:
//     L1 (layer=0): 8 oc 병렬. line_buffer ch0 broadcast → 8 pe_group(각 다른 weight oc)
//                  → 8 독립 (partial+bias[g]) → 8 refine+ReLU → 8 oc packed 출력.
//     L2 (layer=1): 8 ic 병렬. line_buffer[g]=ch_data[g] → 8 pe_group(같은 oc 의 ic g weight)
//                  → adder tree 8→1 → +bias[i_out_ch_cnt] → refine+ReLU → slot0 출력.
//     L3 (layer=2): 8 ic 병렬. line_buffer[g]=ch_data[g] → 8 pe_group
//                  → adder tree 8→1 → +bias[0] → refine (NO ReLU) → slot0 출력.
//
//   weight: 128-bit word = 8 × 16-bit slot. sub_max=1 (모든 layer). dispatcher 가 tap_cnt onehot 으로 tap_en 생성.
//   w_weight[g] = i_w_word[16*(MAX_CH-1-g) +: 16]  (slot g)
//
//   파이프라인 (pe_group 의 3clk 출력 이후):
//     Stage A (1clk): per-(layer) partial.
//       L1: r_sA[g] <= w_partial[g] (pass)
//       L2/L3: r_sA[0]=p0+p1, r_sA[1]=p2+p3, r_sA[2]=p4+p5, r_sA[3]=p6+p7  (pair sums)
//     Stage B (1clk): final sum + bias.
//       L1: r_sB[g] <= r_sA[g] + bias[g]
//       L2: r_sB[0] <= r_sA[0]+r_sA[1]+r_sA[2]+r_sA[3] + bias[i_out_ch_cnt]
//       L3: r_sB[0] <= r_sA[0]+r_sA[1]+r_sA[2]+r_sA[3] + bias[0]
//     Stage C (1clk): refine + (ReLU L1/L2 / none L3).
//
//   img_done : pe_group[0].o_pe_done 의 pipeline-aligned (+3) 버전.
module PU #(
    parameter MAX_CH = 8
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_dispatch_rst,

    input  wire [1:0]                 i_layer_cnt,   // 0:L1, 1:L2, 2:L3
    input  wire [2:0]                 i_out_ch_cnt,  // L2 oc selector (bias mux, 0..7)

    // pixel input
    input  wire                       i_input_valid,
    input  wire [MAX_CH*16-1:0]       i_ch_data,
    input  wire                       i_is_pad_valid,

    // weight / bias  (128-bit word)
    input  wire                       i_w_rd_valid,
    input  wire [MAX_CH*16-1:0]       i_w_word,
    input  wire                       i_bias_en,

    // output (L1: 8 oc packed, L2/L3: slot 0)
    output reg                        o_pixel_valid,
    output reg  [MAX_CH*16-1:0]       o_pixel_data,
    output wire                       o_img_done
);
    // ------------------------------------------------------------------
    // Weight dispatcher (sub_max=1 일관)
    //   w_rd_valid 펄스마다 tap_cnt 0..8, tap_en = onehot(tap_cnt).
    //   pe_group[g] weight = i_w_word slot g
    // ------------------------------------------------------------------
    reg [3:0]  tap_cnt;

    wire [8:0] tap_en =
        (i_w_rd_valid && !i_bias_en && (tap_cnt < 4'd9)) ? (9'd1 << tap_cnt) : 9'd0;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            tap_cnt <= 0;
        end else if (i_dispatch_rst) begin
            tap_cnt <= 0;
        end else if (i_w_rd_valid && !i_bias_en && (tap_cnt < 4'd9)) begin
            tap_cnt <= tap_cnt + 4'd1;
        end
    end

    wire signed [15:0] w_weight [0:MAX_CH-1];
    genvar gw;
    generate
        for (gw = 0; gw < MAX_CH; gw = gw + 1) begin : gen_w_slot
            assign w_weight[gw] = i_w_word[16*((MAX_CH-1)-gw) +: 16];
        end
    endgenerate

    // ------------------------------------------------------------------
    // bias latch (MAX_CH regs, 8 slot 모두 캡처)
    //   L1: 8 oc bias 모두 사용
    //   L2: 8 oc bias 중 i_out_ch_cnt 로 선택
    //   L3: slot 0 만 사용
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias [0:MAX_CH-1];
    integer ii;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (ii = 0; ii < MAX_CH; ii = ii + 1) r_bias[ii] <= 0;
        end else if (i_bias_en) begin
            for (ii = 0; ii < MAX_CH; ii = ii + 1)
                r_bias[ii] <= i_w_word[16*((MAX_CH-1)-ii) +: 16];
        end
    end

    wire signed [15:0] w_L2_bias = r_bias[i_out_ch_cnt];

    // ------------------------------------------------------------------
    // ch routing : layer 별 mux
    //   L1: 모든 g 는 ch_data slot 0 (= 최상위 16-bit) broadcast
    //   L2: g = slot g
    //   L3: g = slot g
    // ------------------------------------------------------------------
    wire w_L1 = (i_layer_cnt == 2'd0);
    wire w_L2 = (i_layer_cnt == 2'd1);
    wire w_L3 = (i_layer_cnt == 2'd2);

    wire signed [15:0] w_lb_data  [0:MAX_CH-1];
    wire               w_lb_valid [0:MAX_CH-1];

    genvar g;
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_mux
            wire signed [15:0] ch_raw =
                w_L1 ? $signed(i_ch_data[16*(MAX_CH-1) +: 16])
                     : $signed(i_ch_data[16*((MAX_CH-1)-g) +: 16]);
            wire ch_v = i_input_valid;
            assign w_lb_data[g]  = i_is_pad_valid ? 16'sd0 : ch_raw;
            assign w_lb_valid[g] = i_is_pad_valid ? 1'b1   : ch_v;
        end
    endgenerate

    wire [16*9-1:0]    w_line_data    [0:MAX_CH-1];
    wire               w_line_valid   [0:MAX_CH-1];
    wire               w_line_rd_done [0:MAX_CH-1];
    wire               w_line_img_done[0:MAX_CH-1];

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb
            line_buffer_improved #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(3), .DATA_BIT(16)
            ) u_lb (
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
    // 8 pe_group
    // ------------------------------------------------------------------
    wire               w_pe_valid [0:MAX_CH-1];
    wire signed [20:0] w_partial  [0:MAX_CH-1];
    wire               w_pe_done  [0:MAX_CH-1];

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_pe
            pe_group u_pe (
                .i_clk           (i_clk),
                .i_rstn          (i_rstn),
                .i_line_valid    (w_line_valid[g]),
                .i_line_data     (w_line_data[g]),
                .i_weight        (w_weight[g]),
                .i_w_tap_en      (tap_en),
                .i_line_img_done (w_line_img_done[g]),
                .o_valid         (w_pe_valid[g]),
                .o_partial       (w_partial[g]),
                .o_pe_done       (w_pe_done[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 통합 파이프라인 3 stage
    // ------------------------------------------------------------------
    // Stage A : 23-bit (pair sum of 21-bit signed → 22-bit; 23 여유)
    reg  signed [22:0] r_sA [0:MAX_CH-1];
    reg                r_vA;
    // Stage B : 26-bit (4-term 합 + bias)
    reg  signed [25:0] r_sB [0:MAX_CH-1];
    reg                r_vB;
    reg [1:0] r_layer_A, r_layer_B;
    reg [2:0] r_out_ch_A, r_out_ch_B;

    function automatic signed [22:0] sext21_23(input signed [20:0] x);
        sext21_23 = {{2{x[20]}}, x};
    endfunction
    function automatic signed [25:0] sext23_26(input signed [22:0] x);
        sext23_26 = {{3{x[22]}}, x};
    endfunction
    function automatic signed [25:0] sext16_26(input signed [15:0] b);
        sext16_26 = {{10{b[15]}}, b};
    endfunction

    integer j;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (j = 0; j < MAX_CH; j = j + 1) begin
                r_sA[j] <= 0;
                r_sB[j] <= 0;
            end
            r_vA <= 0;  r_vB <= 0;
            r_layer_A <= 0; r_layer_B <= 0;
            r_out_ch_A <= 0; r_out_ch_B <= 0;
        end else begin
            // ---- Stage A ----
            r_vA       <= w_pe_valid[0];
            r_layer_A  <= i_layer_cnt;
            r_out_ch_A <= i_out_ch_cnt;
            case (i_layer_cnt)
                2'd0: begin // L1 pass
                    r_sA[0] <= sext21_23(w_partial[0]);
                    r_sA[1] <= sext21_23(w_partial[1]);
                    r_sA[2] <= sext21_23(w_partial[2]);
                    r_sA[3] <= sext21_23(w_partial[3]);
                    r_sA[4] <= sext21_23(w_partial[4]);
                    r_sA[5] <= sext21_23(w_partial[5]);
                    r_sA[6] <= sext21_23(w_partial[6]);
                    r_sA[7] <= sext21_23(w_partial[7]);
                end
                2'd1, 2'd2: begin // L2/L3 pair sum
                    r_sA[0] <= sext21_23(w_partial[0]) + sext21_23(w_partial[1]);
                    r_sA[1] <= sext21_23(w_partial[2]) + sext21_23(w_partial[3]);
                    r_sA[2] <= sext21_23(w_partial[4]) + sext21_23(w_partial[5]);
                    r_sA[3] <= sext21_23(w_partial[6]) + sext21_23(w_partial[7]);
                    r_sA[4] <= 0; r_sA[5] <= 0; r_sA[6] <= 0; r_sA[7] <= 0;
                end
                default: begin
                    for (j = 0; j < MAX_CH; j = j + 1) r_sA[j] <= 0;
                end
            endcase

            // ---- Stage B ----
            r_vB       <= r_vA;
            r_layer_B  <= r_layer_A;
            r_out_ch_B <= r_out_ch_A;
            case (r_layer_A)
                2'd0: begin // L1: per-oc + bias
                    r_sB[0] <= sext23_26(r_sA[0]) + sext16_26(r_bias[0]);
                    r_sB[1] <= sext23_26(r_sA[1]) + sext16_26(r_bias[1]);
                    r_sB[2] <= sext23_26(r_sA[2]) + sext16_26(r_bias[2]);
                    r_sB[3] <= sext23_26(r_sA[3]) + sext16_26(r_bias[3]);
                    r_sB[4] <= sext23_26(r_sA[4]) + sext16_26(r_bias[4]);
                    r_sB[5] <= sext23_26(r_sA[5]) + sext16_26(r_bias[5]);
                    r_sB[6] <= sext23_26(r_sA[6]) + sext16_26(r_bias[6]);
                    r_sB[7] <= sext23_26(r_sA[7]) + sext16_26(r_bias[7]);
                end
                2'd1: begin // L2: full sum + bias[oc_sel]
                    r_sB[0] <= sext23_26(r_sA[0]) + sext23_26(r_sA[1]) +
                               sext23_26(r_sA[2]) + sext23_26(r_sA[3]) +
                               sext16_26(w_L2_bias);
                    r_sB[1] <= 0; r_sB[2] <= 0; r_sB[3] <= 0;
                    r_sB[4] <= 0; r_sB[5] <= 0; r_sB[6] <= 0; r_sB[7] <= 0;
                end
                2'd2: begin // L3: full sum + bias[0]
                    r_sB[0] <= sext23_26(r_sA[0]) + sext23_26(r_sA[1]) +
                               sext23_26(r_sA[2]) + sext23_26(r_sA[3]) +
                               sext16_26(r_bias[0]);
                    r_sB[1] <= 0; r_sB[2] <= 0; r_sB[3] <= 0;
                    r_sB[4] <= 0; r_sB[5] <= 0; r_sB[6] <= 0; r_sB[7] <= 0;
                end
                default: begin
                    for (j = 0; j < MAX_CH; j = j + 1) r_sB[j] <= 0;
                end
            endcase
        end
    end

    // Stage C : refine + ReLU(L1/L2) / none(L3)
    integer kk;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            o_pixel_valid <= r_vB;
            case (r_layer_B)
                2'd0: begin // L1: 8 oc packed, ReLU
                    for (kk = 0; kk < MAX_CH; kk = kk + 1) begin
                        o_pixel_data[16*((MAX_CH-1)-kk) +: 16] <=
                            (r_sB[kk][25]) ? 16'sd0
                                           : {r_sB[kk][25], r_sB[kk][14:0]};
                    end
                end
                2'd1: begin // L2: slot 0 + ReLU
                    o_pixel_data[16*(MAX_CH-1) +: 16] <=
                        (r_sB[0][25]) ? 16'sd0
                                      : {r_sB[0][25], r_sB[0][14:0]};
                    o_pixel_data[0 +: 16*(MAX_CH-1)] <= {(16*(MAX_CH-1)){1'b0}};
                end
                2'd2: begin // L3: slot 0, NO ReLU
                    o_pixel_data[16*(MAX_CH-1) +: 16] <= {r_sB[0][25], r_sB[0][14:0]};
                    o_pixel_data[0 +: 16*(MAX_CH-1)] <= {(16*(MAX_CH-1)){1'b0}};
                end
                default: o_pixel_data <= 0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // o_img_done : pe_done[0] (+3 from line_buffer) + 3 (pipeline A,B,C)
    // ------------------------------------------------------------------
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0]),
        .dout (o_img_done)
    );
endmodule
