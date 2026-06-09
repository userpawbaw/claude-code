`timescale 1ns / 1ps
module tb_l3_debug;
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
    localparam NPIX=22500;
    reg [15:0] captured[0:NPIX-1]; integer cap_idx;
    always @(posedge clk) begin
        if(!rstn) cap_idx<=0;
        else if(pixel_valid&&cap_idx<NPIX) begin captured[cap_idx]<=pixel_data; cap_idx<=cap_idx+1; end
    end
    integer i, fd;
    initial begin
        rstn=0;start=0;repeat(4)@(posedge clk);rstn=1;@(posedge clk);
        start=1;@(posedge clk);start=0;
        wait(system_done); repeat(100)@(posedge clk);
        // Print first 5 pixel outputs
        $display("=== L3 output pixel 0..4 ===");
        for(i=0;i<5;i=i+1) $display("  pix[%0d] = %04X (%0d)", i, captured[i], captured[i]);
        // Dump intermediate values from L3_PU via hierarchy 
        $display("=== L3_PU internal state (last captured) ===");
        $display("  r_add_stage2 = %0d", $signed(dut.u_l3.u_pu.r_add_stage2));
        $display("  r_bias = %0d", $signed(dut.u_l3.u_pu.r_bias));
        fd=$fopen("rtl_debug.txt","w");
        for(i=0;i<NPIX;i=i+1) $fwrite(fd,"%04X\n",captured[i]);
        $fclose(fd);
        $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
