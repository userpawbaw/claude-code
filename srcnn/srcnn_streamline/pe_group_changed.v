`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : pe_group_changed.v  (module name: pe_group)
// PURPOSE        : 3x3 conv PE 묶음 1개. PE 9개 + 공간 adder tree 캡슐화.
//                  ★ README spec : full Q16.16 누적 (PE 32-bit 그대로 합산).
//                  Q8.8 변환/saturation 은 상위 L*_PU 의 출력 stage 에서 수행.
// -----------------------------------------------------------------------------

module pe_group #(
    parameter IN_CN = 8
    )(
    input wire                 i_clk,
    input wire                 i_rstn,

    // line buffer window
    input wire                 i_line_valid,
    input wire [16*9-1:0]      i_line_data,

    // weight broadcast + per-tap one-hot enable
    input wire signed [15:0]   i_weight,
    input wire [8:0]           i_w_tap_en,

    input  wire                i_line_done,
    // partial sum 출력 (Q16.16, 공간 9-tap 합)
    output reg                 o_valid,
    output reg  signed [35:0]  o_partial,    // ★ 36-bit Q16.16
    output wire                o_pe_done
);

    // -------------------------------------------------------------------------
    // PE array (9개)
    // -------------------------------------------------------------------------
    wire                pe_valid;
    wire [32*9-1:0]     pe_output;            // ★ 9 × 32-bit Q16.16

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
                .o_output (pe_output[32*i +: 32])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Adder Tree Pipeline (Q16.16 그대로 누적)
    //   stage1 : 3개씩 3그룹 합 → 34-bit (32 + ceil(log2 3))
    //   total  : stage1 3개 합 → 36-bit
    //   valid  : pe_valid -> adder_val1 -> o_valid (2단 파이프)
    // -------------------------------------------------------------------------
    reg                 adder_val1;
    reg signed [33:0]   r_add_stage1 [2:0];

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

    delay_shift #(.DELAY(3)) d3_pe_en_to_add_valid (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(i_line_done),
        .dout(o_pe_done)
    );

endmodule
