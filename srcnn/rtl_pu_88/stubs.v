`timescale 1ns / 1ps
// stubs.v (rtl_pu_88) — iverilog 검증 보조 IP.
//   - PE: PE.v 의 dsp_macro_0 대체 stub. Q7.8 추출 = {w_output[31], w_output[22:8]}.
//   - simple_dual_port_bram: 1-clk read latency. weight BRAM 은 WIDTH=128 인스턴스화됨.
//   - simple_dual_port_uram: 1-clk read latency, 64-bit.
//   - fifo_generator_0: 64→16 standard mode, 4-pixel packed write.

module PE (
    input  wire               i_clk,
    input  wire               i_rstn,
    input  wire               i_en_i,
    input  wire               i_en_w,
    input  wire signed [15:0] i_input,
    input  wire signed [15:0] i_weight,
    output reg                o_valid,
    output wire signed [15:0] o_output
);
    reg signed [15:0] r_weight;
    reg signed [31:0] w_output;
    reg               clr;
    assign o_output = o_valid ? {w_output[31], w_output[22:8]} : 16'sd0;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_valid  <= 0;
            r_weight <= 0;
            clr      <= 0;
            w_output <= 0;
        end else begin
            if (i_en_w) r_weight <= i_weight;
            o_valid <= i_en_i;
            clr     <= ({i_en_i, o_valid} == 2'b01);
            if (i_en_i) w_output <= i_input * r_weight;
        end
    end
endmodule

module simple_dual_port_bram #(
    parameter WIDTH     = 16,
    parameter DEPTH     = 1024,
    parameter INIT_FILE = ""
)(
    input  wire                     clk,
    input  wire                     wr_en,
    input  wire                     rd_en,
    input  wire [16:0]              wr_addr,
    input  wire [16:0]              rd_addr,
    input  wire [WIDTH-1:0]         wr_din,
    output reg                      rd_valid,
    output reg  [WIDTH-1:0]         rd_dout
);
    localparam AW = $clog2(DEPTH);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    integer ii;
    initial begin
        for (ii=0; ii<DEPTH; ii=ii+1) mem[ii] = 0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) begin
        if (wr_en) mem[wr_addr[AW-1:0]] <= wr_din;
        rd_dout  <= mem[rd_addr[AW-1:0]];
        rd_valid <= rd_en;
    end
endmodule

module simple_dual_port_uram #(
    parameter WIDTH     = 64,
    parameter DEPTH     = 8192,
    parameter INIT_FILE = ""
)(
    input  wire                     clk,
    input  wire                     wr_en,
    input  wire [12:0]              wr_addr,
    input  wire [WIDTH-1:0]         wr_din,
    input  wire                     rd_en,
    input  wire [12:0]              rd_addr,
    output reg                      rd_valid,
    output reg  [WIDTH-1:0]         rd_dout
);
    localparam AW = $clog2(DEPTH);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    integer ii;
    initial begin
        for (ii=0; ii<DEPTH; ii=ii+1) mem[ii] = 0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) begin
        if (wr_en) mem[wr_addr[AW-1:0]] <= wr_din;
        rd_dout  <= mem[rd_addr[AW-1:0]];
        rd_valid <= rd_en;
    end
endmodule

module fifo_generator_0 #(
    parameter DEPTH = 4096
)(
    input  wire        clk,
    input  wire        srst,
    input  wire [63:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output reg  [15:0] dout,
    output wire        full,
    output wire        empty,
    output wire        wr_rst_busy,
    output wire        rd_rst_busy
);
    reg [15:0] mem [0:DEPTH-1];
    integer wptr, rptr, cnt;
    assign full  = (cnt >= DEPTH-4);
    assign empty = (cnt == 0);
    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;
    initial begin wptr=0; rptr=0; cnt=0; dout=0; end
    always @(posedge clk) begin
        if (srst) begin
            wptr<=0; rptr<=0; cnt<=0; dout<=0;
        end else begin
            if (wr_en) begin
                mem[wptr]            <= din[63:48];
                mem[(wptr+1)%DEPTH]  <= din[47:32];
                mem[(wptr+2)%DEPTH]  <= din[31:16];
                mem[(wptr+3)%DEPTH]  <= din[15:0];
                wptr <= (wptr+4)%DEPTH;
            end
            if (rd_en && cnt>0) begin
                dout <= mem[rptr];
                rptr <= (rptr+1)%DEPTH;
            end
            if (wr_en && !(rd_en && cnt>0))      cnt <= cnt + 4;
            else if (wr_en && (rd_en && cnt>0))  cnt <= cnt + 3;
            else if (rd_en && cnt>0)             cnt <= cnt - 1;
        end
    end
endmodule
