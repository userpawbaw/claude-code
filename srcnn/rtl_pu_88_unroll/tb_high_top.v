`timescale 1ns/1ps
// tb_high_top.v (rtl_pu_88_unroll) — high_top 통합 TB.
//   16-bit/clk 직렬 스트림을 golden_out.txt 와 비교.
//   golden_out : 1 ch × 3 img × 2888 words (128-bit/word, 8 px MSB-first).
//   유효 px : 각 이미지의 padded row 1..150, padded col 1..150 (= 22500 px).
//   out col 0 (padding zero) 포함 22500 pulses/image; pcol==0 비교 skip.

module tb_high_top;
    reg  clk  = 0;
    reg  rstn = 0;
    reg  start = 0;
    always #5 clk = ~clk;

    wire       all_done;
    wire       pix_valid;
    wire [15:0] pix_data;
    wire        img_done_out;

    high_top dut (
        .i_clk        (clk),
        .i_rstn       (rstn),
        .i_start      (start),
        .o_all_done   (all_done),
        .o_pix_valid  (pix_valid),
        .o_pix_data   (pix_data),
        .o_img_done   (img_done_out)
    );

    // ─── golden ────────────────────────────────────────────────────────────
    localparam NIMG  = 3;
    localparam WPCH  = 2888;   // 19 words/row × 152 rows
    localparam WPR   = 19;     // 128-bit words per padded row
    localparam G_SZ  = NIMG * WPCH;   // 8664

    reg [127:0] gold_out [0 : G_SZ - 1];

    initial begin
        $readmemh("golden_out.txt", gold_out);
        $display("golden loaded OK");
    end

    // ─── 16-bit 직렬 스트림 비교 ──────────────────────────────────────────
    integer cnt_pix;
    integer cur_img;
    integer p;
    integer prow, pcol;
    integer err_val;
    reg [15:0] got_px, exp_px;
    reg [127:0] g_word;

    initial begin
        cnt_pix = 0; cur_img = 0; p = 0; err_val = 0;
    end

    always @(posedge clk) begin
        if (pix_valid) begin
            cnt_pix = cnt_pix + 1;
            if (cur_img < NIMG) begin
                prow = 1 + p / 150;
                pcol = p % 150;

                if (pcol != 0) begin
                    g_word  = gold_out[cur_img * WPCH + prow * WPR + pcol / 8];
                    exp_px  = g_word[(7 - pcol % 8) * 16 +: 16];
                    got_px  = pix_data;
                    if (got_px !== exp_px) begin
                        if (err_val < 8)
                            $display("PIXEL ERR img=%0d row=%0d col=%0d got=%04x exp=%04x",
                                cur_img, prow, pcol, got_px, exp_px);
                        err_val = err_val + 1;
                    end
                end

                if (p == 22499) begin
                    p       = 0;
                    cur_img = cur_img + 1;
                end else begin
                    p = p + 1;
                end
            end
        end
    end

    // ─── DEBUG ─────────────────────────────────────────────────────────────
    integer cyc;
    initial cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    always @(posedge clk) begin
        if (img_done_out)
            $display("[%0t cy=%0d] IMG_DONE cur_img=%0d cnt_pix=%0d",
                $time, cyc, cur_img, cnt_pix);
        if (cyc % 20000 == 0)
            $display("t=%0t cy=%0d all_done=%b pix_valid=%b cur_img=%0d p=%0d cnt_pix=%0d err=%0d",
                $time, cyc, all_done, pix_valid, cur_img, p, cnt_pix, err_val);
    end

    // ─── main ──────────────────────────────────────────────────────────────
    initial begin
        $display("SIM START");
        rstn = 0; start = 0;
        repeat(4)  @(posedge clk);
        rstn = 1;  @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        repeat(120000) @(posedge clk);

        $display("");
        $display("=== RESULT ===");
        $display("all_done=%b  pix_pulses=%0d  img_done_cnt=%0d  val_err=%0d",
                 all_done, cnt_pix, cur_img, err_val);
        if (all_done && cur_img == NIMG && err_val == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end
endmodule
