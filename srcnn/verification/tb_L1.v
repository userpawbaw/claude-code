`timescale 1ns / 1ps
// tb_L1.v — Layer1 검증: uram_L1[0..3] 출력 vs golden_L1
module tb_L1;
    parameter URELU = 0;   // -PtbL1.URELU=1 로 ReLU 모드 검증
    reg clk=0, rstn=0, start=0;
    wire done, ovalid, lrd;
    wire [63:0] oout;

    top #(.USE_RELU(URELU)) dut (
        .i_clk(clk), .i_rstn(rstn), .i_start(start),
        .o_done(done), .o_output_valid(ovalid),
        .o_output(oout), .o_line_rd_done(lrd)
    );

    always #5 clk = ~clk;

    // golden_L1 로드 (4ch * 150*150)
    localparam NPIX = 150*150;
    reg [15:0] gold [0:4*NPIX-1];
    integer i;

    // uram_L1 word 디코드 헬퍼 (64bit = 4 pixel, MSB first)
    function [15:0] pix_of;
        input [63:0] w; input [1:0] sub;
        begin
            case (sub)
                2'd0: pix_of = w[63:48];
                2'd1: pix_of = w[47:32];
                2'd2: pix_of = w[31:16];
                2'd3: pix_of = w[15:0];
            endcase
        end
    endfunction

    integer ch, p, errors, checked;
    reg [63:0] uword;
    reg [15:0] got, exp;

    initial begin
        $readmemh("golden_L1.txt", gold);
        rstn = 0; start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // L1 완료까지 대기: layer_cnt가 1이 되면 L1 끝
        wait (dut.layer_cnt == 2'd1);
        repeat(100) @(posedge clk);  // 잔여 write 충분히 대기

        // uram_L1[0..3] 덤프 비교
        errors = 0; checked = 0;
        for (ch = 0; ch < 4; ch = ch + 1) begin
            for (p = 0; p < NPIX; p = p + 1) begin
                case (ch)
                    0: uword = dut.gen_uram_L1[0].u_uram_L1.mem[p>>2];
                    1: uword = dut.gen_uram_L1[1].u_uram_L1.mem[p>>2];
                    2: uword = dut.gen_uram_L1[2].u_uram_L1.mem[p>>2];
                    3: uword = dut.gen_uram_L1[3].u_uram_L1.mem[p>>2];
                endcase
                got = pix_of(uword, p[1:0]);
                exp = gold[ch*NPIX + p];
                checked = checked + 1;
                if (got !== exp) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("MISMATCH ch%0d pix%0d: got=%04x exp=%04x", ch, p, got, exp);
                end
            end
        end
        $display("=== L1 check: %0d checked, %0d errors ===", checked, errors);
        if (errors==0) $display("L1 PASS");
        else           $display("L1 FAIL");
        $finish;
    end

    // 타임아웃
    initial begin
        #50000000;  // 5ms
        $display("TIMEOUT");
        $display("layer_cnt=%0d", dut.layer_cnt);
        $finish;
    end
endmodule
