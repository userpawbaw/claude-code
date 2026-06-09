`timescale 1ns / 1ps
// PU (preset 8_8) : recursive 단일 PU. i_layer_cnt 로 L1/L2/L3 모드 전환.
//
//   ★ DATAFLOW (README spec):
//     - PE       : Q8.8 × Q8.8 → 32-bit Q16.16 (no truncation)
//     - pe_group : 9 PE 의 Q16.16 합 → 36-bit Q16.16
//     - PU stage1: per-layer partial 합 (Q16.16, 더 wide)
//     - PU stage2: 채널 합 → 산술 우시프트 8 (Q16.16 → Q8.8) → + bias(Q8.8)
//     - PU output: L1/L2 ReLU+truncate, L3 양방향 saturate ([-0x8000, 0x7FFF])
//
//   layer 별 동작:
//     L1 (layer=0): 8 oc 병렬. line_buffer ch0 broadcast → 8 pe_group → 각자
//                  bias[g] 합 → ReLU+truncate → 8 oc packed 출력.
//     L2 (layer=1): 8 ic 병렬. line_buffer[g]=uram_data[g] → 8 pe_group →
//                  adder tree 8→1 → bias[i_out_ch_cnt] 합 → ReLU+truncate → slot0.
//     L3 (layer=2): 8 ic 병렬. → adder tree 8→1 → bias[0] 합 → bidirectional
//                  saturate → slot0.
//
//   weight: 128-bit word = 8 × 16-bit slot. sub_max=1.
//   w_weight[g] = i_weight_bram_data[16*(MAX_CH-1-g) +: 16]
//
//   파이프라인 (pe_group 의 3clk 출력 이후):
//     Stage 1 (1clk): per-layer partial.
//       L1: r_add_stage1[g] <= w_partial[g]            (37-bit Q16.16, sext)
//       L2/L3: pair sum (4 pair) → r_add_stage1[0..3]  (37-bit Q16.16)
//     Stage 2 (1clk): final 합 + (>>8) + bias.
//       L1: r_out_q88[g] <= (r_add_stage1[g] >>> 8) + sext(r_bias[g])
//       L2: r_out_q88[0] <= (Σ r_add_stage1[0..3] >>> 8) + sext(w_L2_bias)
//       L3: r_out_q88[0] <= (Σ r_add_stage1[0..3] >>> 8) + sext(r_bias[0])
//     Output stage (1clk): saturate.
//       L1/L2: ReLU(neg→0) + upper clip 0x7FFF
//       L3   : bidirectional [-0x8000, 0x7FFF]
//
//   o_img_done : pe_group[0].o_pe_done 의 pipeline-aligned (+3) 버전.
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
    input  wire [MAX_CH*16-1:0]       i_uram_data,
    input  wire                       i_is_pad_valid,

    // weight / bias  (128-bit word)
    input  wire                       i_w_rd_en,
    input  wire [MAX_CH*16-1:0]       i_weight_bram_data,
    input  wire                       i_bias_en,

    // output (L1: 8 oc packed, L2/L3: slot 0)
    output reg                        o_pixel_valid,
    output reg  [MAX_CH*16-1:0]       o_pixel_data,
    output wire                       o_img_done
);
    // ------------------------------------------------------------------
    // Weight dispatcher (sub_max=1 일관)
    // ------------------------------------------------------------------
    reg [3:0]  tap_cnt;
    wire [8:0] tap_en =
        (i_w_rd_en && !i_bias_en && (tap_cnt < 4'd9)) ? (9'd1 << tap_cnt) : 9'd0;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)            tap_cnt <= 0;
        else if (i_dispatch_rst) tap_cnt <= 0;
        else if (i_w_rd_en && !i_bias_en && (tap_cnt < 4'd9))
            tap_cnt <= tap_cnt + 4'd1;
    end

    wire signed [15:0] w_weight [0:MAX_CH-1];
    genvar gw;
    generate
        for (gw = 0; gw < MAX_CH; gw = gw + 1) begin : gen_w_slot
            assign w_weight[gw] = i_weight_bram_data[16*((MAX_CH-1)-gw) +: 16];
        end
    endgenerate

    // ------------------------------------------------------------------
    // bias latch (MAX_CH regs, 8 slot 모두 캡처)
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias [0:MAX_CH-1];
    integer ii;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (ii = 0; ii < MAX_CH; ii = ii + 1) r_bias[ii] <= 0;
        end else if (i_bias_en) begin
            for (ii = 0; ii < MAX_CH; ii = ii + 1)
                r_bias[ii] <= i_weight_bram_data[16*((MAX_CH-1)-ii) +: 16];
        end
    end

    // L2 의 oc 선택 (FSM 이 image 동안 stable 유지하므로 live mux).
    wire signed [15:0] w_L2_bias = r_bias[i_out_ch_cnt];

    // ------------------------------------------------------------------
    // ch routing : layer 별 mux
    //   L1: 모든 g 는 uram_data slot 0 (= 최상위 16-bit) broadcast
    //   L2/L3: g = slot g
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
                w_L1 ? $signed(i_uram_data[16*(MAX_CH-1) +: 16])
                     : $signed(i_uram_data[16*((MAX_CH-1)-g) +: 16]);
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
    // 8 pe_group (Q16.16 36-bit output)
    // ------------------------------------------------------------------
    wire               w_pe_valid [0:MAX_CH-1];
    wire signed [35:0] w_partial  [0:MAX_CH-1];
    wire               w_pe_done  [0:MAX_CH-1];

    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_pe
            pe_group u_pe_group (
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
    //   Stage 1 : partial 처리 (L1 pass / L2,L3 pair sum) — Q16.16
    //   Stage 2 : final 합 + (>>8) + bias(Q8.8) — Q8.8 with extended int
    //   Output  : ReLU/saturate → 16-bit Q8.8
    // ------------------------------------------------------------------
    // Stage 1 width : 37-bit (pair sum of 36-bit Q16.16 → +1 bit)
    reg  signed [36:0] r_add_stage1 [0:MAX_CH-1];
    reg                r_valid_stage1;
    reg  [1:0]         r_layer_stage1;

    // Stage 2 width : 32-bit Q8.8 with extended int (>>8 of ~39-bit + bias).
    //   L1 path  : (37 >>> 8) = 29-bit + bias 16 → 30-bit
    //   L2/L3    : sum of 4 × 37-bit (39-bit) >>> 8 = 31-bit + bias → 32-bit
    //   통일하여 32-bit 사용.
    reg  signed [31:0] r_out_q88 [0:MAX_CH-1];
    reg                r_valid_stage2;
    reg  [1:0]         r_layer_stage2;

    function automatic signed [36:0] sext36_37(input signed [35:0] x);
        sext36_37 = {x[35], x};
    endfunction
    function automatic signed [31:0] sext16_32(input signed [15:0] b);
        sext16_32 = {{16{b[15]}}, b};
    endfunction
    // L1 path : 37-bit Q16.16 (>>> 8) → 32-bit Q8.8 (sext truncate).
    function automatic signed [31:0] shr8_37(input signed [36:0] x);
        reg signed [36:0] s;
        begin
            s = x >>> 8;        // arithmetic shift; sign-extends MSB
            shr8_37 = s[31:0];  // 하위 32-bit (upper sign bits 안전)
        end
    endfunction
    // L2/L3 path : 4 × 37-bit pair-sum → 39-bit Q16.16 → (>>> 8) → 32-bit Q8.8.
    function automatic signed [31:0] sum4_shr8(
        input signed [36:0] a, input signed [36:0] b,
        input signed [36:0] c, input signed [36:0] d
    );
        reg signed [38:0] s_q1616;
        reg signed [38:0] s_q88_wide;
        begin
            s_q1616    = {{2{a[36]}}, a} + {{2{b[36]}}, b}
                       + {{2{c[36]}}, c} + {{2{d[36]}}, d};
            s_q88_wide = s_q1616 >>> 8;   // arithmetic
            sum4_shr8  = s_q88_wide[31:0];
        end
    endfunction

    integer j;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (j = 0; j < MAX_CH; j = j + 1) begin
                r_add_stage1[j] <= 0;
                r_out_q88[j]    <= 0;
            end
            r_valid_stage1 <= 0;  r_valid_stage2 <= 0;
            r_layer_stage1 <= 0;  r_layer_stage2 <= 0;
        end else begin
            // ---- Stage 1 ----
            r_valid_stage1 <= w_pe_valid[0];
            r_layer_stage1 <= i_layer_cnt;
            case (i_layer_cnt)
                2'd0: begin // L1 pass : 36 → 37 sext
                    r_add_stage1[0] <= sext36_37(w_partial[0]);
                    r_add_stage1[1] <= sext36_37(w_partial[1]);
                    r_add_stage1[2] <= sext36_37(w_partial[2]);
                    r_add_stage1[3] <= sext36_37(w_partial[3]);
                    r_add_stage1[4] <= sext36_37(w_partial[4]);
                    r_add_stage1[5] <= sext36_37(w_partial[5]);
                    r_add_stage1[6] <= sext36_37(w_partial[6]);
                    r_add_stage1[7] <= sext36_37(w_partial[7]);
                end
                2'd1, 2'd2: begin // L2/L3 pair sum : 36 + 36 → 37
                    r_add_stage1[0] <= sext36_37(w_partial[0]) + sext36_37(w_partial[1]);
                    r_add_stage1[1] <= sext36_37(w_partial[2]) + sext36_37(w_partial[3]);
                    r_add_stage1[2] <= sext36_37(w_partial[4]) + sext36_37(w_partial[5]);
                    r_add_stage1[3] <= sext36_37(w_partial[6]) + sext36_37(w_partial[7]);
                    r_add_stage1[4] <= 0; r_add_stage1[5] <= 0;
                    r_add_stage1[6] <= 0; r_add_stage1[7] <= 0;
                end
                default: begin
                    for (j = 0; j < MAX_CH; j = j + 1) r_add_stage1[j] <= 0;
                end
            endcase

            // ---- Stage 2 : >>>8  +  bias(Q8.8) ----
            r_valid_stage2 <= r_valid_stage1;
            r_layer_stage2 <= r_layer_stage1;
            case (r_layer_stage1)
                2'd0: begin // L1: per-oc, 각 r_add_stage1[g] 단일 (>>>8) + bias
                    r_out_q88[0] <= shr8_37(r_add_stage1[0]) + sext16_32(r_bias[0]);
                    r_out_q88[1] <= shr8_37(r_add_stage1[1]) + sext16_32(r_bias[1]);
                    r_out_q88[2] <= shr8_37(r_add_stage1[2]) + sext16_32(r_bias[2]);
                    r_out_q88[3] <= shr8_37(r_add_stage1[3]) + sext16_32(r_bias[3]);
                    r_out_q88[4] <= shr8_37(r_add_stage1[4]) + sext16_32(r_bias[4]);
                    r_out_q88[5] <= shr8_37(r_add_stage1[5]) + sext16_32(r_bias[5]);
                    r_out_q88[6] <= shr8_37(r_add_stage1[6]) + sext16_32(r_bias[6]);
                    r_out_q88[7] <= shr8_37(r_add_stage1[7]) + sext16_32(r_bias[7]);
                end
                2'd1: begin // L2: Σ4 pair-sum 후 >>>8 + bias[oc_sel]
                    r_out_q88[0] <= sum4_shr8(r_add_stage1[0], r_add_stage1[1],
                                              r_add_stage1[2], r_add_stage1[3])
                                  + sext16_32(w_L2_bias);
                    r_out_q88[1] <= 0; r_out_q88[2] <= 0; r_out_q88[3] <= 0;
                    r_out_q88[4] <= 0; r_out_q88[5] <= 0; r_out_q88[6] <= 0; r_out_q88[7] <= 0;
                end
                2'd2: begin // L3: 동일, bias[0]
                    r_out_q88[0] <= sum4_shr8(r_add_stage1[0], r_add_stage1[1],
                                              r_add_stage1[2], r_add_stage1[3])
                                  + sext16_32(r_bias[0]);
                    r_out_q88[1] <= 0; r_out_q88[2] <= 0; r_out_q88[3] <= 0;
                    r_out_q88[4] <= 0; r_out_q88[5] <= 0; r_out_q88[6] <= 0; r_out_q88[7] <= 0;
                end
                default: begin
                    for (j = 0; j < MAX_CH; j = j + 1) r_out_q88[j] <= 0;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Output stage : saturate-to-16bit Q8.8
    //   L1/L2 : v<0 → 0, v>0x7FFF → 0x7FFF, else v[15:0]                (ReLU + upper sat)
    //   L3    : v<-0x8000 → 0x8000, v>0x7FFF → 0x7FFF, else v[15:0]     (bidirectional sat)
    // 32-bit signed 에서 16-bit signed 로 saturate 검사 :
    //   pos_ovf = (v[31]==0) && (|v[30:15])
    //   neg_ovf = (v[31]==1) && (~&v[30:15])
    // ------------------------------------------------------------------
    function automatic [15:0] sat_relu(input signed [31:0] v);
        if (v[31])                          sat_relu = 16'h0000;     // negative → 0
        else if (|v[30:15])                 sat_relu = 16'h7FFF;     // positive overflow
        else                                sat_relu = v[15:0];
    endfunction

    function automatic [15:0] sat_bidir(input signed [31:0] v);
        if      (~v[31] &&  (|v[30:15]))    sat_bidir = 16'h7FFF;    // positive overflow
        else if ( v[31] && ~(&v[30:15]))    sat_bidir = 16'h8000;    // negative overflow
        else                                sat_bidir = v[15:0];
    endfunction

    integer kk;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            o_pixel_valid <= r_valid_stage2;
            case (r_layer_stage2)
                2'd0: begin // L1: 8 oc packed, ReLU+sat
                    for (kk = 0; kk < MAX_CH; kk = kk + 1)
                        o_pixel_data[16*((MAX_CH-1)-kk) +: 16] <= sat_relu(r_out_q88[kk]);
                end
                2'd1: begin // L2: slot 0, ReLU+sat
                    o_pixel_data[16*(MAX_CH-1) +: 16] <= sat_relu(r_out_q88[0]);
                    o_pixel_data[0 +: 16*(MAX_CH-1)] <= {(16*(MAX_CH-1)){1'b0}};
                end
                2'd2: begin // L3: slot 0, bidirectional sat (no ReLU)
                    o_pixel_data[16*(MAX_CH-1) +: 16] <= sat_bidir(r_out_q88[0]);
                    o_pixel_data[0 +: 16*(MAX_CH-1)] <= {(16*(MAX_CH-1)){1'b0}};
                end
                default: o_pixel_data <= 0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // o_img_done : pe_done[0] (+3 from line_buffer) + 3 (pipeline Stage1/2/Out)
    // ------------------------------------------------------------------
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0]),
        .dout (o_img_done)
    );
endmodule
