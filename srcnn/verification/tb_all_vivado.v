`timescale 1ns / 1ps
// tb_all_vivado.v — Vivado XSim 호환 통합 testbench.
//
// 설계 결정 vs 기존 tb_L1.v / tb_L2.v:
//   - 기존 tb 는 stub URAM 의 내부 메모리 (`dut.gen_uram_L1[0].u_uram_L1.mem`)
//     를 직접 peek 한다. Xilinx URAM IP 는 그런 단일 `mem` 배열이 없어서
//     실 IP 환경에서 안 통한다.
//   - 본 tb 는 top 안의 packer 신호 (`pack_L1_we`/`pack_L1_dout`/`pack_main_we`/
//     `pack_main_dout`) 를 계층 참조로 모니터링해서 캡처한다. stub URAM 이든
//     실 Xilinx URAM IP 이든 동일하게 작동.
//   - i_start 1펄스로 L1→L2→L3 자동 진행 후 3 골든 모두 대조.
//
// 사용:
//   1) gen_golden.py 로 golden_L1.txt / golden_L2.txt / golden_out.txt / input.txt
//      / weight.txt 생성.
//   2) Vivado 시뮬레이션 워킹 디렉토리에 위 5개 파일 + 본 tb + RTL/stubs 추가.
//      자세한 setup 은 VIVADO_SIM.md 참조.
//   3) ReLU 모드 검증 시: gen_golden.py 를 `relu` 로 재생성 + URELU=1 오버라이드.

module tb_all_vivado;
    parameter URELU = 0;

    reg  clk  = 0;
    reg  rstn = 0;
    reg  start = 0;
    wire done, ovalid, lrd;
    wire [63:0] oout;

    top #(.USE_RELU(URELU)) dut (
        .i_clk          (clk),
        .i_rstn         (rstn),
        .i_start        (start),
        .o_done         (done),
        .o_output_valid (ovalid),
        .o_output       (oout),
        .o_line_rd_done (lrd)
    );

    always #5 clk = ~clk;

    localparam NPIX = 150 * 150;

    // ─── golden ─────────────────────────────────────────────────────────────
    reg [15:0] gold_L1  [0 : 4*NPIX - 1];
    reg [15:0] gold_L2  [0 : 2*NPIX - 1];
    reg [15:0] gold_out [0 : NPIX     - 1];

    // ─── 캡처 버퍼 ──────────────────────────────────────────────────────────
    reg [15:0] cap_L1  [0 : 4*NPIX - 1];   // [ch*NPIX + p]
    reg [15:0] cap_L2  [0 : 2*NPIX - 1];   // [oc*NPIX + p]
    reg [15:0] cap_out [0 : NPIX     - 1];

    integer cap_L1_idx;        // L1: 4 채널 동시 write 라 1 카운터로 충분
    integer cap_L2_oc0_idx;    // L2 oc0
    integer cap_L2_oc1_idx;    // L2 oc1
    integer cap_out_idx;

    // ─── 64bit word → 4 픽셀 (MSB-first) ───────────────────────────────────
    function [15:0] pix_of;
        input [63:0] w;
        input [1:0]  sub;
        begin
            case (sub)
                2'd0: pix_of = w[63:48];
                2'd1: pix_of = w[47:32];
                2'd2: pix_of = w[31:16];
                2'd3: pix_of = w[15:0];
            endcase
        end
    endfunction

    // ─── L1 캡처 (layer_cnt == 0 동안 pack_L1_we[*] 펄스마다 4픽셀 × 4채널) ──
    integer ich;
    always @(posedge clk) begin
        if (!rstn) begin
            cap_L1_idx <= 0;
        end else if (dut.layer_cnt == 2'd0 && dut.pack_L1_we[0]) begin
            // pack_L1_we[0..3] 가 모두 같은 clk 에 발사된다 (4 채널 공유 입력).
            for (ich = 0; ich < 4; ich = ich + 1) begin
                cap_L1[ich*NPIX + cap_L1_idx + 0] <= pix_of(dut.pack_L1_dout[ich], 2'd0);
                cap_L1[ich*NPIX + cap_L1_idx + 1] <= pix_of(dut.pack_L1_dout[ich], 2'd1);
                cap_L1[ich*NPIX + cap_L1_idx + 2] <= pix_of(dut.pack_L1_dout[ich], 2'd2);
                cap_L1[ich*NPIX + cap_L1_idx + 3] <= pix_of(dut.pack_L1_dout[ich], 2'd3);
            end
            cap_L1_idx <= cap_L1_idx + 4;
        end
    end

    // ─── L2 캡처 (layer_cnt == 1 동안 pack_main_we, out_ch_cnt 로 oc0/oc1 분기) ─
    //   case 로 명시 분기 — XSim 의 동적 hier index 안전 우선.
    always @(posedge clk) begin
        if (!rstn) begin
            cap_L2_oc0_idx <= 0;
            cap_L2_oc1_idx <= 0;
        end else if (dut.layer_cnt == 2'd1 && dut.pack_main_we) begin
            case (dut.out_ch_cnt)
                2'd0: begin
                    cap_L2[0*NPIX + cap_L2_oc0_idx + 0] <= pix_of(dut.pack_main_dout, 2'd0);
                    cap_L2[0*NPIX + cap_L2_oc0_idx + 1] <= pix_of(dut.pack_main_dout, 2'd1);
                    cap_L2[0*NPIX + cap_L2_oc0_idx + 2] <= pix_of(dut.pack_main_dout, 2'd2);
                    cap_L2[0*NPIX + cap_L2_oc0_idx + 3] <= pix_of(dut.pack_main_dout, 2'd3);
                    cap_L2_oc0_idx <= cap_L2_oc0_idx + 4;
                end
                2'd1: begin
                    cap_L2[1*NPIX + cap_L2_oc1_idx + 0] <= pix_of(dut.pack_main_dout, 2'd0);
                    cap_L2[1*NPIX + cap_L2_oc1_idx + 1] <= pix_of(dut.pack_main_dout, 2'd1);
                    cap_L2[1*NPIX + cap_L2_oc1_idx + 2] <= pix_of(dut.pack_main_dout, 2'd2);
                    cap_L2[1*NPIX + cap_L2_oc1_idx + 3] <= pix_of(dut.pack_main_dout, 2'd3);
                    cap_L2_oc1_idx <= cap_L2_oc1_idx + 4;
                end
            endcase
        end
    end

    // ─── L3 캡처 (포트 사용: o_output_valid = ub_final_we, layer_cnt==2 에서만 활성) ─
    always @(posedge clk) begin
        if (!rstn) begin
            cap_out_idx <= 0;
        end else if (ovalid && cap_out_idx + 4 <= NPIX) begin
            cap_out[cap_out_idx + 0] <= pix_of(oout, 2'd0);
            cap_out[cap_out_idx + 1] <= pix_of(oout, 2'd1);
            cap_out[cap_out_idx + 2] <= pix_of(oout, 2'd2);
            cap_out[cap_out_idx + 3] <= pix_of(oout, 2'd3);
            cap_out_idx <= cap_out_idx + 4;
        end
    end

    // ─── main ───────────────────────────────────────────────────────────────
    integer i, errL1, errL2, errOut;

    initial begin
        $readmemh("golden_L1.txt",  gold_L1);
        $readmemh("golden_L2.txt",  gold_L2);
        $readmemh("golden_out.txt", gold_out);

        rstn = 0; start = 0;
        repeat (4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // L3 까지 통과 대기 (layer_cnt 가 3 으로 진행)
        wait (dut.layer_cnt == 2'd3);
        repeat (200) @(posedge clk);   // 잔여 캡처 여유

        // 비교 ─────────────────────────────────────────────────────────────
        errL1 = 0;
        for (i = 0; i < 4*NPIX; i = i + 1) begin
            if (cap_L1[i] !== gold_L1[i]) begin
                if (errL1 < 10)
                    $display("L1 MISMATCH idx%0d ch%0d pix%0d: got=%04x exp=%04x",
                             i, i/NPIX, i%NPIX, cap_L1[i], gold_L1[i]);
                errL1 = errL1 + 1;
            end
        end

        errL2 = 0;
        for (i = 0; i < 2*NPIX; i = i + 1) begin
            if (cap_L2[i] !== gold_L2[i]) begin
                if (errL2 < 10)
                    $display("L2 MISMATCH idx%0d oc%0d pix%0d: got=%04x exp=%04x",
                             i, i/NPIX, i%NPIX, cap_L2[i], gold_L2[i]);
                errL2 = errL2 + 1;
            end
        end

        errOut = 0;
        for (i = 0; i < NPIX; i = i + 1) begin
            if (cap_out[i] !== gold_out[i]) begin
                if (errOut < 10)
                    $display("OUT MISMATCH pix%0d: got=%04x exp=%04x",
                             i, cap_out[i], gold_out[i]);
                errOut = errOut + 1;
            end
        end

        $display("");
        $display("=== L1  : %0d / %0d errors  (captured %0d/22500)",
                 errL1, 4*NPIX, cap_L1_idx);
        $display("=== L2  : %0d / %0d errors  (captured oc0=%0d oc1=%0d / 22500)",
                 errL2, 2*NPIX, cap_L2_oc0_idx, cap_L2_oc1_idx);
        $display("=== OUT : %0d / %0d errors  (captured %0d/22500)",
                 errOut, NPIX, cap_out_idx);

        if (errL1==0 && errL2==0 && errOut==0)
            $display("ALL PASS");
        else
            $display("ALL FAIL");

        $finish;
    end

    // 타임아웃 (L1+L2+L3 ≈ 925ms sim, 여유)
    initial begin
        #1500000000;
        $display("TIMEOUT layer=%0d capL1=%0d capL2 oc0=%0d oc1=%0d capOut=%0d",
                 dut.layer_cnt, cap_L1_idx, cap_L2_oc0_idx, cap_L2_oc1_idx, cap_out_idx);
        $finish;
    end
endmodule
