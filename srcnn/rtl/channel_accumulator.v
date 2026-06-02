`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : channel_accumulator.v
// PURPOSE        : 입력 채널 병렬 pe_group 들의 부분합(partial sum)을 누적하여
//                  1개 출력 픽셀을 생성. 입력 채널은 동시(공간축) 누적.
// -----------------------------------------------------------------------------
// 동작:
//   - pe_group 4개가 같은 타이밍에 o_valid/o_partial 을 내므로,
//     한 clk 에 들어온 partial[0..MAX_CH-1] 을 즉시 합산 (시간축 아님).
//   - i_active_ch 로 사용 채널만 합산 (미사용 채널 입력은 0 가정 또는 마스킹).
//       L1: 1 (partial[0]만, 단 L1 은 채널누적 미사용 경로이므로 보통 우회)
//       L2: 4
//       L3: 2
//   - 출력 정제: 설계 프로파일상 누적 결과가 PE 출력 정제 범위를 넘지 않음이 확정.
//     기존 PE.v 규칙과 동일하게 {sign, 하위15bit} 로 16bit 정제 출력.
//   - 파이프라인: 입력 valid -> 1clk 후 합산 결과 valid (PE/adder 와 정렬 위해 1단 등록)
//
//   Reset Strategy : Asynchronous, active low (i_rstn)
//   Synthesizable  : Y
// -FHDR------------------------------------------------------------------------

module channel_accumulator #(
    parameter MAX_CH = 4
)(
    input  wire                        i_clk,
    input  wire                        i_rstn,
    input  wire                        i_valid,
    input  wire [21*MAX_CH-1:0]        i_partial,    // [c] = i_partial[21*c +: 21] (signed)
    input  wire [2:0]                  i_active_ch,  // 1/4/2

    output reg                         o_valid,
    output reg  signed [15:0]          o_data        // 16bit 정제 출력 (PE 규칙)
);

    // -------------------------------------------------------------------------
    // 채널 합산 (조합) — 최대 4채널 누적 여유 위해 23bit
    // i_active_ch 로 사용 채널만 더한다.
    // -------------------------------------------------------------------------
    integer c;
    reg signed [22:0] sum_comb;

    always @(*) begin
        sum_comb = 23'sd0;
        for (c = 0; c < MAX_CH; c = c + 1) begin
            if (c < i_active_ch) begin
                sum_comb = sum_comb + $signed(i_partial[21*c +: 21]);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 1단 등록 + 16bit 정제
    //   정제 규칙: {sum[22](sign), sum[14:0]} — 기존 PE.v 출력 정제와 동일 의미.
    //   (설계 프로파일상 오버플로 미발생 확정 → 추가 saturation 불필요)
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_valid <= 1'b0;
            o_data  <= 16'sd0;
        end else begin
            o_valid <= i_valid;
            o_data  <= { sum_comb[22], sum_comb[14:0] };
        end
    end

endmodule
