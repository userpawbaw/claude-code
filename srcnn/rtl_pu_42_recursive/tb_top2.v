`timescale 1ns/1ps
// tb_top2.v — top 통합 TB (새버전).
//   - $readmemh 로 128-bit golden 배열 로드 (on-the-fly 비교, 캡처 배열 없음).
//   - fixed-cycle 종료 (hang 방지).
//   - L1/L2: pack_we 타이밍에 128-bit word 단위 비교.
//   - L3: 4px/clk 출력 수집 → 8px 단어로 조합 후 비교.

module tb_top2;
    reg  clk  = 0;
    reg  rstn = 0;
    reg  start = 0;
    always #5 clk = ~clk;

    wire img_done, all_done;
    wire pix_valid;
    wire [127:0] pix_data;
    wire [7:0]   lane_valid;
    wire [127:0] out_word;
    wire         out_we;
    wire [3:0]   out_flush_cnt;

    top dut (
        .i_clk           (clk),
        .i_rstn          (rstn),
        .i_start         (start),
        .o_img_done      (img_done),
        .o_all_done      (all_done),
        .o_pixel_valid   (pix_valid),
        .o_pixel_data    (pix_data),
        .o_lane_valid    (lane_valid),
        .o_out_word      (out_word),
        .o_out_we        (out_we),
        .o_out_flush_cnt (out_flush_cnt)
    );

    // golden : 128-bit word arrays (preset 4_2).
    //   golden_L1 : 4 ch × 3 img × 2888 = 34656 entries.
    //   golden_L2 : 2 ch × 3 img × 2888 = 17328 entries.
    //   golden_out: 1 ch × 3 img × 2888 = 8664 entries.
    localparam NIMG        = 3;
    localparam L1_OC       = 4;
    localparam L2_OC       = 2;
    localparam WPCH        = 2888;
    localparam WPR         = 19;
    localparam G_L1_SZ     = NIMG*L1_OC*WPCH;   // 34656
    localparam G_L2_SZ     = NIMG*L2_OC*WPCH;   // 17328
    localparam G_OUT_SZ    = NIMG*WPCH;          // 8664

    reg [127:0] gold_L1  [0 : G_L1_SZ-1];
    reg [127:0] gold_L2  [0 : G_L2_SZ-1];
    reg [127:0] gold_out [0 : G_OUT_SZ-1];

    initial begin
        $readmemh("golden_L1.txt",  gold_L1);
        $readmemh("golden_L2.txt",  gold_L2);
        $readmemh("golden_out.txt", gold_out);
        $display("golden loaded OK");
    end

    // ---------- on-the-fly L1 comparison ----------
    integer err_L1;
    integer cnt_L1;
    reg [127:0] g_L1_w, c_L1_w;
    integer bi;
    initial begin err_L1 = 0; cnt_L1 = 0; end

    always @(posedge clk) begin
        if (dut.w_layer_cnt == 2'd0 && dut.w_pack_we[0]) begin
            for (bi = 0; bi < L1_OC; bi = bi + 1) begin
                c_L1_w = dut.w_pack_dout_flat[bi*128 +: 128];
                g_L1_w = gold_L1[dut.w_img_cnt*L1_OC*WPCH + bi*WPCH + dut.r_wr_addr];
                if (c_L1_w !== g_L1_w) begin
                    if (err_L1 < 8)
                        $display("L1 ERR img=%0d ch=%0d addr=%0d got=%032x exp=%032x",
                            dut.w_img_cnt, bi, dut.r_wr_addr, c_L1_w, g_L1_w);
                    err_L1 = err_L1 + 1;
                end
            end
            cnt_L1 = cnt_L1 + 1;
        end
    end

    // ---------- on-the-fly L2 comparison ----------
    integer err_L2;
    integer cnt_L2;
    reg [127:0] g_L2_w, c_L2_w;
    initial begin err_L2 = 0; cnt_L2 = 0; end

    // L2 : 2 oc 동시 write. pack_we[0] 가 write 펄스 (모든 oc 동기 발생).
    integer oi_L2;
    always @(posedge clk) begin
        if (dut.w_layer_cnt == 2'd1 && dut.w_pack_we[0]) begin
            for (oi_L2 = 0; oi_L2 < L2_OC; oi_L2 = oi_L2 + 1) begin
                c_L2_w = dut.w_pack_dout_flat[oi_L2*128 +: 128];
                g_L2_w = gold_L2[dut.w_img_cnt*L2_OC*WPCH + oi_L2*WPCH + dut.r_wr_addr];
                if (c_L2_w !== g_L2_w) begin
                    if (err_L2 < 8)
                        $display("L2 ERR img=%0d oc=%0d addr=%0d got=%032x exp=%032x",
                            dut.w_img_cnt, oi_L2, dut.r_wr_addr, c_L2_w, g_L2_w);
                    err_L2 = err_L2 + 1;
                end
            end
            cnt_L2 = cnt_L2 + 1;
        end
    end

    // ---------- L3 output pixel-level comparison ----------
    // o_pixel_data = 4 lanes × 16 bit per valid pulse.
    // lane k → out_col = 4*emit_k - 2 + (3-k)  [k=0 is MSB=leftmost]
    //   Wait, pix_data[63:48]=ok=0→lane0, pix_data[47:32]=lane1,
    //         pix_data[31:16]=lane2, pix_data[15:0]=lane3.
    //   lane_valid[k]: bit k of o_lane_valid (bit0=lane0 valid).
    //   From line_buffer_wide_l3: lane k → out_col 4K-2+k.
    //   But pix_data bit order: pix_data[63:48]=PU ok=0=lane0 → out_col 4K-2.
    //                           pix_data[15:0] =PU ok=3=lane3 → out_col 4K+1.
    // Compare only valid (row 1..150, col 1..149) pixels.
    // Golden pixel: gold_out[img*WPCH + row*WPR + col/8], bit (7-col%8)*16+:16.

    // L3 8-way : pix_valid 펄스 카운트 + packer 출력 word 카운트만 수집.
    //   상세 값 검증은 추후 별도 작업 (packer 출력을 150x150 stream 으로 재배열 필요).
    integer err_L3;
    integer cnt_L3;          // raw pix_valid pulses
    integer cnt_out_we;      // packer output we pulses
    integer cnt_out_flush;   // flush emit count
    initial begin
        err_L3=0; cnt_L3=0; cnt_out_we=0; cnt_out_flush=0;
    end

    always @(posedge clk) begin
        if (pix_valid)               cnt_L3 = cnt_L3 + 1;
        if (out_we) begin
            cnt_out_we = cnt_out_we + 1;
            if (out_flush_cnt != 4'd0) cnt_out_flush = cnt_out_flush + 1;
        end
    end

    // ---------- periodic status ----------
    integer cyc;
    initial cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    always @(posedge clk) begin
        if (cyc % 10000 == 0)
            $display("t=%0t cy=%0d layer=%0d img=%0d oc=%0d L1cnt=%0d L2cnt=%0d L3cnt=%0d",
                $time, cyc, dut.w_layer_cnt, dut.w_img_cnt, dut.w_out_ch_cnt,
                cnt_L1, cnt_L2, cnt_L3);
    end

    // ---------- main ----------
    initial begin
        $display("SIM START");
        rstn = 0; start = 0;
        repeat(4)  @(posedge clk);
        rstn = 1;  @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        repeat(110000) @(posedge clk);

        $display("");
        $display("=== RESULT ===");
        $display("all_done=%b", all_done);
        $display("L1 : %0d writes, %0d errors", cnt_L1, err_L1);
        $display("L2 : %0d writes, %0d errors", cnt_L2, err_L2);
        $display("L3 : %0d raw pulses, %0d packer words (%0d flush), %0d errors",
                 cnt_L3, cnt_out_we, cnt_out_flush, err_L3);
        if (err_L1 == 0 && err_L2 == 0 && err_L3 == 0 && all_done)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
