`timescale 1ns / 1ps
// =============================================================================
// tb_streamline_top.v  — end-to-end identity test for streamline_top
//
// Test setup (identity chain, output = input):
//   L1: center_tap=256 (Q8.8=1.0)  → L1_out = input
//   L2: center_tap=32               → sum = 8*32*i = 256i; >>>8 = i
//   L3: center_tap=64               → sum = 4*64*i = 256i; >>>8 = i
// Input: ramp 0..22499
// Expected output stream: pixel[i] = i  (22500 pixels, 1 image)
// =============================================================================

module tb_streamline_top;
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
        .L1_IMG_INIT("input_st.txt"),
        .L1_W_INIT  ("weight_l1_st.txt"),
        .L2_W_INIT  ("weight_l2_st.txt"),
        .L3_W_INIT  ("weight_l3_st.txt")
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

    // ---------- Capture output pixel stream ----------
    localparam NPIX = 150 * 150;  // 22500
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

    // ---------- Progress log every 100k cycles ----------
    integer cycle_cnt;
    always @(posedge clk) begin
        if (!rstn) cycle_cnt <= 0;
        else       cycle_cnt <= cycle_cnt + 1;
    end

    // ---------- Stimulus + Check ----------
    integer i, errors;
    reg [15:0] expected;

    initial begin
        rstn  = 0;
        start = 0;
        repeat(4) @(posedge clk);
        rstn = 1;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        $display("[t=%0t] start asserted", $time);

        // Wait for system_done + extra pipeline drain
        wait (system_done);
        $display("[t=%0t] system_done asserted (cap_idx=%0d)", $time, cap_idx);
        repeat(100) @(posedge clk);

        // Check
        errors = 0;
        for (i = 0; i < NPIX; i = i + 1) begin
            expected = i[14:0];  // ramp passthrough: output = input index
            if (captured[i] !== expected) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("MISMATCH pix=%0d: got=%04x exp=%04x",
                             i, captured[i], expected);
            end
        end

        $display("=== streamline_top check: %0d pixels, %0d errors ===",
                 cap_idx, errors);
        if (errors == 0 && cap_idx == NPIX)
            $display("streamline_top PASS");
        else
            $display("streamline_top FAIL (cap=%0d expected=%0d)", cap_idx, NPIX);
        $finish;
    end

    // ---------- Timeout 20ms ----------
    initial begin
        #20_000_000;
        $display("TIMEOUT (cycle=%0d, cap_idx=%0d, system_done=%b)",
                 cycle_cnt, cap_idx, system_done);
        $finish;
    end
endmodule
