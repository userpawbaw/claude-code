`timescale 1ns / 1ps
// Trace PE 0 for channel 1 at first window
module tb_l3_pe_trace;
    reg clk=0, rstn=0, start=0;
    wire pixel_valid; wire [15:0] pixel_data;

    streamline_top #(.MEM_ADDR(15),.N_IMG(1),
        .L1_IMG_INIT("input_real_1img.txt"),
        .L1_W_INIT("weight_l1_real.txt"),
        .L2_W_INIT("weight_l2_real.txt"),
        .L3_W_INIT("weight_l3_real.txt")
    ) dut (.i_clk(clk),.i_rstn(rstn),.i_system_start(start),
           .o_pixel_valid(pixel_valid),.o_pixel_data(pixel_data),
           .o_image_bit(),.o_system_done());

    always #5 clk=~clk;

    integer trace_cnt;

    always @(posedge clk) begin
        if (!rstn) trace_cnt <= 0;
        else if (dut.u_l3.u_pu.w_line_valid[0] && trace_cnt < 5) begin
            $display("[t=%0t] LineValid! ch1 PE0: en_i=%b en_w=%b r_weight=%0d (0x%04x) i_input=%0d (0x%04x) w_output=%0d o_valid=%b o_output=%0d",
                $time,
                dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.i_en_i,
                dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.i_en_w,
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.r_weight),
                dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.r_weight,
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.i_input),
                dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.i_input,
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.w_output),
                dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.o_valid,
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.gen_PE[0].pe.o_output));
            $display("           Stage1[0]=%0d Stage1[1]=%0d Stage1[2]=%0d o_partial=%0d",
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.r_add_stage1[0]),
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.r_add_stage1[1]),
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.r_add_stage1[2]),
                $signed(dut.u_l3.u_pu.gen_ch[1].pe_inst.o_partial));
            trace_cnt <= trace_cnt + 1;
        end
    end

    initial begin
        rstn=0;start=0;repeat(4)@(posedge clk);rstn=1;@(posedge clk);
        start=1;@(posedge clk);start=0;
        #5_000_000;
        $finish;
    end

    initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
