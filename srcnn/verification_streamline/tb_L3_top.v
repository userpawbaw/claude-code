`timescale 1ns / 1ps
// =============================================================================
// tb_L3_top.v
//  identity kernel + 4ch ramp 입력으로 L3_top 검증
//  4개 intermid2_3 URAM stub (사전 로드)
//  L3 출력 stream(16bit + valid) capture, expected와 비교
//  예상: pixel i = (4 * (i & 0x7FFF)) >> 8 = (i & 0x7FFF) >> 6
// =============================================================================

module tb_L3_top;
    reg clk = 0;
    reg rstn = 0;
    reg start = 0;
    reg image_bit = 0;
    wire done;

    wire [3:0]      l2_rd_en;
    wire [4*16-1:0] l2_rd_addr_packed;
    wire [4*16-1:0] l2_rd_dout_packed;
    wire [3:0]      l2_rd_valid;

    wire        l3_pixel_valid;
    wire [15:0] l3_pixel_data;

    L3_top #(
        .MEM_ADDR(15),
        .WEIGHT_INIT("weight_l3.txt")
    ) dut (
        .i_clk(clk),
        .i_rstn(rstn),
        .i_start(start),
        .i_image_bit(image_bit),

        .o_l2_rd_en(l2_rd_en),
        .o_l2_rd_addr_packed(l2_rd_addr_packed),
        .i_l2_rd_dout_packed(l2_rd_dout_packed),
        .i_l2_rd_valid(l2_rd_valid),

        .o_pixel_valid(l3_pixel_valid),
        .o_pixel_data(l3_pixel_data),

        .o_done(done)
    );

    // Stub 4 intermid2_3 URAMs (one per ch) - explicit instances
    // (iverilog 이 generate 내 $sformatf param을 싫어해서 하드코딩)
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch0.txt")) u_uram0 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[0]),.rd_addr(l2_rd_addr_packed[16*0 +: 16]),
        .rd_valid(l2_rd_valid[0]),.rd_dout(l2_rd_dout_packed[16*0 +: 16]));
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch1.txt")) u_uram1 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[1]),.rd_addr(l2_rd_addr_packed[16*1 +: 16]),
        .rd_valid(l2_rd_valid[1]),.rd_dout(l2_rd_dout_packed[16*1 +: 16]));
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch2.txt")) u_uram2 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[2]),.rd_addr(l2_rd_addr_packed[16*2 +: 16]),
        .rd_valid(l2_rd_valid[2]),.rd_dout(l2_rd_dout_packed[16*2 +: 16]));
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch3.txt")) u_uram3 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[3]),.rd_addr(l2_rd_addr_packed[16*3 +: 16]),
        .rd_valid(l2_rd_valid[3]),.rd_dout(l2_rd_dout_packed[16*3 +: 16]));

    always #5 clk = ~clk;

    localparam NPIX = 150 * 150;
    reg [15:0] captured [0:NPIX-1];
    integer cap_idx;

    always @(posedge clk) begin
        if (!rstn) cap_idx <= 0;
        else if (l3_pixel_valid && cap_idx < NPIX) begin
            captured[cap_idx] <= l3_pixel_data;
            cap_idx <= cap_idx + 1;
        end
    end

    integer i, errors;
    reg [15:0] expected;

    initial begin
        rstn = 0;
        start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        wait (done);
        repeat(20) @(posedge clk);

        errors = 0;
        for (i = 0; i < NPIX; i = i + 1) begin
            expected = (i & 16'h7FFF) >> 6;
            if (captured[i] !== expected) begin
                if (errors < 20)
                    $display("MISMATCH pix=%0d: got=%04x exp=%04x", i, captured[i], expected);
                errors = errors + 1;
            end
        end

        $display("=== L3 check: captured %0d pixels, %0d errors ===", cap_idx, errors);
        if (errors == 0 && cap_idx == NPIX) $display("L3 PASS");
        else                                $display("L3 FAIL");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT (cap_idx=%0d, done=%b)", cap_idx, done);
        $finish;
    end
endmodule
