`timescale 1ns / 1ps
// =============================================================================
// tb_L2_top.v
//  identity kernel + 8ch ramp 입력으로 L2_top 검증
//  pre-loaded intermid1_2 URAM stub 사용 (L1_top 없이)
//  out_ch 4번 반복(시분할). intermid2_3 ch 0~3 각각 동일한 결과 기대.
//  예상: URAM[i] = (8 * (i & 0x7FFF)) >> 8
// =============================================================================

module tb_L2_top;
    reg clk = 0;
    reg rstn = 0;
    reg start = 0;
    reg image_bit = 0;
    wire done;

    wire        l1_rd_en;
    wire [15:0] l1_rd_addr;
    wire [127:0] l1_rd_dout;
    wire        l1_rd_valid;

    wire [3:0]      l3_rd_en = 4'd0;
    wire [4*16-1:0] l3_rd_addr_packed = 64'd0;
    wire [4*16-1:0] l3_rd_dout_packed;
    wire [3:0]      l3_rd_valid;

    L2_top #(
        .MEM_ADDR(15),
        .WEIGHT_INIT("weight_l2.txt")
    ) dut (
        .i_clk(clk),
        .i_rstn(rstn),
        .i_start(start),
        .i_image_bit(image_bit),

        .o_l1_rd_en(l1_rd_en),
        .o_l1_rd_addr(l1_rd_addr),
        .i_l1_rd_dout(l1_rd_dout),
        .i_l1_rd_valid(l1_rd_valid),

        .i_l3_rd_en(l3_rd_en),
        .i_l3_rd_addr_packed(l3_rd_addr_packed),
        .o_l3_rd_dout_packed(l3_rd_dout_packed),
        .o_l3_rd_valid(l3_rd_valid),

        .o_done(done)
    );

    // Stub intermid1_2 URAM (L1 output stand-in)
    simple_dual_port_uram #(
        .WIDTH(128),
        .DEPTH(45000),
        .INIT_FILE("intermid1_2_init.txt")
    ) u_intermid1_2 (
        .clk(clk),
        .wr_en(1'b0),
        .wr_addr(16'd0),
        .wr_din(128'd0),
        .rd_en(l1_rd_en),
        .rd_addr(l1_rd_addr),
        .rd_valid(l1_rd_valid),
        .rd_dout(l1_rd_dout)
    );

    always #5 clk = ~clk;

    localparam NPIX = 150 * 150;
    integer ch, i, errors, checked;
    integer done_count;
    reg [15:0] expected, actual;

    always @(posedge clk) begin
        if (!rstn)     done_count <= 0;
        else if (done) done_count <= done_count + 1;
    end

    initial begin
        rstn = 0;
        start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        $display("[t=%0t] start asserted", $time);

        // progress logging every 10k cycles
        fork begin
            integer pp;
            for (pp = 0; pp < 100; pp = pp + 1) begin
                repeat(10000) @(posedge clk);
                $display("[t=%0t] done_count=%0d, r_ps=%0d, out_ch_cnt=%0d",
                         $time, done_count, dut.u_fsm.r_ps, dut.u_fsm.out_ch_cnt);
            end
        end join_none

        wait (done_count == 4);
        $display("[t=%0t] 4 out_ch iterations completed", $time);
        repeat(50) @(posedge clk);

        errors = 0; checked = 0;
        for (ch = 0; ch < 4; ch = ch + 1) begin
            for (i = 0; i < NPIX; i = i + 1) begin
                case (ch)
                    0: actual = dut.gen_intermid2_3[0].u_intermid2_3.mem[i];
                    1: actual = dut.gen_intermid2_3[1].u_intermid2_3.mem[i];
                    2: actual = dut.gen_intermid2_3[2].u_intermid2_3.mem[i];
                    3: actual = dut.gen_intermid2_3[3].u_intermid2_3.mem[i];
                endcase
                expected = (i & 16'h7FFF) >> 5;
                checked = checked + 1;
                if (actual !== expected) begin
                    if (errors < 20)
                        $display("MISMATCH ch=%0d pix=%0d: got=%04x exp=%04x", ch, i, actual, expected);
                    errors = errors + 1;
                end
            end
        end

        $display("=== L2 check: %0d checked, %0d errors ===", checked, errors);
        if (errors == 0) $display("L2 PASS");
        else             $display("L2 FAIL");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT (done_count=%0d)", done_count);
        $finish;
    end
endmodule
