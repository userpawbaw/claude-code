`timescale 1ns / 1ps
// tb_lb_fsm.v — FSM 가 input BRAM 을 통해 line_buffer_wide 에 입력을
//               올바른 timing 으로 흘리고, 각 emit 의 slice 값이 padded 입력
//               이미지 (input.txt) 와 일치하는지 검증.  PE/PU/URAM 미포함.
//
//   L1 mode 만 검증 (i_pe_done = 0 으로 묶어두면 FSM 는 L1 stream 끝낸 후
//   S_DRAIN 에 머무른다).
//
//   검증 항목:
//     (1) 총 emit count = 2850 (= 150 출력 row × 19 emit).
//     (2) 첫 emit (out_row=1 word_cnt=1) slice 값 = padded row 2 col 0..8 +
//         padded row 1 col 151 (=0).
//     (3) 첫 boundary emit (out_row=1 word_cnt=0 of next row) slice 값 =
//         padded row 3 col 0 + padded row 2 col 144..151 + padded row 2 col 143.

module tb_lb_fsm;
    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    // ----------- FSM -----------
    wire        fsm_w_rd_en;
    wire [16:0] fsm_w_rd_addr;
    wire        fsm_bias_en;
    wire        fsm_i_rd_en;
    wire [16:0] fsm_i_rd_addr;
    wire        fsm_intermid_rd_en;
    wire [14:0] fsm_intermid_rd_addr;
    wire        fsm_dummy_valid;
    wire        fsm_pad_wr_en;
    wire        fsm_idle_rst;
    wire        fsm_dispatch_rst;
    wire        fsm_wr_addr_rst;
    wire [1:0]  fsm_layer_cnt;
    wire [2:0]  fsm_out_ch_cnt;
    wire [1:0]  fsm_img_cnt;
    wire        all_done;
    wire        img_done;

    FSM_pad u_fsm (
        .i_clk                   (clk),
        .i_rstn                  (rstn),
        .i_start                 (start),
        .i_line_img_done         (1'b0),
        .i_pe_done               (1'b0),   // never advance past L1 stream
        .i_uram_we               (1'b0),
        .o_w_rd_en               (fsm_w_rd_en),
        .o_w_rd_addr             (fsm_w_rd_addr),
        .o_bias_en               (fsm_bias_en),
        .o_i_rd_en               (fsm_i_rd_en),
        .o_i_rd_addr             (fsm_i_rd_addr),
        .o_intermid_uram_rd_en   (fsm_intermid_rd_en),
        .o_intermid_uram_rd_addr (fsm_intermid_rd_addr),
        .o_fifo_rd_en            (),
        .o_input_dummy_valid     (fsm_dummy_valid),
        .o_pad_wr_en             (fsm_pad_wr_en),
        .o_IDLE_rst              (fsm_idle_rst),
        .o_dispatch_rst          (fsm_dispatch_rst),
        .o_wr_addr_rst           (fsm_wr_addr_rst),
        .o_is_pad                (),
        .o_is_pad_valid          (),
        .o_line_done             (),
        .o_layer_cnt             (fsm_layer_cnt),
        .o_out_ch_cnt            (fsm_out_ch_cnt),
        .o_img_cnt               (fsm_img_cnt),
        .o_img_done              (img_done),
        .o_all_done              (all_done)
    );

    // ----------- input BRAM -----------
    wire         i_rd_valid;
    wire [127:0] i_dout;
    simple_dual_port_bram #(.WIDTH(128), .DEPTH(8664), .INIT_FILE("input.txt"))
        u_i_bram (
        .clk(clk), .wr_en(1'b0), .rd_en(fsm_i_rd_en),
        .wr_addr({17{1'b0}}), .rd_addr(fsm_i_rd_addr),
        .wr_din(128'h0), .rd_valid(i_rd_valid), .rd_dout(i_dout)
    );

    // ----------- weight BRAM (FSM가 S_W_READ 지나가게 필요) -----------
    wire         w_rd_valid;
    wire [127:0] w_dout;
    simple_dual_port_bram #(.WIDTH(128), .DEPTH(128), .INIT_FILE("weight.txt"))
        u_w_bram (
        .clk(clk), .wr_en(1'b0), .rd_en(fsm_w_rd_en),
        .wr_addr({17{1'b0}}), .rd_addr(fsm_w_rd_addr),
        .wr_din(128'h0), .rd_valid(w_rd_valid), .rd_dout(w_dout)
    );

    // ----------- Line buffer (ch 0 only) -----------
    wire [127:0] lb_data_in  = fsm_dummy_valid ? 128'h0 : i_dout;
    wire         lb_in_valid = (fsm_layer_cnt == 2'd0) && (i_rd_valid || fsm_dummy_valid);
    wire [479:0] lb_out;
    wire [7:0]   lb_lane_valid;
    wire         lb_line_valid;
    wire         lb_img_done;

    line_buffer_wide u_lb (
        .i_clk          (clk),
        .i_rstn         (rstn),
        .i_IDLE_rst     (fsm_idle_rst),
        .i_input_valid  (lb_in_valid),
        .i_input_data   (lb_data_in),
        .o_line_data    (lb_out),
        .o_lane_valid   (lb_lane_valid),
        .o_line_valid   (lb_line_valid),
        .o_line_rd_done (),
        .o_img_done     (lb_img_done)
    );

    // ----------- 기대 이미지 로드 -----------
    reg [15:0] img_pad [0:151][0:151];

    integer fi, code, row, cw, col;
    reg [127:0] word;
    initial begin
        fi = $fopen("input.txt", "r");
        if (fi == 0) begin $display("ERR open input.txt"); $finish; end
        for (row = 0; row < 152; row = row + 1) begin
            for (cw = 0; cw < 19; cw = cw + 1) begin
                code = $fscanf(fi, "%h\n", word);
                for (col = 0; col < 8; col = col + 1) begin
                    img_pad[row][cw*8 + col] = word[(7-col)*16 +: 16];
                end
            end
        end
        $fclose(fi);
        $display("img_pad[0][0]=%04x (=0 top pad), img_pad[1][0]=%04x (=0 left pad), img_pad[1][1]=%04x (real data)",
                 img_pad[0][0], img_pad[1][0], img_pad[1][1]);
    end

    // ----------- 검증 -----------
    integer emit_cnt;
    integer err_cnt;
    initial begin emit_cnt = 0; err_cnt = 0; end

    function [15:0] sl_px;
        input integer rw;       // 0=bot, 1=mid, 2=top
        input integer px;       // 0..9 (slice px)
        begin
            sl_px = lb_out[rw*160 + px*16 +: 16];
        end
    endfunction

    task chk;
        input integer rw, px;
        input [15:0] exp;
        input [31:0] tag;
        begin
            if (sl_px(rw, px) !== exp) begin
                $display("ERR emit %0d row %0d px %0d : got=%04x exp=%04x (tag=%0d)",
                         emit_cnt, rw, px, sl_px(rw, px), exp, tag);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (lb_line_valid) begin
            // 첫 emit (n=0) : out_row=1 word_cnt=1 emit. input row R=2.
            //   bot (r_line0) = padded row 2.
            //     px 0 = col 8 of row 2, px 8 = col 0 of row 2, px 9 = col 151 of row 1 (=0).
            //   mid (r_line1) = padded row 1.
            //     px 0 = col 8 of row 1, px 8 = col 0 of row 1, px 9 = col 151 of row 0 (=0).
            //   top (r_line2) = padded row 0 (= all 0 top padding).
            if (emit_cnt == 0) begin
                $display("== Emit 0 (out_row=1 word_cnt=1) lane_valid=%02x", lb_lane_valid);
                $display("  bot px0..9 = %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x",
                    sl_px(0,0), sl_px(0,1), sl_px(0,2), sl_px(0,3), sl_px(0,4),
                    sl_px(0,5), sl_px(0,6), sl_px(0,7), sl_px(0,8), sl_px(0,9));
                $display("  mid px0..9 = %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x",
                    sl_px(1,0), sl_px(1,1), sl_px(1,2), sl_px(1,3), sl_px(1,4),
                    sl_px(1,5), sl_px(1,6), sl_px(1,7), sl_px(1,8), sl_px(1,9));
                $display("  top px0..9 = %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x",
                    sl_px(2,0), sl_px(2,1), sl_px(2,2), sl_px(2,3), sl_px(2,4),
                    sl_px(2,5), sl_px(2,6), sl_px(2,7), sl_px(2,8), sl_px(2,9));
                chk(0, 0, img_pad[2][8], 100);
                chk(0, 1, img_pad[2][7], 101);
                chk(0, 7, img_pad[2][1], 102);
                chk(0, 8, img_pad[2][0], 103);   // = 0 (left pad of row 2)
                chk(0, 9, img_pad[1][151], 104); // = 0 (right pad of row 1), OR masked by lane_valid → check raw
                chk(1, 0, img_pad[1][8], 110);
                chk(1, 8, img_pad[1][0], 111);
                chk(2, 0, img_pad[0][8], 120);
                chk(2, 8, img_pad[0][0], 121);
            end

            // emit_cnt = 18 : out_row=1 word_cnt=0 of next row (= boundary). input row R=3.
            //   bot (r_line0) covers (col 0 of row 3) + cols 151..144 of row 2 + col 143 of row 2.
            //   mid (r_line1) covers (col 0 of row 2) + cols 151..144 of row 1 + col 143 of row 1.
            //   top (r_line2) covers (col 0 of row 1) + cols 151..144 of row 0 + col 143 of row 0.
            if (emit_cnt == 18) begin
                $display("== Emit 18 (out_row=1 boundary) lane_valid=%02x", lb_lane_valid);
                $display("  bot px0..9 = %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x",
                    sl_px(0,0), sl_px(0,1), sl_px(0,2), sl_px(0,3), sl_px(0,4),
                    sl_px(0,5), sl_px(0,6), sl_px(0,7), sl_px(0,8), sl_px(0,9));
                $display("  mid px0..9 = %04x %04x %04x %04x %04x %04x %04x %04x %04x %04x",
                    sl_px(1,0), sl_px(1,1), sl_px(1,2), sl_px(1,3), sl_px(1,4),
                    sl_px(1,5), sl_px(1,6), sl_px(1,7), sl_px(1,8), sl_px(1,9));
                chk(0, 0, img_pad[3][0], 200);     // = 0 left pad of row 3
                chk(0, 1, img_pad[2][151], 201);   // = 0 right pad of row 2
                chk(0, 2, img_pad[2][150], 202);
                chk(0, 8, img_pad[2][144], 203);
                chk(0, 9, img_pad[2][143], 204);
                chk(1, 0, img_pad[2][0], 210);     // = 0
                chk(1, 1, img_pad[1][151], 211);   // = 0
                chk(1, 2, img_pad[1][150], 212);
                chk(1, 9, img_pad[1][143], 213);
                chk(2, 0, img_pad[1][0], 220);
                chk(2, 8, img_pad[0][144], 221);   // = 0 (top pad)
            end

            emit_cnt = emit_cnt + 1;
        end
    end

    // 시뮬 종료
    initial begin
        rstn = 0;
        repeat (4) @(posedge clk);
        rstn = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // L1 stream + drain : ~3500 cycle
        repeat (3500) @(posedge clk);

        $display("");
        $display("Total emits = %0d (expected 2850)", emit_cnt);
        $display("Error count = %0d", err_cnt);
        if (emit_cnt == 2850 && err_cnt == 0) $display("PASS");
        else                                    $display("FAIL");
        $finish;
    end
endmodule
