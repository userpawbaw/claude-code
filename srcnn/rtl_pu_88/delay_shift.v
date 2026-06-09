`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/31 17:54:07
// Design Name: 
// Module Name: delay_shift
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module delay_shift #(
    parameter WIDTH = 1,   // 
    parameter DELAY = 4    // 
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              en,
    input  wire [WIDTH-1:0]  din,
    output wire [WIDTH-1:0]  dout
);

    reg [WIDTH-1:0] shift_reg [0:DELAY-1];
    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < DELAY; i = i + 1)
                shift_reg[i] <= {WIDTH{1'b0}};
        end else if (en) begin
            shift_reg[0] <= din;
            for (i = 1; i < DELAY; i = i + 1)
                shift_reg[i] <= shift_reg[i-1];
        end
    end

    assign dout = shift_reg[DELAY-1];

endmodule
