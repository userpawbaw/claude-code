`timescale 1ns/1ps
// tb_fsm.v — FSM_pad unit test for unrolled design.
// Checks per-layer: weight read count, stream length, URAM read count,
// FIFO read count, input BRAM read count, layer/image progression.
module tb_fsm;
    reg         clk, rstn, start;
    reg         pe_done, uram_we;

    wire        w_rd_en, bias_en;
    wire [16:0] w_rd_addr;
    wire        i_rd_en;
    wire [16:0] i_rd_addr;
    wire        uram_rd_en;
    wire [14:0] uram_rd_addr;
    wire        fifo_rd_en;
    wire        idle_rst, dispatch_rst, wr_addr_rst;
    wire        is_pad, is_pad_valid, line_done;
    wire [1:0]  layer_cnt;
    wire [2:0]  out_ch_cnt;
    wire [1:0]  img_cnt;
    wire        img_done, all_done;

    FSM_pad #(
        .I_NUM(152), .O_NUM(150), .WORDS_PER_ROW(19),
        .NPIX_IMG(2888), .MEM_ADDR_WIDTH(17), .NUM_IMG(3)
    ) uut (
        .i_clk(clk), .i_rstn(rstn), .i_start(start),
        .i_line_img_done(1'b0), .i_pe_done(pe_done), .i_uram_we(uram_we),
        .o_w_rd_en(w_rd_en), .o_w_rd_addr(w_rd_addr), .o_bias_en(bias_en),
        .o_i_rd_en(i_rd_en), .o_i_rd_addr(i_rd_addr),
        .o_intermid_uram_rd_en(uram_rd_en), .o_intermid_uram_rd_addr(uram_rd_addr),
        .o_fifo_rd_en(fifo_rd_en),
        .o_IDLE_rst(idle_rst), .o_dispatch_rst(dispatch_rst),
        .o_wr_addr_rst(wr_addr_rst),
        .o_is_pad(is_pad), .o_is_pad_valid(is_pad_valid),
        .o_line_done(line_done),
        .o_layer_cnt(layer_cnt), .o_out_ch_cnt(out_ch_cnt),
        .o_img_cnt(img_cnt),
        .o_img_done(img_done), .o_all_done(all_done)
    );

    always #5 clk = ~clk;

    integer err_cnt;
    integer cnt_w_rd, cnt_bias, cnt_i_rd, cnt_uram_rd, cnt_fifo_rd;
    integer cnt_stream_clk;
    integer saved_layer, saved_img;

    task reset_counters;
    begin
        cnt_w_rd       = 0;
        cnt_bias       = 0;
        cnt_i_rd       = 0;
        cnt_uram_rd    = 0;
        cnt_fifo_rd    = 0;
        cnt_stream_clk = 0;
    end
    endtask

    task wait_for_state;
        input [1:0] target;
        integer timeout;
    begin
        timeout = 0;
        while (uut.r_ps !== target && timeout < 200000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 200000) begin
            $display("TIMEOUT waiting for state %0d at layer=%0d img=%0d", target, layer_cnt, img_cnt);
            err_cnt = err_cnt + 1;
        end
    end
    endtask

    task run_one_layer;
    begin
        reset_counters;
        saved_layer = layer_cnt;
        saved_img   = img_cnt;

        // wait for W_READ to start
        wait_for_state(2'd1);

        // count weight reads
        while (uut.r_ps == 2'd1) begin
            @(posedge clk);
            if (w_rd_en) cnt_w_rd = cnt_w_rd + 1;
            if (bias_en) cnt_bias = cnt_bias + 1;
        end

        // now in I_STREAM — count everything
        while (uut.r_ps == 2'd2) begin
            @(posedge clk);
            cnt_stream_clk = cnt_stream_clk + 1;
            if (i_rd_en)    cnt_i_rd    = cnt_i_rd + 1;
            if (uram_rd_en) cnt_uram_rd = cnt_uram_rd + 1;
            if (fifo_rd_en) cnt_fifo_rd = cnt_fifo_rd + 1;
        end

        // now in DONE — pulse pe_done after a few clocks
        repeat(5) @(posedge clk);
        pe_done <= 1'b1;
        @(posedge clk);
        pe_done <= 1'b0;

        // wait for IDLE
        wait_for_state(2'd0);
        @(posedge clk);
    end
    endtask

    task check_val;
        input integer actual, expected;
        input [255:0] name;
    begin
        if (actual !== expected) begin
            $display("ERR L%0d img%0d: %0s = %0d, expected %0d",
                     saved_layer, saved_img, name, actual, expected);
            err_cnt = err_cnt + 1;
        end
    end
    endtask

    initial begin
        clk = 0; rstn = 0; start = 0; pe_done = 0; uram_we = 0;
        err_cnt = 0;

        #20 rstn = 1;
        #10;

        // ---- image 0 ----
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // L1 (layer 0)
        run_one_layer;
        check_val(cnt_w_rd, 10, "w_rd_count");
        check_val(cnt_bias, 1,  "bias_count");
        check_val(cnt_i_rd, 2888, "i_rd_count");
        check_val(cnt_uram_rd, 0, "uram_rd_count");
        check_val(cnt_fifo_rd, 0, "fifo_rd_count");
        check_val(cnt_stream_clk, 2888, "stream_clk");
        $display("img%0d L1 OK: w=%0d bias=%0d i_rd=%0d stream=%0d",
                 saved_img, cnt_w_rd, cnt_bias, cnt_i_rd, cnt_stream_clk);

        // L2 (layer 1)
        run_one_layer;
        check_val(cnt_w_rd, 73, "w_rd_count");
        check_val(cnt_bias, 1,  "bias_count");
        check_val(cnt_i_rd, 0,  "i_rd_count");
        // URAM preload in W_READ(1) + I_STREAM(23104/8 = 2888)
        check_val(cnt_uram_rd, 2888, "uram_rd_count");
        check_val(cnt_fifo_rd, 23104, "fifo_rd_count");
        check_val(cnt_stream_clk, 23104, "stream_clk");
        $display("img%0d L2 OK: w=%0d bias=%0d uram=%0d fifo=%0d stream=%0d",
                 saved_img, cnt_w_rd, cnt_bias, cnt_uram_rd, cnt_fifo_rd, cnt_stream_clk);

        // L3 (layer 2)
        run_one_layer;
        check_val(cnt_w_rd, 10, "w_rd_count");
        check_val(cnt_bias, 1,  "bias_count");
        check_val(cnt_i_rd, 0,  "i_rd_count");
        // URAM preload(1) + I_STREAM(2888)
        check_val(cnt_uram_rd, 2888, "uram_rd_count");
        check_val(cnt_fifo_rd, 0,    "fifo_rd_count");
        check_val(cnt_stream_clk, 2888, "stream_clk");
        $display("img%0d L3 OK: w=%0d bias=%0d uram=%0d stream=%0d",
                 saved_img, cnt_w_rd, cnt_bias, cnt_uram_rd, cnt_stream_clk);

        // ---- image 1: just check layer progression ----
        run_one_layer;  // L1
        check_val(saved_img, 1, "img_cnt_L1");
        check_val(saved_layer, 0, "layer_cnt");
        check_val(cnt_i_rd, 2888, "i_rd_count");
        $display("img1 L1 OK");

        run_one_layer;  // L2
        check_val(cnt_fifo_rd, 23104, "fifo_rd_count");
        $display("img1 L2 OK");

        run_one_layer;  // L3
        $display("img1 L3 OK");

        // ---- image 2: check final signals ----
        run_one_layer;  // L1
        check_val(saved_img, 2, "img_cnt");
        $display("img2 L1 OK");

        run_one_layer;  // L2
        $display("img2 L2 OK");

        // L3 — last layer of last image
        reset_counters;
        saved_layer = layer_cnt;
        saved_img   = img_cnt;
        wait_for_state(2'd1);
        while (uut.r_ps == 2'd1) @(posedge clk);
        while (uut.r_ps == 2'd2) @(posedge clk);
        // in DONE, pulse pe_done
        repeat(5) @(posedge clk);
        pe_done <= 1'b1;
        @(posedge clk);
        pe_done <= 1'b0;
        repeat(3) @(posedge clk);

        if (!all_done) begin
            $display("ERR: all_done not asserted after 3 images");
            err_cnt = err_cnt + 1;
        end
        $display("img2 L3 OK, all_done=%b", all_done);

        // ---- check is_pad always 0 ----
        if (is_pad !== 0 || is_pad_valid !== 0) begin
            $display("ERR: is_pad or is_pad_valid not 0");
            err_cnt = err_cnt + 1;
        end
        if (out_ch_cnt !== 3'd0) begin
            $display("ERR: out_ch_cnt not 0");
            err_cnt = err_cnt + 1;
        end

        // ---- summary ----
        $display("tb_fsm: err_cnt = %0d", err_cnt);
        if (err_cnt == 0) $display("PASS");
        else              $display("FAIL");
        $finish;
    end

    // monitor is_pad — should never go high
    always @(posedge clk) begin
        if (is_pad || is_pad_valid) begin
            $display("ERR @ %0t: is_pad=%b is_pad_valid=%b", $time, is_pad, is_pad_valid);
            err_cnt = err_cnt + 1;
        end
    end

    // L1 address check: first read of each image should start at img*2888
    always @(posedge clk) begin
        if (i_rd_en && layer_cnt == 2'd0 && cnt_i_rd == 0) begin
            if (i_rd_addr !== img_cnt * 2888) begin
                $display("ERR: L1 first i_rd_addr = %0d, expected %0d",
                         i_rd_addr, img_cnt * 2888);
                err_cnt = err_cnt + 1;
            end
        end
    end

endmodule
