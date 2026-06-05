`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// L1 top  (SRCNN streamline)
//
//   Sub-blocks:
//     - L1 image BRAM     (16-bit × 22500, INIT_FILE)
//     - L1 weight BRAM    (64-bit × 20,    INIT_FILE)
//     - L1_local_FSM
//     - L1_PU              (in_ch=1, out_ch=8 parallel)
//     - intermid1_2 URAM  (128-bit × 45000)  ← W-side here, R-port exposed for L2_top
//
//   Memory layout (URAM):
//     addr[15]   = image_bit          (이미지 영역 교차)
//     addr[14:0] = pixel_idx (0~22499) (raster order, 150×150)
//     data[127:0] = {ch7, ch6, ..., ch1, ch0}  (LSB 안도에 ch0; L2_PU.i_uram_data[16*i+:16] 과 속도와 일치)
// -----------------------------------------------------------------------------

module L1_top #(
    parameter MEM_ADDR    = 15,
    parameter IMG_INIT    = "image_l1.txt",
    parameter WEIGHT_INIT = "weight_l1.txt"
)(
    input  wire                   i_clk,
    input  wire                   i_rstn,
    input  wire                   i_start,
    input  wire                   i_image_bit,   // image_cnt[0] from global FSM

    // Exposed read port for L2_top (intermid1_2 URAM)
    input  wire                   i_l2_rd_en,
    input  wire [MEM_ADDR:0]      i_l2_rd_addr,  // 16-bit (image_bit + pixel_idx)
    output wire [127:0]           o_l2_rd_dout,
    output wire                   o_l2_rd_valid,

    output wire                   o_done
);

    // --- internal wires ---
    wire                  w_w_rd_en;
    wire [MEM_ADDR-1:0]   w_w_rd_addr;
    wire                  w_w_rd_valid;
    wire signed [63:0]    w_w_rd_dout;

    wire                  w_i_rd_en;
    wire [MEM_ADDR-1:0]   w_i_rd_addr;
    wire                  w_i_rd_valid;
    wire signed [15:0]    w_i_rd_dout;

    wire                  w_IDLE_rst;
    wire                  w_is_pad_valid;
    wire                  w_done;

    wire                  w_pixel_valid;
    wire [127:0]          w_uram_data;
    wire                  w_img_done;

    // --- padding mux (zero on pad region) ---
    wire signed [15:0]    w_lb_data;
    wire                  w_lb_valid;
    assign w_lb_data  = w_is_pad_valid ? 16'h0 : w_i_rd_dout;
    assign w_lb_valid = w_is_pad_valid ? 1'b1 : w_i_rd_valid;

    // =========================================================================
    // L1_local_FSM
    // =========================================================================
    L1_local_FSM #(
        .MEM_ADDR_WIDTH(MEM_ADDR)
    ) u_fsm (
        .i_clk                 (i_clk),
        .i_rstn                (i_rstn),
        .i_start               (i_start),
        .i_adder_done          (w_img_done),       // drain-aligned

        .o_weight_bram_rd_en   (w_w_rd_en),
        .o_weight_bram_rd_addr (w_w_rd_addr),

        .o_input_bram_rd_en    (w_i_rd_en),
        .o_input_bram_rd_addr  (w_i_rd_addr),

        .o_is_pad              (),
        .o_is_pad_valid        (w_is_pad_valid),

        .o_IDLE_rst            (w_IDLE_rst),
        .o_done                (w_done)
    );

    // =========================================================================
    // L1 Image BRAM  (16-bit × 22500)
    // =========================================================================
    simple_dual_port_bram #(
        .WIDTH(16),
        .DEPTH(22500),
        .INIT_FILE(IMG_INIT)
    ) u_l1_img_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .wr_din   (16'h0),
        .rd_en    (w_i_rd_en),
        .rd_addr  (w_i_rd_addr),
        .rd_valid (w_i_rd_valid),
        .rd_dout  (w_i_rd_dout)
    );

    // =========================================================================
    // L1 Weight BRAM (64-bit × 20)
    // =========================================================================
    simple_dual_port_bram #(
        .WIDTH(64),
        .DEPTH(20),
        .INIT_FILE(WEIGHT_INIT)
    ) u_l1_w_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .wr_din   (64'h0),
        .rd_en    (w_w_rd_en),
        .rd_addr  (w_w_rd_addr),
        .rd_valid (w_w_rd_valid),
        .rd_dout  (w_w_rd_dout)
    );

    // =========================================================================
    // L1_PU
    // =========================================================================
    L1_PU u_pu (
        .i_clk                 (i_clk),
        .i_rstn                (i_rstn),
        .i_IDLE_rst            (w_IDLE_rst),

        .i_input_valid         (w_lb_valid),
        .i_pixel_data          (w_lb_data),

        .i_w_rd_en             (w_w_rd_valid),     // 1clk-delayed weight rd_en → align with rd_dout
        .i_weight_bram_data    (w_w_rd_dout),

        .o_pixel_valid         (w_pixel_valid),
        .o_uram_data           (w_uram_data),

        .o_img_done            (w_img_done)
    );

    // =========================================================================
    // intermid1_2 URAM Write Address Counter
    //   - reset on IDLE_rst (between images) and rstn
    //   - increments on each valid pixel from L1_PU
    // =========================================================================
    reg [14:0] r_uram_wr_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)               r_uram_wr_addr <= 15'd0;
        else if (w_IDLE_rst)       r_uram_wr_addr <= 15'd0;
        else if (w_pixel_valid)    r_uram_wr_addr <= r_uram_wr_addr + 1'b1;
    end

    wire [MEM_ADDR:0] w_uram_wr_full_addr = {i_image_bit, r_uram_wr_addr};

    // =========================================================================
    // intermid1_2 URAM (128-bit × 45000)
    // =========================================================================
    simple_dual_port_uram #(
        .WIDTH(128),
        .DEPTH(45000)
    ) u_intermid1_2 (
        .clk      (i_clk),
        .wr_en    (w_pixel_valid),
        .wr_addr  (w_uram_wr_full_addr),
        .wr_din   (w_uram_data),
        .rd_en    (i_l2_rd_en),
        .rd_addr  (i_l2_rd_addr),
        .rd_valid (o_l2_rd_valid),
        .rd_dout  (o_l2_rd_dout)
    );

    assign o_done = w_done;

endmodule
