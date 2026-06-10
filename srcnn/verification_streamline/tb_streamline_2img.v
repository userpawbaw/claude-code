`timescale 1ns / 1ps
// 2-image real-weight test for streamline_top
module tb_streamline_2img;
    reg  clk   = 0;
    reg  rstn  = 0;
    reg  start = 0;

    wire        pixel_valid;
    wire [15:0] pixel_data;
    wire        image_bit;
    wire        system_done;

    streamline_top #(
        .MEM_ADDR   (15),
        .N_IMG      (2),
        .L1_IMG_INIT("input_real_2img.txt"),
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

    localparam NPIX_1 = 150 * 150;
    localparam NPIX_TOT = NPIX_1 * 2;
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

    reg [15:0] golden [0:NPIX_TOT-1];
    initial $readmemh("golden_2img.txt", golden);

    integer i, errors, errors_img0, errors_img1, bit_flip_idx;

    initial begin
        rstn  = 0;
        start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        $display("[t=%0t] start asserted", $time);

        wait (system_done);
        $display("[t=%0t] system_done (cap_idx=%0d)", $time, cap_idx);
        repeat(100) @(posedge clk);

        errors      = 0;
        errors_img0 = 0;
        errors_img1 = 0;
        bit_flip_idx = -1;

        for (i = 0; i < NPIX_TOT; i = i + 1) begin
            if (captured[i] !== golden[i]) begin
                errors = errors + 1;
                if (i < NPIX_1) errors_img0 = errors_img0 + 1;
                else            errors_img1 = errors_img1 + 1;
                if (errors <= 10)
                    $display("MISMATCH pix=%0d (img=%0d) rtl=%04x golden=%04x bit=%b",
                             i, (i < NPIX_1) ? 0 : 1, captured[i], golden[i], captured_bit[i]);
            end
            if (i > 0 && captured_bit[i] !== captured_bit[i-1] && bit_flip_idx < 0)
                bit_flip_idx = i;
        end

        $display("=== 2-image check: %0d pixels, %0d errors (img0=%0d img1=%0d) ===",
                 cap_idx, errors, errors_img0, errors_img1);
        $display("image_bit first flip at pix=%0d (expected %0d)", bit_flip_idx, NPIX_1);
        if (errors == 0 && cap_idx == NPIX_TOT)
            $display("streamline_top 2-img PASS");
        else
            $display("streamline_top 2-img FAIL");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT (cap_idx=%0d, system_done=%b)", cap_idx, system_done);
        $finish;
    end
endmodule
