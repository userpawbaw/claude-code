`timescale 1ns / 1ps
// Minimal L3 debug: trace FSM state, img_done, adder_done
module tb_l3_fsm_debug;
    reg clk=0, rstn=0, start=0;
    wire done;
    wire [3:0]      l2_rd_en;
    wire [4*16-1:0] l2_rd_addr_packed;
    wire [4*16-1:0] l2_rd_dout_packed;
    wire [3:0]      l2_rd_valid;
    wire            pixel_valid;
    wire [15:0]     pixel_data;

    L3_top #(.MEM_ADDR(15),.WEIGHT_INIT("weight_l3_id.txt")) dut (
        .i_clk(clk),.i_rstn(rstn),.i_start(start),.i_image_bit(1'b0),
        .o_l2_rd_en(l2_rd_en),.o_l2_rd_addr_packed(l2_rd_addr_packed),
        .i_l2_rd_dout_packed(l2_rd_dout_packed),.i_l2_rd_valid(l2_rd_valid),
        .o_pixel_valid(pixel_valid),.o_pixel_data(pixel_data),.o_done(done));

    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch0.txt")) u0 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[0]),.rd_addr(l2_rd_addr_packed[0+:16]),.rd_valid(l2_rd_valid[0]),.rd_dout(l2_rd_dout_packed[0+:16]));
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch1.txt")) u1 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[1]),.rd_addr(l2_rd_addr_packed[16+:16]),.rd_valid(l2_rd_valid[1]),.rd_dout(l2_rd_dout_packed[16+:16]));
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch2.txt")) u2 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[2]),.rd_addr(l2_rd_addr_packed[32+:16]),.rd_valid(l2_rd_valid[2]),.rd_dout(l2_rd_dout_packed[32+:16]));
    simple_dual_port_uram #(.WIDTH(16),.DEPTH(45000),.INIT_FILE("intermid2_3_init_ch3.txt")) u3 (
        .clk(clk),.wr_en(1'b0),.wr_addr(16'd0),.wr_din(16'd0),
        .rd_en(l2_rd_en[3]),.rd_addr(l2_rd_addr_packed[48+:16]),.rd_valid(l2_rd_valid[3]),.rd_dout(l2_rd_dout_packed[48+:16]));

    always #5 clk = ~clk;

    // Monitor FSM state changes
    reg [1:0] prev_state;
    always @(posedge clk) begin
        if (rstn) begin
            if (dut.u_fsm.r_ps !== prev_state) begin
                $display("[t=%0t] FSM state: %0d -> %0d", $time, prev_state, dut.u_fsm.r_ps);
                prev_state <= dut.u_fsm.r_ps;
            end
        end else begin
            prev_state <= 0;
        end
    end

    // Monitor img_done chain
    always @(posedge clk) begin
        if (rstn) begin
            if (dut.u_pu.w_img_done)
                $display("[t=%0t] w_img_done HIGH (line_buffer)", $time);
            if (dut.u_pu.o_img_done)
                $display("[t=%0t] o_img_done HIGH (L3_PU out)", $time);
            if (dut.u_fsm.i_adder_done)
                $display("[t=%0t] i_adder_done HIGH", $time);
            if (dut.u_fsm.o_done)
                $display("[t=%0t] o_done HIGH", $time);
        end
    end

    // Print pixel count every 5000 pixels
    integer cap_idx;
    always @(posedge clk) begin
        if (!rstn) cap_idx <= 0;
        else if (pixel_valid) begin
            cap_idx <= cap_idx + 1;
            if (cap_idx % 5000 == 0)
                $display("[t=%0t] cap_idx=%0d", $time, cap_idx);
        end
    end

    integer lb_row;
    // Also monitor line buffer row counter
    always @(posedge clk) begin
        if (rstn) begin
            lb_row = dut.u_pu.gen_ch[0].u_line_buffer.r_row;
            if (lb_row == 150 || lb_row == 151 || lb_row == 152)
                $display("[t=%0t] LB r_row=%0d", $time, lb_row);
        end
    end

    initial begin
        rstn=0; start=0;
        repeat(4) @(posedge clk); rstn=1; @(posedge clk);
        start=1; @(posedge clk); start=0;
        $display("[t=%0t] start asserted", $time);

        #30_000_000;  // 30ms timeout
        $display("TIMEOUT (done=%b, cap=%0d)", done, cap_idx);
        $finish;
    end

    // Complete when done
    always @(posedge clk) begin
        if (done) begin
            $display("[t=%0t] DONE fired! cap=%0d", $time, cap_idx);
            repeat(5) @(posedge clk);
            $finish;
        end
    end
endmodule
