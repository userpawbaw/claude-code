`timescale 1ns / 1ps
// tb_pu_l1.v — PU 만 떼서 L1 출력 검증.
//   FSM_pad + input BRAM + weight BRAM + PU. URAM/packer 없음.
//   i_pe_done = 0 으로 FSM 가 S_DRAIN 에서 멈춘 채 L1 emit 만 수집.
//   각 emit 마다 8 oc × 8 lane = 64 픽셀을 golden_L1 과 비교.
//
//   검증 목적 : line buffer 윈도우는 OK (tb_lb_fsm).  남은 의심은
//     (a) lane→col 정렬 + sub-window 추출,
//     (b) per-(oc,lane) bias / >>>8 / sat,
//     (c) lane_valid mask 정렬.

module tb_pu_l1;
    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    // ---------- FSM ----------
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
        .i_clk(clk), .i_rstn(rstn), .i_start(start),
        .i_line_img_done(1'b0), .i_pe_done(1'b0), .i_uram_we(1'b0),
        .o_w_rd_en(fsm_w_rd_en), .o_w_rd_addr(fsm_w_rd_addr),
        .o_bias_en(fsm_bias_en),
        .o_i_rd_en(fsm_i_rd_en), .o_i_rd_addr(fsm_i_rd_addr),
        .o_intermid_uram_rd_en(fsm_intermid_rd_en),
        .o_intermid_uram_rd_addr(fsm_intermid_rd_addr),
        .o_fifo_rd_en(), .o_input_dummy_valid(fsm_dummy_valid),
        .o_pad_wr_en(fsm_pad_wr_en),
        .o_IDLE_rst(fsm_idle_rst), .o_dispatch_rst(fsm_dispatch_rst),
        .o_wr_addr_rst(fsm_wr_addr_rst),
        .o_is_pad(), .o_is_pad_valid(), .o_line_done(),
        .o_layer_cnt(fsm_layer_cnt), .o_out_ch_cnt(fsm_out_ch_cnt),
        .o_img_cnt(fsm_img_cnt),
        .o_img_done(img_done), .o_all_done(all_done)
    );

    // ---------- Memories ----------
    wire         i_rd_valid;
    wire [127:0] i_dout;
    simple_dual_port_bram #(.WIDTH(128), .DEPTH(8664), .INIT_FILE("input.txt"))
        u_i_bram (
        .clk(clk), .wr_en(1'b0), .rd_en(fsm_i_rd_en),
        .wr_addr({17{1'b0}}), .rd_addr(fsm_i_rd_addr),
        .wr_din(128'h0), .rd_valid(i_rd_valid), .rd_dout(i_dout)
    );
    wire         w_rd_valid;
    wire [127:0] w_dout;
    simple_dual_port_bram #(.WIDTH(128), .DEPTH(128), .INIT_FILE("weight.txt"))
        u_w_bram (
        .clk(clk), .wr_en(1'b0), .rd_en(fsm_w_rd_en),
        .wr_addr({17{1'b0}}), .rd_addr(fsm_w_rd_addr),
        .wr_din(128'h0), .rd_valid(w_rd_valid), .rd_dout(w_dout)
    );

    // ---------- PU ----------
    wire [127:0] l1_data_in = fsm_dummy_valid ? 128'h0 : i_dout;
    wire [8*128-1:0] pu_data_wide = { l1_data_in, {7{128'h0}} };
    wire [8*64-1:0]  pu_data_l3   = 0;
    wire pu_input_valid = (fsm_layer_cnt == 2'd0) && (i_rd_valid || fsm_dummy_valid);

    wire        pu_emit_valid;
    wire [7:0]  pu_oc_mask;
    wire [63:0] pu_lane_mask;
    wire [1023:0] pu_pixel_data;

    PU #(.MAX_CH(8)) u_pu (
        .i_clk(clk), .i_rstn(rstn),
        .i_IDLE_rst(fsm_idle_rst), .i_dispatch_rst(fsm_dispatch_rst),
        .i_layer_cnt(fsm_layer_cnt), .i_out_ch_cnt(fsm_out_ch_cnt),
        .i_input_valid(pu_input_valid),
        .i_uram_data_wide(pu_data_wide), .i_uram_data_l3(pu_data_l3),
        .i_w_rd_en(w_rd_valid), .i_weight_bram_data(w_dout),
        .i_bias_en(fsm_bias_en),
        .o_emit_valid(pu_emit_valid),
        .o_oc_valid_mask(pu_oc_mask),
        .o_lane_valid_mask(pu_lane_mask),
        .o_pixel_data(pu_pixel_data),
        .o_img_done()
    );

    // ---------- Golden load ----------
    reg [15:0] gL1 [0:7][0:151][0:151];   // img 0 only
    integer fi, code, ch_, row, cw, col;
    reg [127:0] gword;
    initial begin
        fi = $fopen("golden_L1.txt", "r");
        if (fi == 0) begin $display("ERR open golden_L1.txt"); $finish; end
        for (ch_ = 0; ch_ < 8; ch_ = ch_ + 1) begin
            for (row = 0; row < 152; row = row + 1) begin
                for (cw = 0; cw < 19; cw = cw + 1) begin
                    code = $fscanf(fi, "%h\n", gword);
                    for (col = 0; col < 8; col = col + 1)
                        gL1[ch_][row][cw*8 + col] = gword[(7-col)*16 +: 16];
                end
            end
        end
        $fclose(fi);
        $display("golden L1 loaded. ch0 r1 c1..3 = %04x %04x %04x",
                 gL1[0][1][1], gL1[0][1][2], gL1[0][1][3]);
    end

    // ---------- Capture & compare ----------
    integer emit_cnt;
    integer err_cnt;
    integer first_err_emit;
    integer oc, ln, out_row, out_cw, out_col, gline;
    reg [15:0] got, exp;
    initial begin
        emit_cnt = 0;
        err_cnt = 0;
        first_err_emit = -1;
    end

    always @(posedge clk) begin
        if (pu_emit_valid && (fsm_layer_cnt == 2'd0 || emit_cnt < 2850)) begin
            // Map emit_cnt → out_row, out_col_word
            out_row = 1 + emit_cnt/19;        // 1..150
            out_cw  = emit_cnt % 19;          // 0..18 of output row
            for (oc = 0; oc < 8; oc = oc + 1) begin
                for (ln = 0; ln < 8; ln = ln + 1) begin
                    // oc slot bits [oc*128 + (7-ln)*16 +: 16]  (lane 0 = MSB inside slot)
                    got = pu_pixel_data[oc*128 + (7-ln)*16 +: 16];
                    out_col = out_cw*8 + ln;      // 0..151
                    exp = gL1[oc][out_row][out_col];
                    if (got !== exp) begin
                        if (err_cnt < 32) begin
                            $display("MISMATCH emit %0d oc %0d lane %0d (row %0d col %0d) got=%04x exp=%04x lane_v=%b",
                                got > 0 ? 1 : 0, oc, ln, out_row, out_col, got, exp,
                                pu_lane_mask[oc*8 +: 8]);
                            $display("  emit_cnt=%0d", emit_cnt);
                        end
                        err_cnt = err_cnt + 1;
                        if (first_err_emit < 0) first_err_emit = emit_cnt;
                    end
                end
            end
            // Dump first emit raw
            if (emit_cnt == 0) begin
                $display("== Emit 0 (out_row 1, cw 0) oc_mask=%02x", pu_oc_mask);
                for (oc = 0; oc < 8; oc = oc + 1) begin
                    $display(" oc%0d lane_v=%02x  px = %04x %04x %04x %04x %04x %04x %04x %04x",
                        oc, pu_lane_mask[oc*8 +: 8],
                        pu_pixel_data[oc*128 + 7*16 +: 16],
                        pu_pixel_data[oc*128 + 6*16 +: 16],
                        pu_pixel_data[oc*128 + 5*16 +: 16],
                        pu_pixel_data[oc*128 + 4*16 +: 16],
                        pu_pixel_data[oc*128 + 3*16 +: 16],
                        pu_pixel_data[oc*128 + 2*16 +: 16],
                        pu_pixel_data[oc*128 + 1*16 +: 16],
                        pu_pixel_data[oc*128 + 0*16 +: 16]);
                    $display("  exp[oc%0d r1 c0..7] = %04x %04x %04x %04x %04x %04x %04x %04x",
                        oc, gL1[oc][1][0], gL1[oc][1][1], gL1[oc][1][2], gL1[oc][1][3],
                        gL1[oc][1][4], gL1[oc][1][5], gL1[oc][1][6], gL1[oc][1][7]);
                end
            end
            emit_cnt = emit_cnt + 1;
        end
    end

    initial begin
        rstn = 0;
        repeat (4) @(posedge clk);
        rstn = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        repeat (3600) @(posedge clk);

        $display("");
        $display("Total L1 emits = %0d (expected 2850)", emit_cnt);
        $display("Error count    = %0d", err_cnt);
        if (first_err_emit >= 0)
            $display("First err emit = %0d (out_row %0d out_cw %0d)",
                first_err_emit, 1 + first_err_emit/19, first_err_emit%19);
        if (emit_cnt == 2850 && err_cnt == 0) $display("PASS");
        else                                    $display("FAIL");
        $finish;
    end
endmodule
