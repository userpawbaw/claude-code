`timescale 1ns / 1ps
module tb_l3_debug2;
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

    // Monitor valid output cycles and internal state
    integer pix_cnt;
    initial pix_cnt = 0;
    
    always @(posedge clk) begin
        if (pixel_valid && pix_cnt < 5) begin
            $display("PIX[%0d] t=%0t data=%04X(%0d)  r_add_stage2=%0d  r_bias=%0d  w_partial=[%0d,%0d,%0d,%0d]",
                     pix_cnt, $time, pixel_data, $signed(pixel_data),
                     $signed(dut.u_l3.u_pu.r_add_stage2),
                     $signed(dut.u_l3.u_pu.r_bias),
                     $signed(dut.u_l3.u_pu.w_partial[0]),
                     $signed(dut.u_l3.u_pu.w_partial[1]),
                     $signed(dut.u_l3.u_pu.w_partial[2]),
                     $signed(dut.u_l3.u_pu.w_partial[3])
            );
            pix_cnt = pix_cnt + 1;
        end
    end
    
    // Also monitor the pe_group partials for channel 0 a few cycles before pixel output
    // (pixel output lags pe_group valid by 2 cycles)
    integer dbg_cnt;
    initial dbg_cnt = 0;
    wire pe_valid_ch0;
    assign pe_valid_ch0 = dut.u_l3.u_pu.w_pe_valid[0];
    
    always @(posedge clk) begin
        if (pe_valid_ch0 && dbg_cnt < 10) begin
            $display("PE_VALID[%0d] t=%0t  partials=[%0d, %0d, %0d, %0d]",
                     dbg_cnt, $time,
                     $signed(dut.u_l3.u_pu.w_partial[0]),
                     $signed(dut.u_l3.u_pu.w_partial[1]),
                     $signed(dut.u_l3.u_pu.w_partial[2]),
                     $signed(dut.u_l3.u_pu.w_partial[3])
            );
            dbg_cnt = dbg_cnt + 1;
        end
    end

    initial begin
        rstn=0;start=0;repeat(4)@(posedge clk);rstn=1;@(posedge clk);
        start=1;@(posedge clk);start=0;
        wait(system_done); repeat(100)@(posedge clk);
        $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
