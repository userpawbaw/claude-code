`timescale 1ns / 1ps

// streamline_top
//  - global_FSM + L1_top + L2_top + L3_top 와이어 연결
//  - global FSM이 image_cnt + start 발사용 제어, 각 layer top은 PU/FSM/BRAM/URAM을 그대로 돌림
//  - L1->L2 URAM(intermid1_2): L1_top 안에 포함, R포트는 L2_top이 드라이브
//  - L2->L3 URAM(intermid2_3, 4개): L2_top 안에 포함, R포트들은 L3_top이 드라이브
//  - L3 출력 16bit + valid + 대응되는 image_bit 그대로 노출 (외부 후처리로 전달)

module streamline_top #(
    parameter MEM_ADDR    = 15,
    parameter N_IMG       = 3,
    parameter L1_IMG_INIT = "image_l1.txt",
    parameter L1_W_INIT   = "weight_l1.txt",
    parameter L2_W_INIT   = "weight_l2.txt",
    parameter L3_W_INIT   = "weight_l3.txt"
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_system_start,

    // L3 final output (외부 후처리로)
    output wire                          o_pixel_valid,
    output wire [15:0]                   o_pixel_data,
    output wire                          o_image_bit,    // L3가 현재 처리중인 이미지 LSB

    output wire                          o_system_done
);

    // ====== Global FSM <-> Layer tops ======
    wire        w_l1_start, w_l2_start, w_l3_start;
    wire        w_l1_done,  w_l2_done,  w_l3_done;
    wire        w_l1_imgbit, w_l2_imgbit, w_l3_imgbit;

    global_FSM #(
        .N_IMG(N_IMG)
    ) u_global (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_system_start(i_system_start),

        .i_l1_done     (w_l1_done),
        .i_l2_done     (w_l2_done),
        .i_l3_done     (w_l3_done),

        .o_l1_start    (w_l1_start),
        .o_l2_start    (w_l2_start),
        .o_l3_start    (w_l3_start),

        .o_l1_image_bit(w_l1_imgbit),
        .o_l2_image_bit(w_l2_imgbit),
        .o_l3_image_bit(w_l3_imgbit),

        .o_system_done (o_system_done)
    );

    // ====== intermid1_2 (L1_top owns W-port, L2_top drives R-port) ======
    wire                  w_l1_rdport_en;
    wire [MEM_ADDR:0]     w_l1_rdport_addr;
    wire [127:0]          w_l1_rdport_dout;
    wire                  w_l1_rdport_valid;

    // ====== intermid2_3 (L2_top owns W-port x 4, L3_top drives R-port x 4) ======
    wire [3:0]                    w_l2_rdport_en;
    wire [4*(MEM_ADDR+1)-1:0]     w_l2_rdport_addr_packed;
    wire [4*16-1:0]               w_l2_rdport_dout_packed;
    wire [3:0]                    w_l2_rdport_valid;

    // ====== L1_top ======
    L1_top #(
        .MEM_ADDR   (MEM_ADDR),
        .IMG_INIT   (L1_IMG_INIT),
        .WEIGHT_INIT(L1_W_INIT)
    ) u_l1 (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_start       (w_l1_start),
        .i_image_bit   (w_l1_imgbit),

        .i_l2_rd_en    (w_l1_rdport_en),
        .i_l2_rd_addr  (w_l1_rdport_addr),
        .o_l2_rd_dout  (w_l1_rdport_dout),
        .o_l2_rd_valid (w_l1_rdport_valid),

        .o_done        (w_l1_done)
    );

    // ====== L2_top ======
    L2_top #(
        .MEM_ADDR   (MEM_ADDR),
        .WEIGHT_INIT(L2_W_INIT)
    ) u_l2 (
        .i_clk                (i_clk),
        .i_rstn               (i_rstn),
        .i_start              (w_l2_start),
        .i_image_bit          (w_l2_imgbit),

        .o_l1_rd_en           (w_l1_rdport_en),
        .o_l1_rd_addr         (w_l1_rdport_addr),
        .i_l1_rd_dout         (w_l1_rdport_dout),
        .i_l1_rd_valid        (w_l1_rdport_valid),

        .i_l3_rd_en           (w_l2_rdport_en),
        .i_l3_rd_addr_packed  (w_l2_rdport_addr_packed),
        .o_l3_rd_dout_packed  (w_l2_rdport_dout_packed),
        .o_l3_rd_valid        (w_l2_rdport_valid),

        .o_done               (w_l2_done)
    );

    // ====== L3_top ======
    L3_top #(
        .MEM_ADDR   (MEM_ADDR),
        .WEIGHT_INIT(L3_W_INIT)
    ) u_l3 (
        .i_clk                (i_clk),
        .i_rstn               (i_rstn),
        .i_start              (w_l3_start),
        .i_image_bit          (w_l3_imgbit),

        .o_l2_rd_en           (w_l2_rdport_en),
        .o_l2_rd_addr_packed  (w_l2_rdport_addr_packed),
        .i_l2_rd_dout_packed  (w_l2_rdport_dout_packed),
        .i_l2_rd_valid        (w_l2_rdport_valid),

        .o_pixel_valid        (o_pixel_valid),
        .o_pixel_data         (o_pixel_data),

        .o_done               (w_l3_done)
    );

    assign o_image_bit = w_l3_imgbit;

endmodule
