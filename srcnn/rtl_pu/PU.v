`timescale 1ns / 1ps
// PU : 단일 PU (recursive 구조). i_layer_cnt 로 L1/L2/L3 모드 전환.
//   HW: 4 line_buffer + 4 pe_group + 4 bias reg + 통일 파이프라인.
//   각 layer 별 동작:
//     L1 (layer=0): 4 oc 병렬. line_buffer ch0 broadcast → 4 pe_group(각 다른 weight oc)
//                  → 4 독립 (partial+bias[g]) → 4 refine+ReLU → 4 oc packed 출력.
//     L2 (layer=1): 4 ic 병렬. line_buffer[g]=ch_data[g] → 4 pe_group(같은 oc 의 ic g weight)
//                  → adder tree 4-way → +bias[i_out_ch_cnt] → refine+ReLU → slot0 출력.
//     L3 (layer=2): 2 ic 병렬 (ch 2,3 idle). line_buffer[0,1] → 2 pe_group
//                  → adder tree 2-way → +bias[0] → refine (NO ReLU) → slot0 출력.
//
//   weight sub_max: L1/L2=1, L3=2. 각 word 의 slot 매핑은 아래 코멘트 참조.
//
//   파이프라인 (pe_group 의 3clk 출력 이후):
//     Stage A (1clk): per-(layer) partial 처리.
//       L1: r_sA[g] <= w_partial[g]                          (단순 등록)
//       L2: r_sA[0] <= p0+p1, r_sA[1] <= p2+p3              (쌍합)
//       L3: r_sA[0] <= p0+p1, r_sA[1] <= 0
//     Stage B (1clk): combine + bias.
//       L1: r_sB[g] <= r_sA[g] + bias[g]
//       L2: r_sB[0] <= r_sA[0] + r_sA[1] + bias[i_out_ch_cnt]
//       L3: r_sB[0] <= r_sA[0] + bias[0]
//     Stage C (1clk): refine + (ReLU/clip).
//       L1: o[g_slot] <= ReLU(refine(r_sB[g])) for g=0..3
//       L2: o[slot0] <= ReLU(refine(r_sB[0])), 나머지 0
//       L3: o[slot0] <= refine(r_sB[0]) (NO ReLU), 나머지 0
//
//   img_done : line_buffer.o_img_done 의 pipeline-aligned (3+3=6 clk) 버전.
module PU #(
    parameter MAX_CH = 4
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_dispatch_rst,

    input  wire [1:0]                 i_layer_cnt,   // 0:L1, 1:L2, 2:L3
    input  wire                       i_out_ch_cnt,  // L2 oc selector (bias mux)

    // pixel input
    input  wire                       i_input_valid,
    input  wire [MAX_CH*16-1:0]       i_ch_data,     // L1: ch0 broadcast (top 측 처리),
                                                     // L2: 4ch, L3: ch0..1
    input  wire                       i_is_pad_valid,

    // weight / bias
    input  wire                       i_w_rd_valid,
    input  wire [63:0]                i_w_word,
    input  wire                       i_bias_en,

    // output (L1: 4 oc packed, L2/L3: slot 0)
    output reg                        o_pixel_valid,
    output reg  [MAX_CH*16-1:0]       o_pixel_data,
    output wire                       o_img_done
);
    // ------------------------------------------------------------------
    // Weight dispatcher (sub_max-aware)
    //   L1/L2 (sub_max=1):
    //     w_rd_valid 펄스마다 tap_cnt 0..8 진행, tap_en=onehot(tap_cnt).
    //     pe_group[g] weight = i_w_word[48 - 16*g +: 16]  (slot g)
    //   L3 (sub_max=2):
    //     w_rd_valid 펄스 (sub0): tap_cnt, sub_state<=1, latch word.
    //       pe_group[0] = i_w_word[48 +: 16] (slot0), pe_group[1] = i_w_word[16 +: 16] (slot2)
    //     next clk (sub1): tap_cnt+1.
    //       pe_group[0] = r_word_lat[32 +: 16] (slot1), pe_group[1] = r_word_lat[0 +: 16] (slot3)
    //     pe_group[2,3] = don't care (L3 는 2 ic 만 사용).
    // ------------------------------------------------------------------
    wire w_L3 = (i_layer_cnt == 2'd2);

    reg [3:0]  tap_cnt;
    reg        sub_state;       // L3 만 사용
    reg [63:0] r_word_lat;

    wire w_can_sub0 = (i_w_rd_valid && !i_bias_en) && (tap_cnt < 4'd9);
    wire w_can_sub1 = w_L3 && (sub_state == 1'b1) && (tap_cnt < 4'd9);

    // combinational tap_en : pe.i_en_w 와 BRAM dout 정렬 (PE.v 가 다음 clk latch)
    wire [8:0] tap_en =
        (w_can_sub0 || w_can_sub1) ? (9'd1 << tap_cnt) : 9'd0;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            tap_cnt    <= 0;
            sub_state  <= 0;
            r_word_lat <= 0;
        end else if (i_dispatch_rst) begin
            tap_cnt    <= 0;
            sub_state  <= 0;
            r_word_lat <= 0;
        end else begin
            if (w_can_sub0) begin
                tap_cnt    <= tap_cnt + 4'd1;
                r_word_lat <= i_w_word;
                sub_state  <= w_L3 ? 1'b1 : 1'b0;
            end else if (w_can_sub1) begin
                tap_cnt   <= tap_cnt + 4'd1;
                sub_state <= 1'b0;
            end else begin
                sub_state <= 1'b0;
            end
        end
    end

    // per pe_group g 의 weight bus
    wire signed [15:0] w_weight [0:MAX_CH-1];
    // L1/L2: slot g of i_w_word
    // L3 sub0: g0=slot0(63:48), g1=slot2(31:16)
    // L3 sub1: g0=slot1(47:32) from r_word_lat, g1=slot3(15:0) from r_word_lat
    assign w_weight[0] = w_L3 ? (w_can_sub0 ? i_w_word[48 +: 16] : r_word_lat[32 +: 16])
                              : i_w_word[48 +: 16];
    assign w_weight[1] = w_L3 ? (w_can_sub0 ? i_w_word[16 +: 16] : r_word_lat[0  +: 16])
                              : i_w_word[32 +: 16];
    assign w_weight[2] = i_w_word[16 +: 16];   // L3 는 미사용
    assign w_weight[3] = i_w_word[0  +: 16];   // L3 는 미사용

    // ------------------------------------------------------------------
    // bias latch (4 reg, layer 별로 다르게 채움)
    //   L1 (bias word = [b1[0], b1[1], b1[2], b1[3]]) : 모든 slot
    //   L2 (bias word = [b2[0], b2[1], 0, 0])         : slot 0, 1
    //   L3 (bias word = [b3, 0, 0, 0])                : slot 0
    //
    //   r_bias[g] 는 layer 가 그 slot 을 정의하지 않은 경우 0 으로 둠.
    //   (i_bias_en 이 layer 별로 1회 펄스되며, word 는 그 layer 의 bias 임)
    // ------------------------------------------------------------------
    reg signed [15:0] r_bias [0:MAX_CH-1];
    integer ii;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (ii = 0; ii < MAX_CH; ii = ii + 1) r_bias[ii] <= 0;
        end else if (i_bias_en) begin
            // 모든 4 slot 을 그대로 latch. 사용은 layer 별 선택.
            r_bias[0] <= i_w_word[48 +: 16];
            r_bias[1] <= i_w_word[32 +: 16];
            r_bias[2] <= i_w_word[16 +: 16];
            r_bias[3] <= i_w_word[0  +: 16];
        end
    end

    // L2 에서 active bias 선택 (oc0 → r_bias[0], oc1 → r_bias[1])
    wire signed [15:0] w_L2_bias = i_out_ch_cnt ? r_bias[1] : r_bias[0];

    // ------------------------------------------------------------------
    // 4 line_buffer
    //   L1: ch_data[63:48] 가 모든 4 lb 의 입력 (top 측에서 broadcast 해주는 것
    //       을 권장하지만, 안 해도 자체 broadcast).
    //   L2: ch_data 의 4 slot 을 각각 lb[0..3] 에 매핑.
    //   L3: ch_data 의 2 slot 을 lb[0..1] 에 매핑. lb[2..3] idle (data=0, valid=0).
    // ------------------------------------------------------------------
    wire signed [15:0] w_lb_data  [0:MAX_CH-1];
    wire               w_lb_valid [0:MAX_CH-1];

    wire w_L1 = (i_layer_cnt == 2'd0);
    wire w_L2 = (i_layer_cnt == 2'd1);

    genvar g;
    generate
        for (g = 0; g < MAX_CH; g = g + 1) begin : gen_lb_mux
            // ch 선택
            wire signed [15:0] ch_raw =
                w_L1 ? $signed(i_ch_data[16*(MAX_CH-1) +: 16]) :              // L1 broadcast ch0
                w_L2 ? $signed(i_ch_data[16*((MAX_CH-1)-g) +: 16]) :          // L2 4 ch
                       ((g < 2) ? $signed(i_ch_data[16*((MAX_CH-1)-g) +: 16]) : 16'sd0);  // L3 2 ch
            wire ch_v =
                w_L1 ? i_input_valid :
                w_L2 ? i_input_valid :
                       ((g < 2) ? i_input_valid : 1'b0);
            // padding mux
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
    // 4 pe_group
    // ------------------------------------------------------------------
    wire               w_pe_valid [0:MAX_CH-1];
    wire signed [35:0] w_partial  [0:MAX_CH-1];
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
    // 통합 파이프라인 (3 stage) — README spec Q16.16 → (>>>8) → Q8.8 + bias → sat
    //   Stage A : partial 처리 (L1 pass / L2 pair sum / L3 single pair) — 37-bit Q16.16
    //   Stage B : 채널 합 → (>>>8) → 32-bit Q8.8 + sext_bias
    //   Stage C : L1/L2 ReLU+upper sat / L3 bidirectional sat → 16-bit Q8.8
    // ------------------------------------------------------------------
    // Stage A
    reg  signed [36:0] r_sA [0:MAX_CH-1];      // 37-bit Q16.16
    reg                r_vA;
    // Stage B
    reg  signed [31:0] r_sB [0:MAX_CH-1];      // 32-bit Q8.8 (>>>8 + bias)
    reg                r_vB;
    reg [1:0] r_layer_A, r_layer_B;

    function automatic signed [36:0] sext36_37(input signed [35:0] x);
        sext36_37 = {x[35], x};
    endfunction
    function automatic signed [31:0] sext16_32(input signed [15:0] b);
        sext16_32 = {{16{b[15]}}, b};
    endfunction
    // L1 path (and L3 single pair) : 37-bit Q16.16 → (>>>8) → 32-bit Q8.8.
    function automatic signed [31:0] shr8_37(input signed [36:0] x);
        reg signed [36:0] s;
        begin
            s = x >>> 8;
            shr8_37 = s[31:0];
        end
    endfunction
    // L2 path : 2 × 37-bit pair-sum → 38-bit Q16.16 → (>>>8) → 32-bit Q8.8.
    function automatic signed [31:0] sum2_shr8(input signed [36:0] a, input signed [36:0] b);
        reg signed [37:0] s_q1616;
        reg signed [37:0] s_q88;
        begin
            s_q1616  = {a[36], a} + {b[36], b};
            s_q88    = s_q1616 >>> 8;
            sum2_shr8 = s_q88[31:0];
        end
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
        end else begin
            // ---- Stage A ----  Q16.16 누적 유지 (no precision loss)
            r_vA      <= w_pe_valid[0];
            r_layer_A <= i_layer_cnt;
            case (i_layer_cnt)
                2'd0: begin // L1: pass-through (per-oc)
                    r_sA[0] <= sext36_37(w_partial[0]);
                    r_sA[1] <= sext36_37(w_partial[1]);
                    r_sA[2] <= sext36_37(w_partial[2]);
                    r_sA[3] <= sext36_37(w_partial[3]);
                end
                2'd1: begin // L2: pair sum (4 ic → 2 pairs)
                    r_sA[0] <= sext36_37(w_partial[0]) + sext36_37(w_partial[1]);
                    r_sA[1] <= sext36_37(w_partial[2]) + sext36_37(w_partial[3]);
                    r_sA[2] <= 0;
                    r_sA[3] <= 0;
                end
                2'd2: begin // L3: pair sum (2 ic only)
                    r_sA[0] <= sext36_37(w_partial[0]) + sext36_37(w_partial[1]);
                    r_sA[1] <= 0;
                    r_sA[2] <= 0;
                    r_sA[3] <= 0;
                end
                default: begin
                    r_sA[0] <= 0; r_sA[1] <= 0; r_sA[2] <= 0; r_sA[3] <= 0;
                end
            endcase

            // ---- Stage B ----  (>>>8) + bias(Q8.8)
            r_vB      <= r_vA;
            r_layer_B <= r_layer_A;
            case (r_layer_A)
                2'd0: begin // L1: 각 r_sA[g] → 32-bit Q8.8 + bias[g]
                    r_sB[0] <= shr8_37(r_sA[0]) + sext16_32(r_bias[0]);
                    r_sB[1] <= shr8_37(r_sA[1]) + sext16_32(r_bias[1]);
                    r_sB[2] <= shr8_37(r_sA[2]) + sext16_32(r_bias[2]);
                    r_sB[3] <= shr8_37(r_sA[3]) + sext16_32(r_bias[3]);
                end
                2'd1: begin // L2: 2 pair 합 (>>>8) + bias[oc_sel]
                    r_sB[0] <= sum2_shr8(r_sA[0], r_sA[1]) + sext16_32(w_L2_bias);
                    r_sB[1] <= 0; r_sB[2] <= 0; r_sB[3] <= 0;
                end
                2'd2: begin // L3: single pair (>>>8) + bias[0]
                    r_sB[0] <= shr8_37(r_sA[0]) + sext16_32(r_bias[0]);
                    r_sB[1] <= 0; r_sB[2] <= 0; r_sB[3] <= 0;
                end
                default: begin
                    r_sB[0] <= 0; r_sB[1] <= 0; r_sB[2] <= 0; r_sB[3] <= 0;
                end
            endcase
        end
    end

    // Stage C : saturate-to-16bit Q8.8
    //   L1/L2 : v<0 → 0, v>0x7FFF → 0x7FFF, else v[15:0]                (ReLU + upper sat)
    //   L3    : v<-0x8000 → 0x8000, v>0x7FFF → 0x7FFF, else v[15:0]     (bidirectional sat)
    function automatic [15:0] sat_relu(input signed [31:0] v);
        if (v[31])           sat_relu = 16'h0000;
        else if (|v[30:15])  sat_relu = 16'h7FFF;
        else                 sat_relu = v[15:0];
    endfunction
    function automatic [15:0] sat_bidir(input signed [31:0] v);
        if      (~v[31] &&  (|v[30:15])) sat_bidir = 16'h7FFF;
        else if ( v[31] && ~(&v[30:15])) sat_bidir = 16'h8000;
        else                             sat_bidir = v[15:0];
    endfunction

    integer kk;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            o_pixel_valid <= r_vB;
            case (r_layer_B)
                2'd0: begin // L1: 4 oc packed, ReLU+sat
                    for (kk = 0; kk < MAX_CH; kk = kk + 1)
                        o_pixel_data[16*((MAX_CH-1)-kk) +: 16] <= sat_relu(r_sB[kk]);
                end
                2'd1: begin // L2: slot 0, ReLU+sat
                    o_pixel_data[48 +: 16] <= sat_relu(r_sB[0]);
                    o_pixel_data[0  +: 48] <= 48'd0;
                end
                2'd2: begin // L3: slot 0, bidirectional sat (no ReLU)
                    o_pixel_data[48 +: 16] <= sat_bidir(r_sB[0]);
                    o_pixel_data[0  +: 48] <= 48'd0;
                end
                default: o_pixel_data <= 0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // o_img_done : pe_done (+3 from line_buffer.img_done) + 3 (pipeline)
    // ------------------------------------------------------------------
    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pe_done[0]),
        .dout (o_img_done)
    );
endmodule
