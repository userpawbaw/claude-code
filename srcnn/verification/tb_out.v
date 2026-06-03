`timescale 1ns / 1ps
// tb_out.v — Layer3 검증: 최종 출력 스트림(o_output/o_output_valid) vs golden_out
//   L3 결과는 URAM 에 저장되지 않고 64b 4픽셀 패킹으로 포트로 흘러나간다.
//   o_output_valid (= ub_final_we) 펄스마다 4픽셀씩 캡처해서 golden_out.txt 와 대조.
module tb_out;
    parameter URELU = 0;   // -Ptb_out.URELU=1 로 ReLU 모드 검증
    reg clk=0, rstn=0, start=0;
    wire done, ovalid, lrd; wire [63:0] oout;
    top #(.USE_RELU(URELU)) dut (
        .i_clk(clk), .i_rstn(rstn), .i_start(start),
        .o_done(done), .o_output_valid(ovalid),
        .o_output(oout), .o_line_rd_done(lrd)
    );
    always #5 clk = ~clk;

    localparam NPIX = 150*150;
    reg [15:0] gold     [0:NPIX-1];
    reg [15:0] captured [0:NPIX-1];
    integer cap_idx;

    function [15:0] pix_of;
        input [63:0] w; input [1:0] sub;
        case (sub)
            2'd0: pix_of = w[63:48];
            2'd1: pix_of = w[47:32];
            2'd2: pix_of = w[31:16];
            2'd3: pix_of = w[15:0];
        endcase
    endfunction

    // o_output_valid 펄스마다 4픽셀 캡처 (MSB-first 4 슬롯).
    //   L1/L2 동안 ovalid 는 항상 0 (ub_final_we 는 layer_cnt==2 에서만 활성).
    always @(posedge clk) begin
        if (!rstn) begin
            cap_idx <= 0;
        end else if (ovalid && cap_idx + 4 <= NPIX) begin
            captured[cap_idx + 0] <= pix_of(oout, 2'd0);
            captured[cap_idx + 1] <= pix_of(oout, 2'd1);
            captured[cap_idx + 2] <= pix_of(oout, 2'd2);
            captured[cap_idx + 3] <= pix_of(oout, 2'd3);
            cap_idx <= cap_idx + 4;
        end
    end

    integer i, errors, checked;

    initial begin
        $readmemh("golden_out.txt", gold);
        rstn = 0; start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // L3 종료까지 대기: out_ch 루프 후 layer_cnt 가 3 으로 진행.
        wait (dut.layer_cnt == 2'd3);
        repeat(100) @(posedge clk);

        errors = 0; checked = 0;
        for (i = 0; i < NPIX; i = i + 1) begin
            checked = checked + 1;
            if (captured[i] !== gold[i]) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("MISMATCH pix%0d: got=%04x exp=%04x", i, captured[i], gold[i]);
            end
        end
        $display("=== OUT check: %0d checked, %0d errors, captured=%0d ===",
                 checked, errors, cap_idx);
        if (errors == 0) $display("OUT PASS");
        else             $display("OUT FAIL");
        $finish;
    end

    // 타임아웃 (L1+L2 ≈ 695ms sim, L3 추가 여유)
    initial begin
        #1500000000;
        $display("TIMEOUT layer=%0d cap=%0d", dut.layer_cnt, cap_idx);
        $finish;
    end
endmodule
