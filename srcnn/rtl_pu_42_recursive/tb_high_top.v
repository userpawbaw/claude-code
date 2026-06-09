`timescale 1ns/1ps
// tb_high_top.v — high_top 통합 TB.
//   16-bit/clk 직렬 스트림을 golden_out.txt 와 비교.
//   golden_out : 1 ch × 3 img × 2888 words (128-bit/word, 8 px MSB-first).
//   유효 px : 각 이미지의 padded row 1..150, padded col 1..150 (= 150×150=22500 px).
//   out_buf 가 out col 0 (padding zero) 도 직렬 출력하므로 실제 o_pix_valid pulses 는
//   22500 px/img (2 valid lanes at row-start, 150 rows, but col 0 is padding zero).
//
//   ★ pix_data[15:0] 를 row-major 22500 px 시퀀스로 비교:
//     pulse p (0-based within image) →
//       if (p % 150 == 0):  col 0 = padding zero (skip comparison)
//       else:               padded_col = p % 150, padded_row = 1 + p / 150
//     golden_out[img*WPCH + row*WPR + col/8][(7-col%8)*16 +: 16]

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
    localparam WPCH  = 2888;
    localparam WPR   = 19;
    localparam G_SZ  = NIMG * WPCH;   // 8664

    reg [127:0] gold_out [0 : G_SZ - 1];

    initial begin
        $readmemh("golden_out.txt", gold_out);
        $display("golden loaded OK");
    end

    // ─── 16-bit 직렬 스트림 비교 ──────────────────────────────────────────
    // out_buf 가 내보내는 순서:
    //   row-major, row 1..150, 각 row 마다 150 px:
    //     px 0 : col 0 (= padding zero, lane valid 이나 golden 은 0)
    //     px 1 : col 1 (padded col 1 = 최초 유효 px)
    //     ...
    //     px 149 : col 149
    //   총 150 px/row × 150 row = 22500 px/image.
    //
    //   → pulse_in_image p:
    //       padded_col = p % 150 (0-based within row's 150 outputs)
    //       padded_row = 1 + p / 150
    //       If padded_col == 0: expect 0 (padding zero; skip comparison)

    integer cnt_pix;      // total pix_valid pulses
    integer cur_img;      // image counter
    integer p;            // pulse within image (0..22499)
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
                // derive row/col in padded space
                prow = 1 + p / 150;
                pcol = p % 150;          // 0 = padding col

                if (pcol != 0) begin
                    // compare against golden
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

                // advance pulse counter
                if (p == 22499) begin
                    p       = 0;
                    cur_img = cur_img + 1;
                end else begin
                    p = p + 1;
                end
            end
        end
    end

    // ─── DEBUG: img_done ───────────────────────────────────────────────────
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

        // 처리 (~35k) + 직렬화 (~3×22500 = 67500) + 여유 = 120000
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
