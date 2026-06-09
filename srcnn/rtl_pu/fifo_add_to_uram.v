`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/05/30 23:57:52
// Design Name: 
// Module Name: fifo_to_uram
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
module fifo_add_to_uram (
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_fifo_en,       // adder_tree_valid와 매칭 (여기서는 adder_val_final)
    input  wire [15:0] i_data,          // adder_tree의 최종 16비트 출력 데이터
    output reg  [63:0] o_output_uram,   // URAM 데이터 입력 포트로 연결
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
            o_uram_we <= 1'b0; // Pulse 형태로 유지하기 위해 디폴트 clear

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