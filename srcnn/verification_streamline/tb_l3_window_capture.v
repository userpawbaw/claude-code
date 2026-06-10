`timescale 1ns / 1ps
// Capture LB window data when first L3 output pixel is produced
module tb_l3_window_capture;
    reg clk=0, rstn=0, start=0;
    wire pixel_valid; wire [15:0] pixel_data; wire image_bit, system_done;

    streamline_top #(.MEM_ADDR(15),.N_IMG(1),
        .L1_IMG_INIT("input_real_1img.txt"),
        .L1_W_INIT("weight_l1_real.txt"),
        .L2_W_INIT("weight_l2_real.txt"),
        .L3_W_INIT("weight_l3_real.txt")
    ) dut (.i_clk(clk),.i_rstn(rstn),.i_system_start(start),
           .o_pixel_valid(pixel_valid),.o_pixel_data(pixel_data),
           .o_image_bit(image_bit),.o_system_done(system_done));

    always #5 clk=~clk;

    integer cap_idx;
    integer i;
    reg captured_first;

    // Capture window data for each L3 channel at first w_line_valid
    always @(posedge clk) begin
        if (!rstn) begin
            cap_idx <= 0;
            captured_first <= 0;
        end else begin
            // Capture at LINE_VALID (1 cycle ahead of PE seeing data, so PE will see CURRENT window)
            if (dut.u_l3.u_pu.w_line_valid[0] && cap_idx < 5) begin
                $display("=== Output pixel %0d (LV time) ===", cap_idx);
                $display("  Channel 0 window=%036x", dut.u_l3.u_pu.w_line_data[0]);
                $display("  Channel 1 window=%036x", dut.u_l3.u_pu.w_line_data[1]);
                $display("  Channel 2 window=%036x", dut.u_l3.u_pu.w_line_data[2]);
                $display("  Channel 3 window=%036x", dut.u_l3.u_pu.w_line_data[3]);
                cap_idx <= cap_idx + 1;
            end
        end
    end

    initial begin
        rstn=0;start=0;repeat(4)@(posedge clk);rstn=1;@(posedge clk);
        start=1;@(posedge clk);start=0;
        #5_000_000;
        $display("END cap_idx=%0d", cap_idx);
        $finish;
    end

    initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
