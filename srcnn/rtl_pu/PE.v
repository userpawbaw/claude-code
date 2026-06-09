`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/25 11:00:48
// Design Name: 
// Module Name: PE
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


module PE(
    input i_clk,  
    input i_rstn,
    input i_en_i,
    input i_en_w,    
    input signed [15:0]    i_input,
    input signed [15:0]    i_weight,
    
    output reg o_valid,
    output signed [15:0]   o_output
);
    reg  signed [15:0]  r_weight;   // weight stationary weight  
    wire signed [31:0]  w_output;   // valid filtered output  
    
    
    reg clr;
    
    assign o_output = o_valid ? {w_output[31], w_output[22:8]} : 16'sd0;  // q8.8 (sign + Q7.8, clean 16bit)
    
    always@(posedge i_clk or negedge i_rstn) begin
        if(~i_rstn)begin
            o_valid     <= 0;
            r_weight    <= 0;
            clr         <= 0;
        end else begin
            if(i_en_w) begin
                r_weight    <= i_weight;
            end
            o_valid     <= i_en_i;
            clr         <= {i_en_i,o_valid} == 2'b01;
        end    
    end
    
    dsp_macro_0 dsp(
  .CLK(i_clk),  // input wire CLK
  .CE(i_en_i),    // input wire CE
  .SCLR(clr),
  .A(i_input),      // input wire [15 : 0] A
  .B(r_weight),      // input wire [15 : 0] B
  .P(w_output)      // output wire [31 : 0] P
);
endmodule
