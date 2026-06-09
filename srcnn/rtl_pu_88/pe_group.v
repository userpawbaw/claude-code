`timescale 1ns / 1ps
// pe_group : 3x3 conv PE 9개 + 공간 adder tree (1 in_ch).
//   weight 인터페이스: i_weight (16bit) 공통 + i_w_tap_en[8:0] (one-hot tap 선택)
//   output: o_partial (36-bit signed Q16.16) = 9-tap 공간합 + valid + pe_done
//   PE 가 full Q16.16 (32-bit) 곱셈을 그대로 흘려보내므로 본 adder tree 도
//   Q16.16 누적. Q8.8 변환/saturation 은 상위 PU 의 출력 stage 에서 수행.
module pe_group (
    input  wire                 i_clk,
    input  wire                 i_rstn,

    input  wire                 i_line_valid,
    input  wire [16*9-1:0]      i_line_data,

    input  wire signed [15:0]   i_weight,
    input  wire [8:0]           i_w_tap_en,    // one-hot per tap

    input  wire                 i_line_img_done,
    output reg                  o_valid,
    output reg  signed [35:0]   o_partial,     // ★ Q16.16 (9 × 32-bit 합, 36-bit safe)
    output wire                 o_pe_done
);
    wire            pe_valid;
    wire [32*9-1:0] pe_output;                 // ★ 9 × 32-bit Q16.16

    genvar i;
    generate
        for (i = 0; i < 9; i = i + 1) begin : gen_PE
            PE pe (
                .i_clk    (i_clk),
                .i_rstn   (i_rstn),
                .i_en_i   (i_line_valid),
                .i_en_w   (i_w_tap_en[i]),
                .i_input  (i_line_data[16*9 - 1 - 16*i -: 16]),
                .i_weight (i_weight),
                .o_valid  (pe_valid),
                .o_output (pe_output[32*i +: 32])
            );
        end
    endgenerate

    // adder tree: 9 → 3 → 1  (Q16.16 그대로 누적)
    //   stage1: 3-input 합 × 3 → 34-bit (32 + ceil(log2 3) = 34)
    //   stage2: 3-input 합     → 36-bit
    reg               adder_val1;
    reg signed [33:0] r_add_stage1 [2:0];

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
                r_add_stage1[j] <= $signed(pe_output[96*j      +: 32]) +
                                   $signed(pe_output[96*j + 32 +: 32]) +
                                   $signed(pe_output[96*j + 64 +: 32]);
            end
            o_partial <= r_add_stage1[0] + r_add_stage1[1] + r_add_stage1[2];
        end
    end

    delay_shift #(.DELAY(3)) u_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (i_line_img_done),
        .dout (o_pe_done)
    );
endmodule
