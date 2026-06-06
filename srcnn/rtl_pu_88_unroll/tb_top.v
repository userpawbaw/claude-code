`timescale 1ns / 1ps
// tb_top.v — rtl_pu_88 통합 TB (3 image 연속).
//   캡처: pack_we[*] / o_pixel_valid (L3). img_done 펄스마다 layer-wise cap idx 초기화.
module tb_top;
    reg  clk  = 0;
    reg  rstn = 0;
    reg  start = 0;
    wire img_done, all_done;
    wire pix_valid;
    wire [15:0] pix_data;

    top dut (
        .i_clk         (clk),
        .i_rstn        (rstn),
        .i_start       (start),
        .o_img_done    (img_done),
        .o_all_done    (all_done),
        .o_pixel_valid (pix_valid),
        .o_pixel_data  (pix_data)
    );

    always #5 clk = ~clk;

    localparam NPIX = 150*150;
    localparam NIMG = 3;
    localparam OC1  = 8;
    localparam OC2  = 8;

    reg [15:0] gold_L1  [0 : NIMG*OC1*NPIX - 1];
    reg [15:0] gold_L2  [0 : NIMG*OC2*NPIX - 1];
    reg [15:0] gold_out [0 : NIMG*1*NPIX - 1];

    reg [15:0] cap_L1  [0 : NIMG*OC1*NPIX - 1];
    reg [15:0] cap_L2  [0 : NIMG*OC2*NPIX - 1];
    reg [15:0] cap_out [0 : NIMG*1*NPIX - 1];

    integer cap_L1_idx;
    integer cap_L2_idx [0:OC2-1];
    integer cap_out_idx;
    integer cur_img;

    function [15:0] pix_of(input [63:0] w, input [1:0] sub);
        case (sub)
            2'd0: pix_of = w[63:48];
            2'd1: pix_of = w[47:32];
            2'd2: pix_of = w[31:16];
            2'd3: pix_of = w[15:0];
        endcase
    endfunction

    integer ich;

    // L1 capture (layer==0, packer[0..7] 동시)
    always @(posedge clk) begin
        if (!rstn) cap_L1_idx <= 0;
        else if (dut.w_layer_cnt == 2'd0 && dut.w_pack_we[0]) begin
            for (ich = 0; ich < OC1; ich = ich + 1) begin
                cap_L1[(cur_img*OC1 + ich)*NPIX + cap_L1_idx + 0] <= pix_of(dut.w_pack_dout_flat[64*ich +: 64], 2'd0);
                cap_L1[(cur_img*OC1 + ich)*NPIX + cap_L1_idx + 1] <= pix_of(dut.w_pack_dout_flat[64*ich +: 64], 2'd1);
                cap_L1[(cur_img*OC1 + ich)*NPIX + cap_L1_idx + 2] <= pix_of(dut.w_pack_dout_flat[64*ich +: 64], 2'd2);
                cap_L1[(cur_img*OC1 + ich)*NPIX + cap_L1_idx + 3] <= pix_of(dut.w_pack_dout_flat[64*ich +: 64], 2'd3);
            end
            cap_L1_idx <= cap_L1_idx + 4;
        end
    end

    // L2 capture (layer==1, packer[0], oc per out_ch_cnt)
    integer kk;
    always @(posedge clk) begin
        if (!rstn) begin
            for (kk = 0; kk < OC2; kk = kk + 1) cap_L2_idx[kk] <= 0;
        end else if (dut.w_layer_cnt == 2'd1 && dut.w_pack_we[0]) begin
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*NPIX + cap_L2_idx[dut.w_out_ch_cnt] + 0] <= pix_of(dut.w_pack_dout_flat[0 +: 64], 2'd0);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*NPIX + cap_L2_idx[dut.w_out_ch_cnt] + 1] <= pix_of(dut.w_pack_dout_flat[0 +: 64], 2'd1);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*NPIX + cap_L2_idx[dut.w_out_ch_cnt] + 2] <= pix_of(dut.w_pack_dout_flat[0 +: 64], 2'd2);
            cap_L2[(cur_img*OC2 + dut.w_out_ch_cnt)*NPIX + cap_L2_idx[dut.w_out_ch_cnt] + 3] <= pix_of(dut.w_pack_dout_flat[0 +: 64], 2'd3);
            cap_L2_idx[dut.w_out_ch_cnt] <= cap_L2_idx[dut.w_out_ch_cnt] + 4;
        end
    end

    // L3 (output) capture
    always @(posedge clk) begin
        if (!rstn) cap_out_idx <= 0;
        else if (pix_valid && cap_out_idx < NPIX) begin
            cap_out[cur_img*NPIX + cap_out_idx] <= pix_data;
            cap_out_idx <= cap_out_idx + 1;
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

    integer i, errL1, errL2, errOut;
    initial begin
        $readmemh("golden_L1.txt",  gold_L1);
        $readmemh("golden_L2.txt",  gold_L2);
        $readmemh("golden_out.txt", gold_out);

        rstn = 0;
        repeat (4) @(posedge clk);
        rstn = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        wait (all_done);
        repeat (50) @(posedge clk);

        errL1 = 0;
        for (i = 0; i < NIMG*OC1*NPIX; i = i + 1)
            if (cap_L1[i] !== gold_L1[i]) begin
                if (errL1 < 10)
                    $display("L1 MISMATCH idx%0d img%0d ch%0d pix%0d: got=%04x exp=%04x",
                             i, i/(OC1*NPIX), (i%(OC1*NPIX))/NPIX, i%NPIX, cap_L1[i], gold_L1[i]);
                errL1 = errL1 + 1;
            end

        errL2 = 0;
        for (i = 0; i < NIMG*OC2*NPIX; i = i + 1)
            if (cap_L2[i] !== gold_L2[i]) begin
                if (errL2 < 10)
                    $display("L2 MISMATCH idx%0d img%0d oc%0d pix%0d: got=%04x exp=%04x",
                             i, i/(OC2*NPIX), (i%(OC2*NPIX))/NPIX, i%NPIX, cap_L2[i], gold_L2[i]);
                errL2 = errL2 + 1;
            end

        errOut = 0;
        for (i = 0; i < NIMG*NPIX; i = i + 1)
            if (cap_out[i] !== gold_out[i]) begin
                if (errOut < 10)
                    $display("OUT MISMATCH idx%0d img%0d pix%0d: got=%04x exp=%04x",
                             i, i/NPIX, i%NPIX, cap_out[i], gold_out[i]);
                errOut = errOut + 1;
            end

        $display("");
        $display("=== L1  : %0d / %0d errors", errL1, NIMG*OC1*NPIX);
        $display("=== L2  : %0d / %0d errors", errL2, NIMG*OC2*NPIX);
        $display("=== OUT : %0d / %0d errors", errOut, NIMG*NPIX);
        if (errL1==0 && errL2==0 && errOut==0) $display("ALL PASS");
        else                                   $display("ALL FAIL");
        $finish;
    end

    initial begin
        #10000000000;
        $display("TIMEOUT layer=%0d img=%0d capL1=%0d capOut=%0d all_done=%b",
                 dut.w_layer_cnt, dut.w_img_cnt, cap_L1_idx, cap_out_idx, all_done);
        $finish;
    end
endmodule
