`timescale 1ns / 1ps
// tb_L2.v — Layer2 검증: uram_L2[0..1] vs golden_L2
module tb_L2;
    reg clk=0, rstn=0, start=0;
    wire done, ovalid, lrd; wire [63:0] oout;
    top #(.USE_RELU(0)) dut (.i_clk(clk),.i_rstn(rstn),.i_start(start),
        .o_done(done),.o_output_valid(ovalid),.o_output(oout),.o_line_rd_done(lrd));
    always #5 clk=~clk;

    localparam NPIX = 150*150;
    reg [15:0] gold [0:2*NPIX-1];

    function [15:0] pix_of;
        input [63:0] w; input [1:0] sub;
        case (sub)
            2'd0: pix_of = w[63:48]; 2'd1: pix_of = w[47:32];
            2'd2: pix_of = w[31:16]; 2'd3: pix_of = w[15:0];
        endcase
    endfunction

    integer ch, p, errors, checked;
    reg [63:0] uword; reg [15:0] got, exp;

    initial begin
        $readmemh("golden_L2.txt", gold);
        rstn=0; start=0; repeat(4) @(posedge clk); rstn=1;
        @(posedge clk); start=1; @(posedge clk); start=0;

        // L2 완료까지: layer_cnt가 2가 되면 L2 끝
        wait (dut.layer_cnt == 2'd2);
        repeat(100) @(posedge clk);

        errors=0; checked=0;
        for (ch=0; ch<2; ch=ch+1) begin
            for (p=0; p<NPIX; p=p+1) begin
                uword = (ch==0) ? dut.gen_uram_L2[0].u_uram_L2.mem[p>>2]
                                : dut.gen_uram_L2[1].u_uram_L2.mem[p>>2];
                got = pix_of(uword, p[1:0]);
                exp = gold[ch*NPIX + p];
                checked = checked+1;
                if (got !== exp) begin
                    errors=errors+1;
                    if (errors<=20) $display("MISMATCH ch%0d pix%0d: got=%04x exp=%04x",ch,p,got,exp);
                end
            end
        end
        $display("=== L2 check: %0d checked, %0d errors ===", checked, errors);
        $display(errors==0 ? "L2 PASS" : "L2 FAIL");
        $finish;
    end
    initial begin #500000000; $display("TIMEOUT layer=%0d",dut.layer_cnt); $finish; end
endmodule
