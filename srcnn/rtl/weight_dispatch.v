`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : weight_dispatch.v
// PURPOSE        : 가중치 BRAM 64bit word 를 레이어별 규칙으로 풀어
//                  PE묶음(최대 4개)들의 9개 weight 슬롯에 순차 공급.
//                  PE 인터페이스(i_en_w 1펄스 = weight 1개 래치)는 유지.
// -----------------------------------------------------------------------------
// 가중치 BRAM 레이아웃 (64bit/word, 슬롯: 파일 맨 왼쪽 = MSB[63:48])
//   표기: K{out_ch}-{in_ch}-{tap}, 모두 1-based
//   Layer 1 (1->4): 9 word, addr 0-8. word당 1슬롯, 4묶음=out_ch
//       word=[K1-1-n][K2-1-n][K3-1-n][K4-1-n]  (in_ch=1 고정)
//       묶음0<-[63:48], 묶음1<-[47:32], 묶음2<-[31:16], 묶음3<-[15:0]
//   Layer 2 (4->2): 18 word, addr 9-26. word당 1슬롯, 4묶음=in_ch
//       word=[K{oc}-1-{tap}][K{oc}-2-{tap}][K{oc}-3-{tap}][K{oc}-4-{tap}]
//       (tap 바깥, out_ch 안쪽 -> oc0 word=addr 9,11,..25 / oc1=10,12,..26)
//       out_ch 순차(2 pass): FSM 이 stride=2 + oc offset 로 9 word 선택.
//       묶음0<-ic1[63:48], 묶음1<-ic2[47:32], 묶음2<-ic3[31:16], 묶음3<-ic4[15:0]
//   Layer 3 (2->1): 5 word, addr 27-31. word당 2슬롯, 2묶음=in_ch
//       word=[ic1-t0][ic1-t1][ic2-t0][ic2-t1] (연속 2탭, 마지막 0패딩)
//       묶음0(ic1): sub0=[63:48], sub1=[47:32]
//       묶음1(ic2): sub0=[31:16], sub1=[15:0]
//
// 동작:
//   - word 를 받으면(accept) sub_max clk 동안 펼쳐 공급. 그 동안 새 word 거부.
//   - 총 9 슬롯(filled==9)을 채우면 이후 공급 차단.
//   - FSM 은 weight BRAM read 를 sub_max 간격(gap)으로 진행:
//       L1 gap=1(9word), L2 gap=1(9word, stride=2 주소), L3 gap=2(5word).
//   - 검증: Python cycle 모델로 L1/L2/L3 모두 9슬롯 정확 분배 확인 완료.
//
//   Reset Strategy : Asynchronous, active low (i_rstn)
//   Synthesizable  : Y
// -FHDR------------------------------------------------------------------------

module weight_dispatch #(
    parameter MAX_GROUP = 4
)(
    input  wire                    i_clk,
    input  wire                    i_rstn,
    input  wire                    i_dispatch_rst,  // 레이어/출력채널 전환 시 카운터 초기화
    input  wire [1:0]              i_layer_cnt,     // 0:L1, 1:L2, 2:L3
    input  wire                    i_wword_valid,   // weight BRAM rd_valid
    input  wire [63:0]             i_wword,         // weight BRAM 64bit 출력

    // PE묶음별 weight 공급 (flatten): [g] = slice(16*g) / slice(9*g)
    output reg  [16*MAX_GROUP-1:0] o_weight,
    output reg  [9*MAX_GROUP-1:0]  o_wen
);

    // -------------------------------------------------------------------------
    // 레이어별 word당 서브슬롯 수
    // -------------------------------------------------------------------------
    reg [1:0] sub_max;
    always @(*) begin
        case (i_layer_cnt)
            2'd0:    sub_max = 2'd1;  // L1: word당 1슬롯, 4묶음(out_ch) 동시
            2'd1:    sub_max = 2'd1;  // L2(신): word당 1슬롯, 4묶음(in_ch) 동시
            2'd2:    sub_max = 2'd2;  // L3(신): word당 2슬롯, 2묶음(in_ch)
            default: sub_max = 2'd1;
        endcase
    end

    // -------------------------------------------------------------------------
    // 진행 카운터
    // -------------------------------------------------------------------------
    reg [3:0]  slot_cnt;    // 0..8
    reg [1:0]  busy_cnt;    // 남은 펼침 clk (sub_max-1 -> 0)
    reg [63:0] word_lat;    // 펼치는 동안 word 유지
    reg [3:0]  filled;      // 채운 슬롯 수 (0..9)

    wire       all_done   = (filled >= 4'd9);
    wire       accept     = i_wword_valid && (busy_cnt == 2'd0) && !all_done;
    wire       supply_en  = (accept || (busy_cnt != 2'd0)) && !all_done;

    wire [63:0] cur_word  = accept ? i_wword : word_lat;
    // 현재 서브슬롯 인덱스: accept clk 은 0, 이후는 (sub_max - busy_cnt)
    wire [1:0]  cur_sub   = accept ? 2'd0 : (sub_max - busy_cnt);

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            slot_cnt <= 0;
            busy_cnt <= 0;
            word_lat <= 0;
            filled   <= 0;
        end else if (i_dispatch_rst) begin
            slot_cnt <= 0;
            busy_cnt <= 0;
            word_lat <= 0;
            filled   <= 0;
        end else begin
            if (accept) begin
                word_lat <= i_wword;
                busy_cnt <= sub_max - 2'd1;
            end else if (busy_cnt != 2'd0) begin
                busy_cnt <= busy_cnt - 2'd1;
            end

            if (supply_en) begin
                slot_cnt <= (slot_cnt == 4'd8) ? 4'd0 : (slot_cnt + 4'd1);
                filled   <= filled + 4'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 레이어별 weight 슬롯 분배 (조합)
    // -------------------------------------------------------------------------
    always @(*) begin
        o_weight = {16*MAX_GROUP{1'b0}};
        o_wen    = {9*MAX_GROUP{1'b0}};

        if (supply_en) begin
            case (i_layer_cnt)
                // ---- Layer 1: word당 1슬롯, 4묶음(out_ch) 동시 ----
                //   word=[K1-n][K2-n][K3-n][K4-n]
                2'd0: begin
                    o_weight[16*0 +: 16] = cur_word[63:48];
                    o_weight[16*1 +: 16] = cur_word[47:32];
                    o_weight[16*2 +: 16] = cur_word[31:16];
                    o_weight[16*3 +: 16] = cur_word[15:0];
                    o_wen[9*0 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*1 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*2 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*3 +: 9] = (9'd1 << slot_cnt);
                end

                // ---- Layer 2 (신): word당 1슬롯, 4묶음(in_ch) 동시 ----
                //   word=[K{oc}-1-{tap}][K{oc}-2-{tap}][K{oc}-3-{tap}][K{oc}-4-{tap}]
                //   = 같은 (out_ch, tap) 의 입력채널 4개
                //   [63:48]=ic1, [47:32]=ic2, [31:16]=ic3, [15:0]=ic4
                //   (out_ch 선택은 FSM 의 주소 stride 로 처리 — 본 모듈은 동일 분배)
                2'd1: begin
                    o_weight[16*0 +: 16] = cur_word[63:48];
                    o_weight[16*1 +: 16] = cur_word[47:32];
                    o_weight[16*2 +: 16] = cur_word[31:16];
                    o_weight[16*3 +: 16] = cur_word[15:0];
                    o_wen[9*0 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*1 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*2 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*3 +: 9] = (9'd1 << slot_cnt);
                end

                // ---- Layer 3 (신): word당 2슬롯, 2묶음(in_ch) ----
                //   word=[ic1-t0][ic1-t1][ic2-t0][ic2-t1] (연속 2탭)
                //   묶음0(ic1): sub0=[63:48], sub1=[47:32]
                //   묶음1(ic2): sub0=[31:16], sub1=[15:0]
                2'd2: begin
                    if (cur_sub == 2'd0) begin
                        o_weight[16*0 +: 16] = cur_word[63:48];
                        o_weight[16*1 +: 16] = cur_word[31:16];
                    end else begin
                        o_weight[16*0 +: 16] = cur_word[47:32];
                        o_weight[16*1 +: 16] = cur_word[15:0];
                    end
                    o_wen[9*0 +: 9] = (9'd1 << slot_cnt);
                    o_wen[9*1 +: 9] = (9'd1 << slot_cnt);
                end

                default: ;
            endcase
        end
    end

endmodule
