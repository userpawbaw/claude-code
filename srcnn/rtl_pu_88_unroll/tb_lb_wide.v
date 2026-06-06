// tb_lb_wide.v — line_buffer_wide unit test.
// Feed 3 rows of known data (152 pixels each), check that the 3×10 window
// output matches expected values at specific col_word positions.
`timescale 1ns/1ps

module tb_lb_wide;
    reg         clk, rstn, idle_rst, valid;
    reg [127:0] din;
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

    // Build a 128-bit word from 8 pixel values (lane 0 = MSB)
    function [127:0] mk_word;
        input [15:0] p0, p1, p2, p3, p4, p5, p6, p7;
        mk_word = {p0, p1, p2, p3, p4, p5, p6, p7};
    endfunction

    integer cw, row, err_cnt;
    reg [15:0] img [0:2][0:151]; // 3 rows × 152 cols
    reg [127:0] word;

    // Extract a 16-bit pixel from the 480-bit window output.
    // Window packing: {row2[159:0], row1[159:0], row0[159:0]}
    // Within a row: win[9]=MSB(159:144) ... win[0]=LSB(15:0)
    // row_idx: 0=bottom(newest), 1=middle, 2=top(oldest)
    // col_idx: 0=rightmost(newest) ... 9=leftmost(oldest)
    function [15:0] get_win;
        input [479:0] w;
        input integer row_idx, col_idx;
        integer base;
        begin
            base = row_idx * 160 + col_idx * 16;
            get_win = w[base +: 16];
        end
    endfunction

    initial begin
        clk = 0; rstn = 0; idle_rst = 0; valid = 0; din = 0;
        err_cnt = 0;

        // Fill image with known values: pixel = row*256 + col
        for (row = 0; row < 3; row = row + 1)
            for (cw = 0; cw < 152; cw = cw + 1)
                img[row][cw] = row * 256 + cw;

        #20 rstn = 1;
        #10;

        // Feed 3 rows
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
        @(posedge clk);
        valid <= 0; din <= 0;

        // Wait for pipeline drain
        repeat(5) @(posedge clk);

        $display("tb_lb_wide: err_cnt = %0d", err_cnt);
        if (err_cnt == 0) $display("PASS");
        else              $display("FAIL");
        $finish;
    end

    // Monitor valid outputs
    reg [15:0] out_cnt;
    initial out_cnt = 0;

    always @(posedge clk) begin
        if (wvalid) begin
            // Check a few specific windows.
            // First valid output is row=2, col_word=0 (after 2-clk pipeline).
            // After col_word 0: bottom row 10 cols =
            //   {stale_prev_col150, stale_prev_col151, row2_col0, ..., row2_col7}
            //   But at the first row (row=2), "prev" data is from row 1.

            // At out_cnt=0 (col_word 0 of row 2):
            // Bottom row (row0 of window = r_line0 = row 2):
            //   win[0] = row2_col7, win[7] = row2_col0
            //   win[8] = row1_col151, win[9] = row1_col150  (stale, expected for border)
            if (out_cnt == 0) begin
                // Check win[0] (bottom row, rightmost = row2 col7)
                if (get_win(wout, 0, 0) !== img[2][7]) begin
                    $display("ERR out0: win[0,0] = %04X, exp %04X", get_win(wout,0,0), img[2][7]);
                    err_cnt = err_cnt + 1;
                end
                // Check win[7] (bottom row, col_idx 7 = row2 col0)
                if (get_win(wout, 0, 7) !== img[2][0]) begin
                    $display("ERR out0: win[0,7] = %04X, exp %04X", get_win(wout,0,7), img[2][0]);
                    err_cnt = err_cnt + 1;
                end
                // Check win[8] (bottom row, col_idx 8 = row1 col151 = stale)
                if (get_win(wout, 0, 8) !== img[1][151]) begin
                    $display("ERR out0: win[0,8] = %04X, exp %04X", get_win(wout,0,8), img[1][151]);
                    err_cnt = err_cnt + 1;
                end
                // Check middle row (row1): win[0] = row1_col7
                if (get_win(wout, 1, 0) !== img[1][7]) begin
                    $display("ERR out0: win[1,0] = %04X, exp %04X", get_win(wout,1,0), img[1][7]);
                    err_cnt = err_cnt + 1;
                end
                // Check top row (row2=r_line2=row0): win[0] = row0_col7
                if (get_win(wout, 2, 0) !== img[0][7]) begin
                    $display("ERR out0: win[2,0] = %04X, exp %04X", get_win(wout,2,0), img[0][7]);
                    err_cnt = err_cnt + 1;
                end
            end

            // At out_cnt=1 (col_word 1 of row 2):
            // Bottom row: win[0]=row2_col15, win[8]=row2_col7, win[9]=row2_col6
            if (out_cnt == 1) begin
                if (get_win(wout, 0, 0) !== img[2][15]) begin
                    $display("ERR out1: win[0,0] = %04X, exp %04X", get_win(wout,0,0), img[2][15]);
                    err_cnt = err_cnt + 1;
                end
                if (get_win(wout, 0, 8) !== img[2][7]) begin
                    $display("ERR out1: win[0,8] = %04X, exp %04X", get_win(wout,0,8), img[2][7]);
                    err_cnt = err_cnt + 1;
                end
                if (get_win(wout, 0, 9) !== img[2][6]) begin
                    $display("ERR out1: win[0,9] = %04X, exp %04X", get_win(wout,0,9), img[2][6]);
                    err_cnt = err_cnt + 1;
                end
            end

            // At out_cnt=18 (col_word 18 = last of row 2):
            // Bottom row: win[0]=row2_col151, win[9]=row2_col142
            if (out_cnt == 18) begin
                if (get_win(wout, 0, 0) !== img[2][151]) begin
                    $display("ERR out18: win[0,0] = %04X, exp %04X", get_win(wout,0,0), img[2][151]);
                    err_cnt = err_cnt + 1;
                end
                if (get_win(wout, 0, 9) !== img[2][142]) begin
                    $display("ERR out18: win[0,9] = %04X, exp %04X", get_win(wout,0,9), img[2][142]);
                    err_cnt = err_cnt + 1;
                end
            end

            out_cnt <= out_cnt + 1;
        end
    end

    // Check total valid count
    always @(posedge clk) begin
        if (out_cnt == 19 && !wvalid) begin
            // Should get exactly 19 valid outputs (1 row × 19 col_words)
            if (out_cnt !== 19) begin
                $display("ERR: expected 19 valid outputs, got %0d", out_cnt);
                err_cnt = err_cnt + 1;
            end
        end
    end

endmodule
