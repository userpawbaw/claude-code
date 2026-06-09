`timescale 1ns / 1ps
// =============================================================================
// stubs.v — 검증용 보조 모듈 (사용자 환경의 실제 IP/모듈 대체)
//   - PE                  : 곱셈 PE (1clk 곱, weight 래치)
//   - simple_dual_port_bram : 단순 동기 read BRAM (1clk rd_valid)
//   - simple_dual_port_uram : 단순 동기 read URAM (1clk rd 지연, addr [15:0])
//   - fifo_generator_0    : 64bit din -> 16bit dout (4분할) FIFO 표내
// 주: 기능 검증용. 실제 합성은 사용자 환경 IP 사용.
// =============================================================================

// -----------------------------------------------------------------------------
// PE : 실제 PE.v 동작 모사.
//   weight stationary (i_en_w 래치). DSP = 1clk latency 곱셈기 (mreg only).
//   o_output = o_valid ? {w_output[31], w_output[14:0]} : 0
//   o_valid <= i_en_i (1clk). w_output <= i_input * r_weight (1clk, CE=i_en_i).
// -----------------------------------------------------------------------------
module PE (
    input  wire               i_clk,
    input  wire               i_rstn,
    input  wire               i_en_i,
    input  wire               i_en_w,
    input  wire signed [15:0] i_input,
    input  wire signed [15:0] i_weight,
    output reg                o_valid,
    output wire signed [31:0] o_output
);
    reg  signed [15:0] r_weight;
    reg  signed [31:0] w_output;   // DSP P (mreg, 1clk)
    reg                clr;

    assign o_output = o_valid ? w_output : 32'sd0;

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
            // DSP: mreg (1clk). CE=i_en_i, SCLR=clr (단순 곱이라 곱값에 영향 없음)
            if (i_en_i) w_output <= i_input * r_weight;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// simple_dual_port_bram : 동기 read, 1clk 후 rd_valid + rd_dout
//   addr [14:0] (15-bit) - existing convention
// -----------------------------------------------------------------------------
module simple_dual_port_bram #(
    parameter WIDTH     = 16,
    parameter DEPTH     = 1024,
    parameter INIT_FILE = ""
)(
    input  wire                     clk,
    input  wire                     wr_en,
    input  wire                     rd_en,
    input  wire [14:0]              wr_addr,
    input  wire [14:0]              rd_addr,
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

// -----------------------------------------------------------------------------
// simple_dual_port_uram : 동기 read, 1clk 후 rd_dout (+rd_valid)
//   addr [15:0] (16-bit) - widened for streamline intermid URAMs (depth ~45000)
// -----------------------------------------------------------------------------
module simple_dual_port_uram #(
    parameter WIDTH     = 64,
    parameter DEPTH     = 8192,
    parameter INIT_FILE = ""
)(
    input  wire                     clk,
    input  wire                     wr_en,
    input  wire [15:0]              wr_addr,
    input  wire [WIDTH-1:0]         wr_din,
    input  wire                     rd_en,
    input  wire [15:0]              rd_addr,
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

// -----------------------------------------------------------------------------
// fifo_generator_0 : 실제 IP 모사.
//   Input_Data_Width=64, Output_Data_Width=16 (MSB-first 4분할).
//   Standard FIFO: rd_en -> 다음 clk dout 유효. Valid_Flag=false (valid 미사용).
// -----------------------------------------------------------------------------
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
