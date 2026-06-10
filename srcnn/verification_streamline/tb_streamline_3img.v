`timescale 1ns / 1ps
// 3-image continuous real-weight test for streamline_top.
//
// Faithful streaming emulation: streamline_top's L1 image BRAM is read-only and
// only holds ONE image. To feed 3 DIFFERENT images through a single continuous
// pipelined run (and thereby exercise inter-image state retention), we reload the
// L1 image BRAM with the next image's pixels at each L1 image-done boundary via a
// hierarchical $readmemh. This mimics a real per-image input stream WITHOUT
// modifying the synthesizable RTL.
module tb_streamline_3img;
    reg  clk   = 0;
    reg  rstn  = 0;
    reg  start = 0;

    wire        pixel_valid;
    wire [15:0] pixel_data;
    wire        image_bit;
    wire        system_done;

    streamline_top #(
        .MEM_ADDR   (15),
        .N_IMG      (3),
        .L1_IMG_INIT("img_block0.txt"),   // image 0 preloaded
        .L1_W_INIT  ("weight_l1_real.txt"),
        .L2_W_INIT  ("weight_l2_real.txt"),
        .L3_W_INIT  ("weight_l3_real.txt")
    ) dut (
        .i_clk         (clk),
        .i_rstn        (rstn),
        .i_system_start(start),
        .o_pixel_valid (pixel_valid),
        .o_pixel_data  (pixel_data),
        .o_image_bit   (image_bit),
        .o_system_done (system_done)
    );

    always #5 clk = ~clk;

    localparam NPIX_1   = 150 * 150;
    localparam NPIX_TOT = NPIX_1 * 3;

    reg [15:0] captured [0:NPIX_TOT-1];
    reg        captured_bit [0:NPIX_TOT-1];
    integer    cap_idx;

    always @(posedge clk) begin
        if (!rstn) begin
            cap_idx <= 0;
        end else if (pixel_valid && cap_idx < NPIX_TOT) begin
            captured[cap_idx]     <= pixel_data;
            captured_bit[cap_idx] <= image_bit;
            cap_idx               <= cap_idx + 1;
        end
    end

    // ---- per-image L1 BRAM reload (input streaming emulation) ----
    // dut.w_l1_done is a 1-clk pulse when L1 finishes reading an image.
    // After image0 done -> load image1; after image1 done -> load image2.
    integer l1_done_cnt;
    reg     prev_l1_done;
    always @(posedge clk) begin
        if (!rstn) begin
            l1_done_cnt  <= 0;
            prev_l1_done <= 1'b0;
        end else begin
            prev_l1_done <= dut.w_l1_done;
            if (dut.w_l1_done && !prev_l1_done) begin
                l1_done_cnt <= l1_done_cnt + 1;
                if (l1_done_cnt == 0) begin
                    $readmemh("img_block1.txt", dut.u_l1.u_l1_img_bram.mem);
                    $display("[t=%0t] L1 reload -> img_block1 (after image0 read)", $time);
                end else if (l1_done_cnt == 1) begin
                    $readmemh("img_block2.txt", dut.u_l1.u_l1_img_bram.mem);
                    $display("[t=%0t] L1 reload -> img_block2 (after image1 read)", $time);
                end
            end
        end
    end

    reg [15:0] golden [0:NPIX_TOT-1];
    initial $readmemh("golden_3img.txt", golden);

    integer i, errors, e0, e1, e2, shown;

    initial begin
        rstn  = 0; start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        $display("[t=%0t] start asserted", $time);

        wait (system_done);
        $display("[t=%0t] system_done (cap_idx=%0d)", $time, cap_idx);
        repeat(100) @(posedge clk);

        errors=0; e0=0; e1=0; e2=0; shown=0;
        for (i = 0; i < NPIX_TOT; i = i + 1) begin
            if (captured[i] !== golden[i]) begin
                errors = errors + 1;
                if      (i < NPIX_1)   e0 = e0 + 1;
                else if (i < 2*NPIX_1) e1 = e1 + 1;
                else                   e2 = e2 + 1;
                if (shown < 12) begin
                    $display("MISMATCH pix=%0d (img=%0d) rtl=%04x golden=%04x",
                             i, i/NPIX_1, captured[i], golden[i]);
                    shown = shown + 1;
                end
            end
        end
        $display("=== 3-image check: %0d px, %0d errors (img0=%0d img1=%0d img2=%0d) ===",
                 cap_idx, errors, e0, e1, e2);
        if (errors == 0 && cap_idx == NPIX_TOT)
            $display("streamline_top 3-img PASS");
        else
            $display("streamline_top 3-img FAIL");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("TIMEOUT (cap_idx=%0d, system_done=%b)", cap_idx, system_done);
        $finish;
    end
endmodule
