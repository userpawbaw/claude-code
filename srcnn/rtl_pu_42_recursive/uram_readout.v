`timescale 1ns / 1ps
// uram_readout.v — 128-bit URAM → 64-bit×2 직렬 출력 드라이버.
//
// 동작 요약:
//   i_start (o_out_we 레벨/펄스) 수신 → 래치 후 자동 동작, 이후 신호 무시.
//   2-클럭 주기:
//     phase=0 : o_rd_en=1 발행 + lower-half(r_buf_lo) 출력
//     phase=1 : 1-clk latency 수신(i_rd_valid) + upper-half 출력 (wire 직결)
//   총 TOTAL_OUT(=5625) 회 64-bit 출력 완료 후 o_done 1-clk 펄스 + 자동 리셋.
//
// URAM 가정: rd_en → 다음 클럭 i_rd_valid=1 (1-clk latency, simple_dual_port_uram 기준).
//
// 출력 wire:
//   o_data = phase=1 → i_rd_data[127:64] (수신 즉시 와이어 연결)
//            phase=0 → r_buf_lo          (전 사이클에 래치된 하위 64-bit)

module uram_readout #(
    parameter TOTAL_OUT  = 5625,    // 22500 px / 4 px_per_64b
    parameter ADDR_BITS  = 13
)(
    input  wire                  i_clk,
    input  wire                  i_rstn,
    input  wire                  i_start,        // o_out_we; 레벨 OK, 첫 수신에서 래치

    output reg                   o_rd_en,
    output reg  [ADDR_BITS-1:0]  o_rd_addr,
    input  wire                  i_rd_valid,
    input  wire [127:0]          i_rd_data,

    output wire  [63:0]          o_data,         // 와이어: phase=1→upper, phase=0→lower
    output reg                   o_valid,
    output reg                   o_done           // 1-clk 펄스: 마지막 출력 다음 cycle
);

    localparam RD_TOTAL = (TOTAL_OUT + 1) / 2;  // ceil(5625/2) = 2813

    reg          r_run;
    reg          r_phase;    // 0: rd_en+lower출력, 1: 수신+upper출력
    reg  [63:0]  r_buf_lo;   // 수신된 128-bit 중 lower 64-bit 저장 (phase=0 출력용)
    reg  [12:0]  r_rd_cnt;   // 발행된 rd_en 횟수 (0..RD_TOTAL-1)
    reg  [12:0]  r_out_cnt;  // 완료된 64-bit 출력 횟수 (0..TOTAL_OUT-1)

    // 출력 와이어: 레지스터 경유 없이 직결
    assign o_data = r_phase ? i_rd_data[127:64] : r_buf_lo;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_run     <= 1'b0;
            r_phase   <= 1'b0;
            r_buf_lo  <= 64'h0;
            r_rd_cnt  <= 13'h0;
            r_out_cnt <= 13'h0;
            o_rd_en   <= 1'b0;
            o_rd_addr <= {ADDR_BITS{1'b0}};
            o_valid   <= 1'b0;
            o_done    <= 1'b0;
        end else begin
            o_done  <= 1'b0;
            o_rd_en <= 1'b0;    // 매 사이클 기본 deassert, phase=0 에서만 set

            if (!r_run) begin
                o_valid <= 1'b0;
                if (i_start)
                    r_run <= 1'b1;   // 래치: 이후 i_start 무시

            end else begin
                case (r_phase)

                // ── phase 0: rd_en 발행 + lower-half 출력 ───────────────
                1'b0: begin
                    // rd_en 발행 (아직 전송할 게 남은 경우)
                    if (r_rd_cnt < RD_TOTAL) begin
                        o_rd_en   <= 1'b1;
                        o_rd_addr <= r_rd_cnt;
                        r_rd_cnt  <= r_rd_cnt + 1'b1;
                    end

                    // lower-half 출력: 첫 phase=0 (r_out_cnt==0) 은 데이터 없으므로 스킵
                    if (r_out_cnt > 0 && r_out_cnt < TOTAL_OUT) begin
                        o_valid   <= 1'b1;
                        r_out_cnt <= r_out_cnt + 1'b1;
                    end else begin
                        o_valid <= 1'b0;
                    end

                    r_phase <= 1'b1;
                end

                // ── phase 1: 128-bit 수신 + upper-half 출력 ─────────────
                1'b1: begin
                    if (i_rd_valid) begin
                        r_buf_lo <= i_rd_data[63:0];   // lower 래치 (다음 phase=0 출력용)
                        o_valid  <= 1'b1;

                        if (r_out_cnt + 1'b1 == TOTAL_OUT) begin
                            // 마지막 출력: done 펄스 + 전체 리셋 (다음 이미지 대비)
                            o_done    <= 1'b1;
                            r_run     <= 1'b0;
                            r_phase   <= 1'b0;
                            r_rd_cnt  <= 13'h0;
                            r_out_cnt <= 13'h0;
                        end else begin
                            r_out_cnt <= r_out_cnt + 1'b1;
                            r_phase   <= 1'b0;
                        end
                    end else begin
                        o_valid <= 1'b0;   // URAM latency mismatch 대비
                    end
                end

                endcase
            end
        end
    end

endmodule
