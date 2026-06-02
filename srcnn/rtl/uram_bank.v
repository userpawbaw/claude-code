`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : uram_bank.v
// PURPOSE        : 중간 Feature Map URAM 뱅크의 읽기/쓰기 라우팅 로직.
//                  URAM 인스턴스 자체는 top 에서 생성(IP/모델 일관성),
//                  본 모듈은 레이어/출력채널에 따른 주소·enable 라우팅만 담당.
// -----------------------------------------------------------------------------
// URAM 구성 (top 에서 인스턴스):
//   uram_L1[0..3] : Layer1 출력 = Layer2 입력
//   uram_L2[0..1] : Layer2 출력 = Layer3 입력
//   Layer3 출력   : 최종 출력 포트
//
// 쓰기 라우팅 (현재 layer_cnt, out_ch_cnt):
//   L1: 4채널 동시 write -> uram_L1[0..3] 각각 (we_L1[0..3] 모두 활성, 같은 주소)
//       단, L1 은 pe_group 4개가 독립 out_ch 이므로 데이터는 각 채널 독립.
//   L2: uram_L2[out_ch_cnt] 1개 write
//   L3: 최종 출력 (URAM write 없음)
//
// 읽기 라우팅 (입력 채널 병렬):
//   L2 입력: uram_L1[0..3] 4개 동시 read (같은 주소)
//   L3 입력: uram_L2[0..1] 2개 동시 read (같은 주소)
//
//   본 모듈은 we/re/addr 라우팅 신호를 생성하는 조합 로직.
//   Synthesizable : Y
// -FHDR------------------------------------------------------------------------

module uram_bank #(
    parameter ADDR_WIDTH = 13   // 5700 word < 8192 -> 13bit
)(
    input  wire [1:0]               i_layer_cnt,   // 0:L1, 1:L2, 2:L3
    input  wire [1:0]               i_out_ch_cnt,  // 현재 출력 채널

    // 쓰기 요청 (공통)
    input  wire                     i_wr_en,       // 출력 픽셀 write enable (pack writer)
    input  wire [ADDR_WIDTH-1:0]    i_wr_addr,     // write 주소 (출력 픽셀 인덱스>>2)

    // 읽기 요청 (공통)
    input  wire                     i_rd_en,       // intermediate read enable
    input  wire [ADDR_WIDTH-1:0]    i_rd_addr,     // read 주소

    // ---- uram_L1[0..3] write 라우팅 ----
    output reg  [3:0]               o_L1_we,       // 채널별 write enable (one-hot or all)
    output reg  [ADDR_WIDTH-1:0]    o_L1_wr_addr,
    // ---- uram_L1[0..3] read 라우팅 ----
    output reg  [3:0]               o_L1_re,       // L2 입력 시 4채널 동시 read
    output reg  [ADDR_WIDTH-1:0]    o_L1_rd_addr,

    // ---- uram_L2[0..1] write 라우팅 ----
    output reg  [1:0]               o_L2_we,
    output reg  [ADDR_WIDTH-1:0]    o_L2_wr_addr,
    // ---- uram_L2[0..1] read 라우팅 ----
    output reg  [1:0]               o_L2_re,       // L3 입력 시 2채널 동시 read
    output reg  [ADDR_WIDTH-1:0]    o_L2_rd_addr,

    // ---- 최종 출력 (L3 write) ----
    output reg                      o_final_we,
    output reg  [ADDR_WIDTH-1:0]    o_final_addr
);

    always @(*) begin
        // 기본값 클리어
        o_L1_we      = 4'b0000;
        o_L1_wr_addr = {ADDR_WIDTH{1'b0}};
        o_L1_re      = 4'b0000;
        o_L1_rd_addr = {ADDR_WIDTH{1'b0}};
        o_L2_we      = 2'b00;
        o_L2_wr_addr = {ADDR_WIDTH{1'b0}};
        o_L2_re      = 2'b00;
        o_L2_rd_addr = {ADDR_WIDTH{1'b0}};
        o_final_we   = 1'b0;
        o_final_addr = {ADDR_WIDTH{1'b0}};

        case (i_layer_cnt)
            // ============ Layer 1 ============
            // 입력: input BRAM (uram read 없음)
            // 출력: uram_L1[0..3] 4채널 동시 write (각 채널 독립 데이터, 같은 주소)
            2'd0: begin
                o_L1_wr_addr = i_wr_addr;
                if (i_wr_en) o_L1_we = 4'b1111;  // 4채널 동시
            end

            // ============ Layer 2 ============
            // 입력: uram_L1[0..3] 4채널 동시 read
            // 출력: uram_L2[out_ch_cnt] 1채널 write
            2'd1: begin
                o_L1_rd_addr = i_rd_addr;
                if (i_rd_en) o_L1_re = 4'b1111;  // 4채널 동시 read

                o_L2_wr_addr = i_wr_addr;
                if (i_wr_en) begin
                    case (i_out_ch_cnt)
                        2'd0: o_L2_we = 2'b01;
                        2'd1: o_L2_we = 2'b10;
                        default: o_L2_we = 2'b00;
                    endcase
                end
            end

            // ============ Layer 3 ============
            // 입력: uram_L2[0..1] 2채널 동시 read
            // 출력: 최종 출력 포트
            2'd2: begin
                o_L2_rd_addr = i_rd_addr;
                if (i_rd_en) o_L2_re = 2'b11;  // 2채널 동시 read

                o_final_addr = i_wr_addr;
                if (i_wr_en) o_final_we = 1'b1;
            end

            default: ;
        endcase
    end

endmodule
