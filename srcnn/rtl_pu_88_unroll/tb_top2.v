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
    wire [63:0] pix_data;
    wire [3:0]  lane_valid;

    top dut (
        .i_clk         (clk),
        .i_rstn        (rstn),
        .i_start       (start),
        .o_img_done    (img_done),
        .o_all_done    (all_done),
        .o_pixel_valid (pix_valid),
        .o_pixel_data  (pix_data),
        .o_lane_valid  (lane_valid)
    );

    // golden : 128-bit word arrays.
    //   golden_L1 / golden_L2 : 8 ch × 3 img × 2888 words = 69312 entries.
    //   golden_out             : 3 img × 2888 words         = 8664 entries.
    //   index order : img → ch → word_in_image (= row*19 + cw, addr 0..2887).
    localparam NIMG        = 3;
    localparam OC          = 8;
    localparam WPCH        = 2888;   // words per ch per img
    localparam WPR         = 19;     // words per row
    localparam WPO         = 19;     // words per row out
    localparam G_L1_SZ     = NIMG*OC*WPCH;   // 69312
    localparam G_OUT_SZ    = NIMG*WPCH;       // 8664
    localparam WPR_SKIP    = WPR;             // skip first row (addr 0..18)

    reg [127:0] gold_L1  [0 : G_L1_SZ-1];
    reg [127:0] gold_L2  [0 : G_L1_SZ-1];
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
            for (bi = 0; bi < OC; bi = bi + 1) begin
                c_L1_w = dut.w_pack_dout_flat[bi*128 +: 128];
                g_L1_w = gold_L1[dut.w_img_cnt*OC*WPCH + bi*WPCH + dut.r_wr_addr];
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

    always @(posedge clk) begin
        if (dut.w_layer_cnt == 2'd1 && dut.w_pack_we[0]) begin
            c_L2_w = dut.w_pack_dout_flat[0 +: 128];
            g_L2_w = gold_L2[dut.w_img_cnt*OC*WPCH + dut.w_out_ch_cnt*WPCH + dut.r_wr_addr];
            if (c_L2_w !== g_L2_w) begin
                if (err_L2 < 8)
                    $display("L2 ERR img=%0d oc=%0d addr=%0d got=%032x exp=%032x",
                        dut.w_img_cnt, dut.w_out_ch_cnt, dut.r_wr_addr, c_L2_w, g_L2_w);
                err_L2 = err_L2 + 1;
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

    integer err_L3;
    integer cnt_L3;      // total pix_valid pulses
    integer emit_k_L3;   // 0..37 per row (input word_cnt)
    integer row_L3;      // output row (1..150)
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
                    // only compare valid region: row 1..150, col 1..149
                    if (out_col >= 1 && out_col <= 149) begin
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
            // advance emit_k and row counters
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

        repeat(110000) @(posedge clk);

        $display("");
        $display("=== RESULT ===");
        $display("all_done=%b", all_done);
        $display("L1 : %0d writes, %0d errors", cnt_L1, err_L1);
        $display("L2 : %0d writes, %0d errors", cnt_L2, err_L2);
        $display("L3 : %0d valid pulses (%0d words), %0d errors", cnt_L3, cnt_L3/2, err_L3);
        if (err_L1 == 0 && err_L2 == 0 && err_L3 == 0 && all_done)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
