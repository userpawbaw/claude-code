`timescale 1ns / 1ps
// =============================================================================
// tb_streamline_real.v  — real-weight test for streamline_top
//   Uses actual L1/L2/L3 weight files + 1 image input.
//   Compares RTL output stream against golden_output.txt (from golden_srcnn.py).
// =============================================================================

module tb_streamline_real;
    reg  clk   = 0;
    reg  rstn  = 0;
    reg  start = 0;

    wire        pixel_valid;
    wire [15:0] pixel_data;
    wire        image_bit;
    wire        system_done;

    streamline_top #(
        .MEM_ADDR   (15),
        .N_IMG      (1),
        .L1_IMG_INIT("input_real_1img.txt"),
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

    // ---------- Capture output ----------
    localparam NPIX = 150 * 150;
    reg [15:0] captured [0:NPIX-1];
    integer    cap_idx;

    always @(posedge clk) begin
        if (!rstn) begin
            cap_idx <= 0;
        end else if (pixel_valid && cap_idx < NPIX) begin
            captured[cap_idx] <= pixel_data;
            cap_idx            <= cap_idx + 1;
        end
    end

    // ---------- Load golden reference ----------
    reg [15:0] golden [0:NPIX-1];
    initial $readmemh("golden_output.txt", golden);

    // ---------- Stimulus + Check ----------
    integer i, errors;

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

        // Dump RTL output to file
        begin : dump_block
            integer fd;
            fd = $fopen("rtl_output.txt", "w");
            for (i = 0; i < NPIX; i = i + 1)
                $fwrite(fd, "%04X\n", captured[i]);
            $fclose(fd);
        end

        errors = 0;
        for (i = 0; i < NPIX; i = i + 1) begin
            if (captured[i] !== golden[i]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH pix=%0d  rtl=%04x  golden=%04x",
                             i, captured[i], golden[i]);
            end
        end

        $display("=== real-weight check: %0d pixels, %0d errors ===", cap_idx, errors);
        if (errors == 0 && cap_idx == NPIX)
            $display("streamline_top PASS (real weights)");
        else
            $display("streamline_top FAIL (cap=%0d, errors=%0d)", cap_idx, errors);
        $finish;
    end

    // ---------- Timeout 20ms ----------
    initial begin
        #20_000_000;
        $display("TIMEOUT (cap_idx=%0d, system_done=%b)", cap_idx, system_done);
        $finish;
    end
endmodule
