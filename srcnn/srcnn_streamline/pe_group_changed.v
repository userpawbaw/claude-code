`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : pe_group.v
// PURPOSE        : 3x3 conv PE 묶음 1개. PE 9개 + 공간 adder tree 캡슐화.
//                  입력 채널 1개를 처리하여 공간 9-tap 합산 부분합(partial sum)을 출력.
// -----------------------------------------------------------------------------
// NOTE
//   - 기존 top.v 의 "PE generate + adder tree pipeline" 로직을 그대로 모듈화.
//     Layer 1 회귀가 깨지지 않도록 비트 인덱싱/파이프라인 타이밍을 보존한다.
//   - weight enable(i_wen)은 외부(weight_dispatch 또는 top의 weight_en)에서 공급.
//     PE 인터페이스(i_en_w 1펄스에 weight 1개 래치)는 변경하지 않는다.
//   - i_weight 는 PE 9개에 공통 연결(브로드캐스트). 어느 슬롯에 래치될지는
//     i_wen[i] one-hot 으로 결정 (기존 top.v 와 동일한 방식).
//
//   Reset Strategy : Asynchronous, active low (i_rstn)
//   Synthesizable  : Y
// -FHDR------------------------------------------------------------------------

module pe_group #(
    parameter IN_CN = 8  // L2 in_ch
    )(
    input wire                 i_clk,
    input wire                 i_rstn,

    // line buffer window
    input wire                 i_line_valid,     // line_buffer o_line_valid
    input wire [16*9-1:0]      i_line_data,      // 144bit 3x3 window (16bit x 9)

    // weight 공급 (기존 top.v weight_en/w_rd_dout 와 동일 역할)
    input wire signed [15:0]    i_weight,         // 공통 weight 버스 (브로드캐스트)
    // input wire                  i_w_group_en,           // 해당 PE_group의 weight en 
    input wire [8:0]            i_w_tap_en,             // PE 슬롯별 weight en 

    input  wire                 i_line_done,
    // partial sum 출력 (채널 누적 전, 공간 9-tap 합)
    output reg                  o_valid,          // 기존 adder_val_final 타이밍
    output reg  signed [20:0]   o_partial,         // 기존 r_add_total 과 동일 비트폭/의미
    output wire                 o_pe_done
    
);

    // -------------------------------------------------------------------------
    // PE array (9개) — 기존 gen_PE 와 동일
    // -------------------------------------------------------------------------
    wire                pe_valid;
    wire signed [31:0] pe_output [0:8];

    genvar i;
    generate
        for (i = 0; i < 9; i = i + 1) begin : gen_PE
            PE pe (
                .i_clk    (i_clk),
                .i_rstn   (i_rstn),
                .i_en_i   (i_line_valid),
                .i_en_w   (i_w_tap_en[i]),
                .i_input  (i_line_data[16*i +: 16]),
                .i_weight (i_weight),
                .o_valid  (pe_valid),
                .o_output (pe_output[i])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Adder Tree Pipeline — 기존 top.v section 7 그대로 이식  
    //   stage1 : 3개씩 3그룹 합 (pe_output[48*j +: ...])
    //   total  : stage1 3개 합
    //   valid  : pe_valid -> adder_val1 -> o_valid (2단 파이프)
    // no clipping applied.
    // -------------------------------------------------------------------------
    reg                 adder_val1;
    reg signed [31:0]   r_add_stage1 [2:0];

    integer j;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_add_stage1[0] <= 0;
            r_add_stage1[1] <= 0;
            r_add_stage1[2] <= 0;
            o_partial       <= 0;
            adder_val1      <= 0;
            o_valid         <= 0;
        end else begin
            { adder_val1, o_valid } <= { pe_valid, adder_val1 };

            for (j = 0; j < 3; j = j + 1) begin
                r_add_stage1[j] <= $signed(pe_output[3*j]) +
                                   $signed(pe_output[3*j + 1]) +
                                   $signed(pe_output[3*j + 2]);
            end

            o_partial <=  $signed(r_add_stage1[0]) +
                           $signed(r_add_stage1[1]) +
                           $signed(r_add_stage1[2]);
        end
    end

delay_shift #(
.DELAY(3)
)d3_pe_en_to_add_valid (
    .clk(i_clk),
    .rst(~i_rstn),
    .en (1'b1),
    .din(i_line_done),
    .dout(o_pe_done)
    );

endmodule
