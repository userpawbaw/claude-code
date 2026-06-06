`timescale 1ns / 1ps
// pe_group : 3x3 conv, 9 PE + spatial adder tree (1 in_ch).
//   weight interface : i_weight (16-bit) shared + i_w_tap_en[8:0] one-hot tap.
//   output           : o_partial (32-bit signed Q16.16) = 9-tap spatial sum.
//   PE produces full Q16.16 (32-bit) product without truncation;
//   adder tree keeps Q16.16. Q8.8 truncation / saturation happens in PU.

module pe_group (
    input  wire                 i_clk,
    input  wire                 i_rstn,

    input  wire                 i_line_valid,
    input  wire [16*9-1:0]      i_line_data,

    input  wire signed [15:0]   i_weight,
    input  wire [8:0]           i_w_tap_en,

    input  wire                 i_line_img_done,
    output reg                  o_valid,
    output reg  signed [31:0]   o_partial,
    output wire                 o_pe_done
);
    wire            pe_valid;
    wire [32*9-1:0] pe_output;

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

    // adder tree : 9 -> 3 -> 1 (Q16.16, 32-bit unified)
    reg               adder_val1;
    reg signed [31:0] r_add_stage1 [2:0];

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
