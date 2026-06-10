`timescale 1ns / 1ps
// fifo_add_to_uram : pack 4 consecutive 16-bit results into a 64-bit URAM word.
// Used by L3 (4-way) output path. Asserts o_uram_we for 1 clk when the 4th
// sample arrives.
module fifo_add_to_uram (
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_fifo_en,       // matches adder_tree_valid (here, adder_val_final)
    input  wire [15:0] i_data,          // 16-bit output from adder_tree
    output reg  [63:0] o_output_uram,   // wires to URAM data-in port
    output reg         o_uram_we        // URAM Write Enable
);

    reg [63:0] fifo_64;
    reg [1:0]  fifo_cnt;
    
    wire [15:0] out_visual [3:0];

assign out_visual[0] = o_output_uram[63:48];
assign out_visual[1] = o_output_uram[63:48];
assign out_visual[2] = o_output_uram[63:48];
assign out_visual[3] = o_output_uram[63:48];

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            fifo_cnt      <= 2'b0;
            fifo_64       <= 64'h0;
            o_output_uram <= 64'h0;
            o_uram_we     <= 1'b0;
        end else begin
            o_uram_we <= 1'b0; // default-clear so the signal remains a 1-clk pulse

            if (i_fifo_en) begin
                fifo_64  <= {fifo_64[47:0], i_data};
                fifo_cnt <= fifo_cnt + 1'b1;

                if (fifo_cnt == 2'b11) begin
                    o_output_uram <= {fifo_64[47:0], i_data};
                    o_uram_we     <= 1'b1;
                end
            end
        end
    end
endmodule