`timescale 1ns / 1ps

// L3 top (streamline)
//  - L3 weight BRAM (64-bit x 10): 9 weight + 1 bias word, 1 set (out_ch=1)
//  - L3_local_FSM + L3_PU
//  - intermid2_3 URAM R-port 드라이브 (L2_top 내 4개 URAM 동시 읽기)
//  - URAM/output addr 없음. final pixel 16bit + valid 그대로 노출.

module L3_top #(
    parameter MEM_ADDR    = 15,
    parameter WEIGHT_INIT = "weight_l3.txt"
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_start,
    input  wire                          i_image_bit,    // global FSM에서 주입

    // Drives intermid2_3 URAM R-ports at L2_top (동일 addr/en을 4 ch에 broadcast)
    output wire [3:0]                    o_l2_rd_en,
    output wire [4*(MEM_ADDR+1)-1:0]     o_l2_rd_addr_packed,
    input  wire [4*16-1:0]               i_l2_rd_dout_packed,
    input  wire [3:0]                    i_l2_rd_valid,

    // Final pixel output (외부 후처리로 직접 흘려보냄)
    output wire                          o_pixel_valid,
    output wire [15:0]                   o_pixel_data,

    output wire                          o_done
);

    // ====== Internal wires ======
    wire                  w_w_rd_en;
    wire [MEM_ADDR-1:0]   w_w_rd_addr;
    wire                  w_w_rd_valid;
    wire [63:0]           w_w_rd_dout;
    wire                  w_bias_en;

    wire                  w_uram_rd_en;
    wire [MEM_ADDR-1:0]   w_uram_rd_addr;

    wire                  w_IDLE_rst;
    wire                  w_is_pad_valid;
    wire                  w_done;

    wire                  w_pixel_valid;
    wire [15:0]           w_pixel_data;
    wire                  w_line_rd_done;
    wire                  w_pe_done;
    wire                  w_img_done;

    // ====== L3_local_FSM ======
    L3_local_FSM #(
        .MEM_ADDR_WIDTH(MEM_ADDR)
    ) u_fsm (
        .i_clk                 (i_clk),
        .i_rstn                (i_rstn),
        .i_start               (i_start),
        .i_adder_done          (w_img_done),     // drain-aligned

        .o_weight_bram_rd_en   (w_w_rd_en),
        .o_weight_bram_rd_addr (w_w_rd_addr),
        .o_bias_en             (w_bias_en),

        .o_input_bram_rd_en    (w_uram_rd_en),
        .o_input_bram_rd_addr  (w_uram_rd_addr),

        .o_is_pad              (),
        .o_is_pad_valid        (w_is_pad_valid),

        .o_IDLE_rst            (w_IDLE_rst),
        .o_done                (w_done)
    );

    // ====== L3 Weight BRAM (64-bit x 10) ======
    simple_dual_port_bram #(
        .WIDTH(64),
        .DEPTH(10),
        .INIT_FILE(WEIGHT_INIT)
    ) u_l3_w_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .wr_din   (64'h0),
        .rd_en    (w_w_rd_en),
        .rd_addr  (w_w_rd_addr),
        .rd_valid (w_w_rd_valid),
        .rd_dout  (w_w_rd_dout)
    );

    // ====== intermid2_3 URAM R-port forwarding ======
    // 4 ch 모두 동일 addr / en 으로 broadcast.
    // addr = {image_bit, FSM의 pixel_addr}
    wire [MEM_ADDR:0] w_full_rd_addr = {i_image_bit, w_uram_rd_addr};
    assign o_l2_rd_en          = {4{w_uram_rd_en}};
    assign o_l2_rd_addr_packed = {w_full_rd_addr, w_full_rd_addr, w_full_rd_addr, w_full_rd_addr};

    // i_l2_rd_dout_packed[63:0] = {ch3, ch2, ch1, ch0} (LSB=ch0)
    // valid 동아안 하나만 쓰면 됨 (4개 동일)
    wire [15:0] w_ch [0:3];
    assign w_ch[0] = i_l2_rd_dout_packed[0  +: 16];
    assign w_ch[1] = i_l2_rd_dout_packed[16 +: 16];
    assign w_ch[2] = i_l2_rd_dout_packed[32 +: 16];
    assign w_ch[3] = i_l2_rd_dout_packed[48 +: 16];

    wire [63:0] w_pu_input_data  = {w_ch[3], w_ch[2], w_ch[1], w_ch[0]}; // 동일 컨벤션
    wire        w_pu_input_valid = i_l2_rd_valid[0]; // 4ch 동기이므로 [0]만 참조

    // ====== L3_PU ======
    L3_PU u_pu (
        .i_clk              (i_clk),
        .i_rstn             (i_rstn),
        .i_IDLE_rst         (w_IDLE_rst),

        .i_input_valid      (w_pu_input_valid),
        .i_uram_data        (w_pu_input_data),
        .i_is_pad_valid     (w_is_pad_valid),

        .i_w_rd_en          (w_w_rd_valid),
        .i_weight_bram_data (w_w_rd_dout),
        .i_bias_en          (w_bias_en),

        .o_line_rd_done     (w_line_rd_done),
        .o_pe_done          (w_pe_done),

        .o_pixel_valid      (w_pixel_valid),
        .o_pixel_data       (w_pixel_data),
        .o_img_done         (w_img_done)
    );

    assign o_pixel_valid = w_pixel_valid;
    assign o_pixel_data  = w_pixel_data;
    assign o_done        = w_done;

endmodule
