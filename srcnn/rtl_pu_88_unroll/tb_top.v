`timescale 1ns / 1ps
// tb_top.v — UNROLL preset 8_8 통합 TB (3 image 연속).
//
//   Capture format :
//     - L1/L2 : packer 128-bit URAM word (= 8 px), packed-padded 152×152 per ch.
//     - L3    : 4-px / clk (per-lane valid), packed-unpadded 150×150 per img.
//
//   gen_golden.py 가 produce 하는 golden_L1.txt / golden_L2.txt / golden_out.txt
//   는 모두 32 hex / line (128 bit), padded 152×152 포맷. tb 가 동일 word 단위로
//   비교한다.
//
//   각 image 당 word 수 :
//     - L1/L2 per ch : 152 row × 19 col_word = 2888 word.
//     - OUT per ch   : 동일 2888 word (152×152 padded).

module tb_top;
    reg  clk  = 0;
    reg  rstn = 0;
    reg  start = 0;
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

    always #5 clk = ~clk;

    localparam NIMG          = 3;
    localparam OC1           = 8;
    localparam OC2           = 8;
    localparam WORDS_PER_CH  = 2888;       // 152 × 19
    localparam PIX_PER_CH    = WORDS_PER_CH * 8;   // 23104 (= 152×152 padded)
    localparam OUT_PIX_PER_IMG = 150 * 150;        // unpadded

    // Golden in 16-bit pixels. L1/L2 = 152×152 padded per ch.
    reg [15:0] gold_L1  [0 : NIMG*OC1*PIX_PER_CH - 1];
    reg [15:0] gold_L2  [0 : NIMG*OC2*PIX_PER_CH - 1];
    reg [15:0] gold_out [0 : NIMG*PIX_PER_CH - 1];

    // Capture buffers.
    reg [15:0] cap_L1  [0 : NIMG*OC1*PIX_PER_CH - 1];
    reg [15:0] cap_L2  [0 : NIMG*OC2*PIX_PER_CH - 1];
    reg [15:0] cap_out [0 : NIMG*OUT_PIX_PER_IMG - 1];

    integer cap_L1_idx;
    integer cap_L2_idx [0:OC2-1];
    integer cap_out_idx;
    integer cur_img;

    // golden 로드 : 각 라인 32 hex = 128 bit = 8 px. 16-bit 단위로 split.
    reg [127:0] tmp_g [0 : NIMG*OC1*WORDS_PER_CH - 1];
    integer    gi, gp;

    integer ich;
    integer kk;

    function [15:0] px_in_word;
        input [127:0] w;
        input integer idx;          // 0 = MSB px, 7 = LSB px
        begin
            px_in_word = w[(7-idx)*16 +: 16];
        end
    endfunction

    // L1 capture : layer==0, pack_we OR pad_wr_en (= URAM wr_addr advances).
    //   pad_wr_en → 0 data, pack_we → real PU emit.
    always @(posedge clk) begin
        if (!rstn) cap_L1_idx <= 0;
        else if (dut.w_layer_cnt == 2'd0
                 && (dut.w_pack_we[0] || dut.w_pad_wr_en)) begin
            for (ich = 0; ich < OC1; ich = ich + 1) begin : cap_L1_loop
                reg [127:0] w128;
                w128 = dut.w_pad_wr_en ? 128'h0
                                       : dut.w_pack_dout_flat[128*ich +: 128];
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 0] <= px_in_word(w128, 0);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 1] <= px_in_word(w128, 1);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 2] <= px_in_word(w128, 2);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 3] <= px_in_word(w128, 3);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 4] <= px_in_word(w128, 4);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 5] <= px_in_word(w128, 5);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 6] <= px_in_word(w128, 6);
                cap_L1[(cur_img*OC1 + ich)*PIX_PER_CH + cap_L1_idx + 7] <= px_in_word(w128, 7);
            end
            cap_L1_idx <= cap_L1_idx + 8;
        end
    end

    // L2 capture : layer==1, pack_we[0] OR pad_wr_en, oc per out_ch_cnt.
    always @(posedge clk) begin
        if (!rstn) begin
            for (kk = 0; kk < OC2; kk = kk + 1) cap_L2_idx[kk] <= 0;
        end else if (dut.w_layer_cnt == 2'd1
                     && (dut.w_pack_we[0] || dut.w_pad_wr_en)) begin : cap_L2_blk
            reg [127:0] w128;
            w128 = dut.w_pad_wr_en ? 128'h0
                                   : dut.w_pack_dout_flat[0 +: 128];
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 0] <= px_in_word(w128, 0);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 1] <= px_in_word(w128, 1);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 2] <= px_in_word(w128, 2);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 3] <= px_in_word(w128, 3);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 4] <= px_in_word(w128, 4);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 5] <= px_in_word(w128, 5);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 6] <= px_in_word(w128, 6);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*PIX_PER_CH + cap_L2_idx[dut.w_out_ch_cnt] + 7] <= px_in_word(w128, 7);
            cap_L2_idx[dut.w_out_ch_cnt] <= cap_L2_idx[dut.w_out_ch_cnt] + 8;
        end
    end

    // L3 (final output) capture : 4 px / clk, lane_valid 마스크.
    integer li;
    always @(posedge clk) begin
        if (!rstn) cap_out_idx <= 0;
        else if (pix_valid) begin
            for (li = 0; li < 4; li = li + 1) begin
                if (lane_valid[li]) begin
                    cap_out[cur_img*OUT_PIX_PER_IMG + cap_out_idx] <= pix_data[(3-li)*16 +: 16];
                    cap_out_idx <= cap_out_idx + 1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rstn) cur_img <= 0;
        else if (img_done) begin
            cap_L1_idx  <= 0;
            for (kk = 0; kk < OC2; kk = kk + 1) cap_L2_idx[kk] <= 0;
            cap_out_idx <= 0;
            cur_img     <= cur_img + 1;
        end
    end

    // Load golden : 32-hex / line = 128 bit word, split into 8 × 16-bit.
    // (inline loops in initial block below.)

    integer i, errL1, errL2, errOut;
    integer fi, idx;
    reg [127:0] w_tmp;
    integer code;

    initial begin
        // ----- Load golden manually (verilog2001 simple loop) -----
        fi = $fopen("golden_L1.txt", "r");
        if (fi == 0) begin $display("ERR open golden_L1.txt"); $finish; end
        for (idx = 0; idx < NIMG*OC1*WORDS_PER_CH; idx = idx + 1) begin
            code = $fscanf(fi, "%h\n", w_tmp);
            gold_L1[idx*8 + 0] = w_tmp[127:112];
            gold_L1[idx*8 + 1] = w_tmp[111:96];
            gold_L1[idx*8 + 2] = w_tmp[95:80];
            gold_L1[idx*8 + 3] = w_tmp[79:64];
            gold_L1[idx*8 + 4] = w_tmp[63:48];
            gold_L1[idx*8 + 5] = w_tmp[47:32];
            gold_L1[idx*8 + 6] = w_tmp[31:16];
            gold_L1[idx*8 + 7] = w_tmp[15:0];
        end
        $fclose(fi);

        fi = $fopen("golden_L2.txt", "r");
        for (idx = 0; idx < NIMG*OC2*WORDS_PER_CH; idx = idx + 1) begin
            code = $fscanf(fi, "%h\n", w_tmp);
            gold_L2[idx*8 + 0] = w_tmp[127:112];
            gold_L2[idx*8 + 1] = w_tmp[111:96];
            gold_L2[idx*8 + 2] = w_tmp[95:80];
            gold_L2[idx*8 + 3] = w_tmp[79:64];
            gold_L2[idx*8 + 4] = w_tmp[63:48];
            gold_L2[idx*8 + 5] = w_tmp[47:32];
            gold_L2[idx*8 + 6] = w_tmp[31:16];
            gold_L2[idx*8 + 7] = w_tmp[15:0];
        end
        $fclose(fi);

        fi = $fopen("golden_out.txt", "r");
        for (idx = 0; idx < NIMG*WORDS_PER_CH; idx = idx + 1) begin
            code = $fscanf(fi, "%h\n", w_tmp);
            gold_out[idx*8 + 0] = w_tmp[127:112];
            gold_out[idx*8 + 1] = w_tmp[111:96];
            gold_out[idx*8 + 2] = w_tmp[95:80];
            gold_out[idx*8 + 3] = w_tmp[79:64];
            gold_out[idx*8 + 4] = w_tmp[63:48];
            gold_out[idx*8 + 5] = w_tmp[47:32];
            gold_out[idx*8 + 6] = w_tmp[31:16];
            gold_out[idx*8 + 7] = w_tmp[15:0];
        end
        $fclose(fi);

        rstn = 0;
        repeat (4) @(posedge clk);
        rstn = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        wait (all_done);
        repeat (50) @(posedge clk);

        errL1 = 0;
        for (i = 0; i < NIMG*OC1*PIX_PER_CH; i = i + 1)
            if (cap_L1[i] !== gold_L1[i]) begin
                if (errL1 < 10)
                    $display("L1 MISMATCH idx%0d : got=%04x exp=%04x", i, cap_L1[i], gold_L1[i]);
                errL1 = errL1 + 1;
            end

        errL2 = 0;
        for (i = 0; i < NIMG*OC2*PIX_PER_CH; i = i + 1)
            if (cap_L2[i] !== gold_L2[i]) begin
                if (errL2 < 10)
                    $display("L2 MISMATCH idx%0d : got=%04x exp=%04x", i, cap_L2[i], gold_L2[i]);
                errL2 = errL2 + 1;
            end

        // L3 output : compare against unpadded 150×150 region of golden_out.
        errOut = 0;
        for (i = 0; i < NIMG*OUT_PIX_PER_IMG; i = i + 1) begin : check_out
            integer img_idx, r, c, gold_idx;
            img_idx  = i / OUT_PIX_PER_IMG;
            r        = (i % OUT_PIX_PER_IMG) / 150;
            c        = (i % OUT_PIX_PER_IMG) % 150;
            gold_idx = img_idx * PIX_PER_CH + (r + 1) * 152 + (c + 1);
            if (cap_out[i] !== gold_out[gold_idx]) begin
                if (errOut < 10)
                    $display("OUT MISMATCH idx%0d img%0d r%0d c%0d : got=%04x exp=%04x",
                             i, img_idx, r, c, cap_out[i], gold_out[gold_idx]);
                errOut = errOut + 1;
            end
        end

        $display("");
        $display("=== L1  : %0d / %0d errors", errL1, NIMG*OC1*PIX_PER_CH);
        $display("=== L2  : %0d / %0d errors", errL2, NIMG*OC2*PIX_PER_CH);
        $display("=== OUT : %0d / %0d errors", errOut, NIMG*OUT_PIX_PER_IMG);
        if (errL1==0 && errL2==0 && errOut==0) $display("ALL PASS");
        else                                   $display("ALL FAIL");
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT layer=%0d img=%0d capL1=%0d capOut=%0d all_done=%b",
                 dut.w_layer_cnt, dut.w_img_cnt, cap_L1_idx, cap_out_idx, all_done);
        $finish;
    end

endmodule
