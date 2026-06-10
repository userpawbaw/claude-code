`timescale 1ns / 1ps
// Trace every LB input pulse and FSM state for first ~10 pulses
module tb_l3_pulse_trace;
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

    integer pulse_cnt;
    integer trace_after_l3_start;

    wire l3_lb_valid = dut.u_l3.u_pu.gen_ch[0].w_lb_valid;
    wire l3_lb_pad = dut.u_l3.u_pu.gen_ch[0].w_lb_data == 0 && dut.u_l3.u_pu.i_is_pad_valid;
    wire [15:0] l3_lb_data_ch0 = dut.u_l3.u_pu.gen_ch[0].w_lb_data;
    wire [15:0] l3_lb_data_ch1 = dut.u_l3.u_pu.gen_ch[1].w_lb_data;

    always @(posedge clk) begin
        if (!rstn) begin
            pulse_cnt <= 0;
            trace_after_l3_start <= 0;
        end else begin
            // Activate trace once L3 FSM enters S_I_STREAM
            if (dut.u_l3.u_fsm.r_ps == 2'd2 && !trace_after_l3_start) begin
                trace_after_l3_start <= 1;
                $display("[t=%0t] L3 FSM entered S_I_STREAM", $time);
            end
            if (l3_lb_valid && pulse_cnt < 320) begin
                if (pulse_cnt < 10 || pulse_cnt == 151 || pulse_cnt == 152 || pulse_cnt == 153 || pulse_cnt == 154 || pulse_cnt == 155 || pulse_cnt == 156 || pulse_cnt >= 300) begin
                    $display("[t=%0t] LB pulse %0d: is_pad_valid=%b inp_valid=%b ch0_data=%04x ch1_data=%04x FSM(row=%0d col=%0d ps=%0d)",
                        $time, pulse_cnt+1,
                        dut.u_l3.u_pu.i_is_pad_valid,
                        dut.u_l3.u_pu.i_input_valid,
                        l3_lb_data_ch0, l3_lb_data_ch1,
                        dut.u_l3.u_fsm.r_pad_row,
                        dut.u_l3.u_fsm.r_pad_col,
                        dut.u_l3.u_fsm.r_ps);
                end
                pulse_cnt <= pulse_cnt + 1;
            end
            if (dut.u_l3.u_pu.w_line_valid[0] && pulse_cnt > 300) begin
                $display("[t=%0t] *** FIRST line_valid! pulse_cnt=%0d ***", $time, pulse_cnt);
            end
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
