`timescale 1ns / 1ps
// =============================================================================
// tb_L1_top.v
//   - identity kernel + ramp input 으로 L1_top 동작 검증
//   - 예상: intermid1_2 URAM[i] = {8 copies of (i & 0x7FFF)} in 128-bit packed
//   - input_l1.txt, weight_l1.txt 는 시뮬 실행 dir에 있어야 함 (gen_inputs_simple.py 생성)
// =============================================================================

module tb_L1_top;
    reg clk  = 0;
    reg rstn = 0;
    reg start = 0;
    wire done;

    // L2-side read port (이 tb에서는 미사용, idle)
    wire [127:0] dummy_dout;
    wire         dummy_rvalid;

    L1_top #(
        .MEM_ADDR   (15),
        .IMG_INIT   ("input_l1.txt"),
        .WEIGHT_INIT("weight_l1.txt")
    ) dut (
        .i_clk         (clk),
        .i_rstn        (rstn),
        .i_start       (start),
        .i_image_bit   (1'b0),

        .i_l2_rd_en    (1'b0),
        .i_l2_rd_addr  (16'd0),
        .o_l2_rd_dout  (dummy_dout),
        .o_l2_rd_valid (dummy_rvalid),

        .o_done        (done)
    );

    always #5 clk = ~clk;

    // ----------------------------------------------------
    // Stimulus + Check
    // ----------------------------------------------------
    localparam NPIX = 150 * 150;  // 22500
    integer i, k, errors, checked;
    reg [127:0] uword;
    reg [15:0]  expected, actual;

    initial begin
        rstn  = 0;
        start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // wait done + pipeline drain
        wait (done);
        repeat(20) @(posedge clk);

        // ----- Verify intermid1_2 URAM contents -----
        // 예상: URAM[i] = {8 copies of (i & 0x7FFF)} (8 ch packed, LSB=ch0)
        errors  = 0;
        checked = 0;
        for (i = 0; i < NPIX; i = i + 1) begin
            uword = dut.u_intermid1_2.mem[i];
            for (k = 0; k < 8; k = k + 1) begin
                actual   = uword[16*k +: 16];
                expected = i[14:0];
                checked  = checked + 1;
                if (actual !== expected) begin
                    if (errors < 20)
                        $display("MISMATCH pix=%0d ch=%0d: got=%04x exp=%04x",
                                 i, k, actual, expected);
                    errors = errors + 1;
                end
            end
        end

        $display("=== L1 check: %0d checked, %0d errors ===", checked, errors);
        if (errors == 0) $display("L1 PASS");
        else             $display("L1 FAIL");
        $finish;
    end

    // ----------------------------------------------------
    // Timeout
    // ----------------------------------------------------
    initial begin
        #5_000_000;   // 5 ms
        $display("TIMEOUT (done=%b)", done);
        $finish;
    end
endmodule
