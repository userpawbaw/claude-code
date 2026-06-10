`timescale 1ns / 1ps
// Diagnose L3 line buffer valid rate
module tb_l3_timing;
    reg clk=0, rstn=0, start=0;
    wire done;
    wire [3:0]      l2_rd_en;
    wire [4*16-1:0] l2_rd_addr_packed;
    wire [4*16-1:0] l2_rd_dout_packed;
    wire [3:0]      l2_rd_valid;
    wire pixel_valid; wire [15:0] pixel_data;

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

    // Count total clock cycles per state
    integer cnt_idle, cnt_wread, cnt_istream, cnt_done, tot_clk;
    wire w_lb_valid_ch0 = dut.u_pu.gen_ch[0].w_lb_valid;

    always @(posedge clk) begin
        if (!rstn) begin
            cnt_idle<=0; cnt_wread<=0; cnt_istream<=0; cnt_done<=0; tot_clk<=0;
        end else begin
            tot_clk <= tot_clk + 1;
            case(dut.u_fsm.r_ps)
                2'd0: cnt_idle    <= cnt_idle+1;
                2'd1: cnt_wread   <= cnt_wread+1;
                2'd2: cnt_istream <= cnt_istream+1;
                2'd3: cnt_done    <= cnt_done+1;
            endcase
            if (tot_clk % 10000 == 9999)
                $display("[t=%0t] tot=%0d IDLE=%0d WREAD=%0d ISTREAM=%0d DONE=%0d LBrow=%0d LBcol=%0d adder_done=%b",
                    $time, tot_clk,
                    cnt_idle, cnt_wread, cnt_istream, cnt_done,
                    dut.u_pu.gen_ch[0].u_line_buffer.r_row,
                    dut.u_pu.gen_ch[0].u_line_buffer.r_col,
                    dut.u_fsm.i_adder_done);
        end
    end

    initial begin
        rstn=0; start=0;
        repeat(4) @(posedge clk); rstn=1; @(posedge clk);
        start=1; @(posedge clk); start=0;
        repeat(50000) @(posedge clk);
        $display("FINAL: tot=%0d IDLE=%0d WREAD=%0d ISTREAM=%0d DONE=%0d LBrow=%0d LBcol=%0d",
            tot_clk, cnt_idle, cnt_wread, cnt_istream, cnt_done,
            dut.u_pu.gen_ch[0].u_line_buffer.r_row,
            dut.u_pu.gen_ch[0].u_line_buffer.r_col);
        $finish;
    end
endmodule
