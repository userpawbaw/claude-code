// tb_lb_wide_l3.v — line_buffer_wide_l3 unit test (4-way L3 line buffer).
//
// Verifies :
//   * 38 emits per valid input row.
//   * First emit of each row (word_cnt=0) carries lane_valid = 4'b1100 and the
//     bottom-row window slice = {row(r-1) col 150, col 151, row r col 0..3}.
//   * Subsequent emits (word_cnt 1..37) carry lane_valid = 4'b1111 and slice
//     content advances by 4 cols per cycle.

`timescale 1ns/1ps

module tb_lb_wide_l3;
    reg          clk, rstn, idle_rst, valid;
    reg  [63:0]  din;
    wire [287:0] wout;
    wire [3:0]   wlane_valid;
    wire         wvalid, wdone, wimgdone;

    line_buffer_wide_l3 #(
        .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(6),
        .SHIFT_STEP(4), .DATA_BIT(16), .LANE_NUM(4)
    ) uut (
        .i_clk(clk), .i_rstn(rstn), .i_IDLE_rst(idle_rst),
        .i_input_valid(valid), .i_input_data(din),
        .o_line_data(wout), .o_lane_valid(wlane_valid),
        .o_line_valid(wvalid),
        .o_line_rd_done(wdone), .o_img_done(wimgdone)
    );

    always #5 clk = ~clk;

    // Build a 64-bit word from 4 pixel values (lane 0 = MSB = leftmost col).
    function [63:0] mk_word;
        input [15:0] p0, p1, p2, p3;
        mk_word = {p0, p1, p2, p3};
    endfunction

    // Per-row slice layout (96 bit) :
    //   slice[16*i +: 16] = pixel i  (i = 0..5, LSB → MSB)
    function [15:0] get_px;
        input [287:0] w;
        input integer row_idx, px_idx;
        begin
            get_px = w[row_idx*96 + px_idx*16 +: 16];
        end
    endfunction

    integer cw, row, err_cnt;
    reg [15:0] img [0:2][0:151];
    reg [63:0] word;

    initial begin
        clk = 0; rstn = 0; idle_rst = 0; valid = 0; din = 0;
        err_cnt = 0;

        // Distinguishable values; left/right cols zero-padded (mimics L2 out).
        for (row = 0; row < 3; row = row + 1)
            for (cw = 0; cw < 152; cw = cw + 1)
                img[row][cw] = (cw == 0 || cw == 151) ? 16'd0
                                                      : (row * 16'd1000 + cw);

        #20 rstn = 1;
        #10;

        // Feed 3 rows × 38 words each.
        for (row = 0; row < 3; row = row + 1) begin
            for (cw = 0; cw < 38; cw = cw + 1) begin
                word = mk_word(
                    img[row][cw*4+0], img[row][cw*4+1],
                    img[row][cw*4+2], img[row][cw*4+3]
                );
                @(posedge clk);
                valid <= 1; din <= word;
            end
        end

        @(posedge clk);
        valid <= 0; din <= 0;
        @(posedge clk);
        idle_rst <= 1;
        @(posedge clk);
        idle_rst <= 0;

        repeat(10) @(posedge clk);

        $display("tb_lb_wide_l3: out_cnt=%0d err_cnt=%0d", out_cnt, err_cnt);
        if (err_cnt == 0 && out_cnt == 38) $display("PASS");
        else                                $display("FAIL");
        $finish;
    end

    reg [15:0] out_cnt;
    initial out_cnt = 0;

    task check_eq;
        input integer idx_row, idx_px;
        input [15:0]  expected;
        input [31:0]  tag;
        begin
            if (get_px(wout, idx_row, idx_px) !== expected) begin
                $display("ERR out=%0d tag=%0d px[%0d,%0d]=%04X exp=%04X",
                         out_cnt, tag, idx_row, idx_px,
                         get_px(wout, idx_row, idx_px), expected);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    task check_lane;
        input [3:0]  expected;
        input [31:0] tag;
        begin
            if (wlane_valid !== expected) begin
                $display("ERR out=%0d tag=%0d lane_valid=%b exp=%b",
                         out_cnt, tag, wlane_valid, expected);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (wvalid) begin
            // out_cnt = 0 : word_cnt=0 of input row 2.
            //   Bottom slice covers cols [-3..2] = {row1 col149, col150, col151,
            //                                       row2 col0, col1, col2}.
            //   slice px 0 (LSB, newest) = col 2 of row 2.
            //   slice px 5 (MSB, oldest) = col 149 of row 1.
            //   lane_valid = 4'b1100.
            if (out_cnt == 0) begin
                check_lane(4'b1100, 0);
                check_eq(0, 0, img[2][2],   1);
                check_eq(0, 1, img[2][1],   2);
                check_eq(0, 2, img[2][0],   3);   // = 0 (left pad)
                check_eq(0, 3, img[1][151], 4);   // = 0 (prev row right pad)
                check_eq(0, 4, img[1][150], 5);
                check_eq(0, 5, img[1][149], 6);
                check_eq(1, 0, img[1][2],   7);
                check_eq(1, 2, img[1][0],   8);
                check_eq(2, 0, img[0][2],   9);
                check_eq(2, 2, img[0][0],  10);
            end

            // out_cnt = 1 : word_cnt=1, bottom slice covers cols [1..6] of row 2.
            //   slice px 0 = col 6, slice px 5 = col 1.
            if (out_cnt == 1) begin
                check_lane(4'b1111, 20);
                check_eq(0, 0, img[2][6], 21);
                check_eq(0, 3, img[2][3], 22);
                check_eq(0, 4, img[2][2], 23);
                check_eq(0, 5, img[2][1], 24);
            end

            // out_cnt = 37 : word_cnt=37, bottom slice covers cols [145..150].
            //   slice px 0 = col 150, slice px 5 = col 145.
            if (out_cnt == 37) begin
                check_lane(4'b1111, 40);
                check_eq(0, 0, img[2][150], 41);
                check_eq(0, 1, img[2][149], 42);
                check_eq(0, 3, img[2][147], 43);
                check_eq(0, 4, img[2][146], 44);
                check_eq(0, 5, img[2][145], 45);
            end

            out_cnt <= out_cnt + 1;
        end
    end

endmodule
