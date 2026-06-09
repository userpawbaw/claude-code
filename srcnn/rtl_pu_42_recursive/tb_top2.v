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
    wire [63:0]  pix_data;
    wire [3:0]   lane_valid;

    top dut (
        .i_clk           (clk),
        .i_rstn          (rstn),
        .i_start         (start),
        .o_img_done      (img_done),
        .o_all_done      (all_done),
        .o_pixel_valid   (pix_valid),
        .o_pixel_data    (pix_data),
        .o_lane_valid    (lane_valid)
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

    // ---------- L3 output pixel-level comparison (4-way) ----------
    //   o_pixel_data = 4 lanes × 16 bit per valid pulse.
    //   pix_data[63:48]=lane0, [47:32]=lane1, [31:16]=lane2, [15:0]=lane3.
    //   lane_valid[k]: bit k = lane k valid.
    //   line_buffer_wide_l3 : lane k → out_col = 4*emit_k - 2 + k.
    //   emit_k = 0..37 per padded row (152/4 = 38).
    //   Compare valid region: row 1..150 (padded), col 1..149.
    //   Golden: gold_out[img*WPCH + row*WPR + col/8][(7-col%8)*16 +: 16].
    integer err_L3;
    integer cnt_L3;      // total pix_valid pulses
    integer emit_k_L3;   // 0..37 per row
    integer row_L3;
    integer cur_img_L3;
    integer lk, out_col;
    reg [15:0] got_px, exp_px;
    reg [127:0] g_word_L3;

    initial begin
        err_L3=0; cnt_L3=0; emit_k_L3=0; row_L3=1; cur_img_L3=0;
    end

    always @(posedge clk) begin
        if (pix_valid) begin
            for (lk = 0; lk < 4; lk = lk + 1) begin
                if (lane_valid[lk]) begin
                    out_col = 4*emit_k_L3 - 2 + lk;
                    if (out_col >= 1 && out_col <= 149 && cur_img_L3 < NIMG) begin
                        got_px = pix_data[(3-lk)*16 +: 16];
                        g_word_L3 = gold_out[cur_img_L3*WPCH + row_L3*WPR + out_col/8];
                        exp_px = g_word_L3[(7 - out_col%8)*16 +: 16];
                        if (got_px !== exp_px) begin
                            if (err_L3 < 8)
                                $display("L3 ERR img=%0d row=%0d col=%0d got=%04x exp=%04x",
                                    cur_img_L3, row_L3, out_col, got_px, exp_px);
                            err_L3 = err_L3 + 1;
                        end
                    end
                end
            end
            cnt_L3 = cnt_L3 + 1;
            emit_k_L3 = emit_k_L3 + 1;
            if (emit_k_L3 == 38) begin
                emit_k_L3 = 0;
                row_L3    = row_L3 + 1;
            end
        end
        if (img_done) begin
            cur_img_L3 = cur_img_L3 + 1;
            emit_k_L3  = 0;
            row_L3     = 1;
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

        repeat(120000) @(posedge clk);

        $display("");
        $display("=== RESULT ===");
        $display("all_done=%b", all_done);
        $display("L1 : %0d writes, %0d errors", cnt_L1, err_L1);
        $display("L2 : %0d writes, %0d errors", cnt_L2, err_L2);
        $display("L3 : %0d valid pulses, %0d errors", cnt_L3, err_L3);
        if (err_L1 == 0 && err_L2 == 0 && err_L3 == 0 && all_done)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
