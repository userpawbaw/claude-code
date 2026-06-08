// tb_lb_wide.v — line_buffer_wide unit test (post-revision slice scheme).
//
// New design:
//   slice = r_lineX[271:112]  (10 pixels covering input cols (K-1)*8-1 .. K*8
//                              of current row R, after word K of row R is in).
//   slice[9] (leftmost) is "col -1" at row-start emit (word_cnt=1) — masked to 0.
//   slice[0] (rightmost) is the freshest pixel of the latest word.
//
// Feed 3 rows of img[row][col] = row*256 + col and verify slice contents at
// the first few emits (which correspond to word_cnt = 1..18 of input row 2,
// producing output cols 0..143 of out_row 1 in the conv view).

`timescale 1ns/1ps

module tb_lb_wide;
    reg          clk, rstn, idle_rst, valid;
    reg  [127:0] din;
    wire [479:0] wout;
    wire         wvalid, wdone, wimgdone;

    line_buffer_wide #(
        .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(10),
        .SHIFT_STEP(8), .DATA_BIT(16)
    ) uut (
        .i_clk(clk), .i_rstn(rstn), .i_IDLE_rst(idle_rst),
        .i_input_valid(valid), .i_input_data(din),
        .o_line_data(wout), .o_line_valid(wvalid),
        .o_line_rd_done(wdone), .o_img_done(wimgdone)
    );

    always #5 clk = ~clk;

    // Build a 128-bit word from 8 pixel values (lane 0 = MSB = leftmost col).
    function [127:0] mk_word;
        input [15:0] p0, p1, p2, p3, p4, p5, p6, p7;
        mk_word = {p0, p1, p2, p3, p4, p5, p6, p7};
    endfunction

    // Window packing : {row2[159:0], row1[159:0], row0[159:0]}
    //   row_idx 0 = bottom (r_line0, newest row in pipeline)
    //   row_idx 1 = middle (r_line1)
    //   row_idx 2 = top    (r_line2, oldest row)
    //   Within a row : col_idx 0 = LSB = rightmost col (newest)
    //                  col_idx 9 = MSB = leftmost  col (oldest, "col -1" at row-start emit)
    function [15:0] get_win;
        input [479:0] w;
        input integer row_idx, col_idx;
        begin
            get_win = w[row_idx*160 + col_idx*16 +: 16];
        end
    endfunction

    integer cw, row, err_cnt;
    reg [15:0] img [0:2][0:151];
    reg [127:0] word;

    initial begin
        clk = 0; rstn = 0; idle_rst = 0; valid = 0; din = 0;
        err_cnt = 0;

        // Fill image with distinguishable values: pixel = row*256 + col.
        // (No left/right padding in tb — that's the point of the mask test.)
        for (row = 0; row < 3; row = row + 1)
            for (cw = 0; cw < 152; cw = cw + 1)
                img[row][cw] = row * 256 + cw;

        #20 rstn = 1;
        #10;

        // Feed 3 rows back-to-back.
        for (row = 0; row < 3; row = row + 1) begin
            for (cw = 0; cw < 19; cw = cw + 1) begin
                word = mk_word(
                    img[row][cw*8+0], img[row][cw*8+1],
                    img[row][cw*8+2], img[row][cw*8+3],
                    img[row][cw*8+4], img[row][cw*8+5],
                    img[row][cw*8+6], img[row][cw*8+7]
                );
                @(posedge clk);
                valid <= 1; din <= word;
            end
        end
        // Trailing dummy word to flush out-row1 cols 144..151
        // (word_cnt=0 of "row 3" emit).
        @(posedge clk);
        valid <= 1; din <= 128'd0;

        // Drop input, then assert IDLE_rst (FSM does this at S_DONE) so the
        // counters stop generating spurious emits.
        @(posedge clk);
        valid <= 0; din <= 0;
        @(posedge clk);
        idle_rst <= 1;
        @(posedge clk);
        idle_rst <= 0;

        repeat(10) @(posedge clk);

        $display("tb_lb_wide: out_cnt=%0d err_cnt=%0d", out_cnt, err_cnt);
        if (err_cnt == 0 && out_cnt == 19) $display("PASS");
        else                                 $display("FAIL");
        $finish;
    end

    // -----------------------------------------------------------------
    // Output checker
    // -----------------------------------------------------------------
    reg [15:0] out_cnt;
    initial out_cnt = 0;

    task check_eq;
        input integer idx_row, idx_col;
        input [15:0]  expected;
        input [31:0]  tag;
        begin
            if (get_win(wout, idx_row, idx_col) !== expected) begin
                $display("ERR out=%0d tag=%0d win[%0d,%0d]=%04X exp=%04X",
                         out_cnt, tag, idx_row, idx_col,
                         get_win(wout, idx_row, idx_col), expected);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (wvalid) begin
            // First emit (out_cnt=0) corresponds to word_cnt=1 of input row 2.
            //   Bottom row slice should be {0(masked), row2 col0..col7, row2 col8}.
            //   Middle row slice should be {0(masked), row1 col0..col7, row1 col8}.
            //   Top    row slice should be {0,          row0 col0..col7, row0 col8}.
            if (out_cnt == 0) begin
                // bottom (row_idx=0)
                check_eq(0, 0, img[2][8], 0);   // win[0] newest = col 8
                check_eq(0, 1, img[2][7], 1);
                check_eq(0, 7, img[2][1], 2);
                check_eq(0, 8, img[2][0], 3);
                check_eq(0, 9, 16'd0,     4);   // MSB (col -1) MASKED
                // middle (row_idx=1)
                check_eq(1, 0, img[1][8], 5);
                check_eq(1, 8, img[1][0], 6);
                check_eq(1, 9, 16'd0,     7);   // MASKED
                // top (row_idx=2)
                check_eq(2, 0, img[0][8], 8);
                check_eq(2, 8, img[0][0], 9);
                check_eq(2, 9, 16'd0,    10);   // top row's col -1 also 0 (reset + mask)
            end

            // Second emit (out_cnt=1) : word_cnt=2 of row 2.
            //   Bottom slice = {row2 col7, row2 col8..col15, row2 col16}.
            //   No mask (col_word at emit was 2).
            if (out_cnt == 1) begin
                check_eq(0, 0, img[2][16], 20);
                check_eq(0, 1, img[2][15], 21);
                check_eq(0, 8, img[2][8],  22);
                check_eq(0, 9, img[2][7],  23);
                check_eq(1, 0, img[1][16], 24);
                check_eq(1, 9, img[1][7],  25);
                check_eq(2, 0, img[0][16], 26);
                check_eq(2, 9, img[0][7],  27);
            end

            // Last in-row emit : word_cnt=18 of row 2 -> out_cnt=17.
            //   Bottom slice = {row2 col135, row2 col136..143, row2 col144}.
            //   No mask (col_word at emit was 18).
            if (out_cnt == 17) begin
                check_eq(0, 0, img[2][144], 40);
                check_eq(0, 1, img[2][143], 41);
                check_eq(0, 8, img[2][136], 42);
                check_eq(0, 9, img[2][135], 43);
            end

            // Boundary emit : word_cnt=0 of "row 3" (= dummy zero word) -> out_cnt=18.
            //   Bottom slice  = {row2 col143, row2 col144..151, 0 (dummy)}.
            //   Middle slice  = {row1 col143, row1 col144..151, row2 col0}.
            //   Top    slice  = {row0 col143, row0 col144..151, row1 col0}.
            //   No mask (col_word at emit was 0).
            if (out_cnt == 18) begin
                check_eq(0, 0, 16'd0,         60);   // dummy word lane 0
                check_eq(0, 1, img[2][151],   61);
                check_eq(0, 8, img[2][144],   62);
                check_eq(0, 9, img[2][143],   63);
                check_eq(1, 0, img[2][0],     64);   // row2 col0 = "col 152" placeholder
                check_eq(1, 1, img[1][151],   65);
                check_eq(1, 8, img[1][144],   66);
                check_eq(1, 9, img[1][143],   67);
                check_eq(2, 0, img[1][0],     68);
                check_eq(2, 1, img[0][151],   69);
                check_eq(2, 8, img[0][144],   70);
                check_eq(2, 9, img[0][143],   71);
            end

            out_cnt <= out_cnt + 1;
        end
    end

endmodule
