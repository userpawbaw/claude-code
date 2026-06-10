`timescale 1ns / 1ps
// packer_8x.v — 8-px parallel pack to 128-bit URAM word.
//
// 8-way unroll PE emits 8 px (= 128 bit) per cycle, which matches the URAM
// word size, so no accumulation buffer is needed: register the data on i_en
// and assert the URAM write enable on the same pulse.
//
// Pipeline : i_en → 1-clk delay → o_uram_we.
module packer_8x (
    input  wire         i_clk,
    input  wire         i_rstn,
    input  wire         i_en,            // 1 clk emit pulse (PE valid)
    input  wire [127:0] i_data,          // 8 px × 16 bit
    output reg  [127:0] o_output_uram,
    output reg          o_uram_we
);
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_output_uram <= 128'h0;
            o_uram_we     <= 1'b0;
        end else begin
            o_uram_we <= i_en;
            if (i_en) o_output_uram <= i_data;
        end
    end
endmodule
