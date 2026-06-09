`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// L2 top  (SRCNN streamline)
//
//   Sub-blocks:
//     - L2 weight BRAM    (64-bit × 76 = 19 × 4 out_ch)
//     - FSM_pad           (L2_local_FSM, exposes o_out_ch_cnt for URAM lane select)
//     - L2_PU              (in_ch=8 parallel, out_ch=4 time-partitioned)
//     - 4 × intermid2_3 URAM (16-bit × 45000 each, one per output channel)
//
//   Up-stream (from L1_top):
//     drives intermid1_2 URAM read interface via o_l1_rd_*  / i_l1_rd_*.
//
//   Down-stream (to L3_top):
//     exposes 4 intermid2_3 URAM read interfaces (packed vectors).
// -----------------------------------------------------------------------------

module L2_top #(
    parameter MEM_ADDR    = 15,
    parameter WEIGHT_INIT = "weight_l2.txt"
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_start,
    input  wire                          i_image_bit,

    // Drives intermid1_2 URAM R-port (소유자: L1_top)
    output wire                          o_l1_rd_en,
    output wire [MEM_ADDR:0]             o_l1_rd_addr,
    input  wire [127:0]                  i_l1_rd_dout,
    input  wire                          i_l1_rd_valid,

    // intermid2_3 URAM R-ports for L3_top (packed: 4 channels)
    input  wire [3:0]                    i_l3_rd_en,
    input  wire [4*(MEM_ADDR+1)-1:0]     i_l3_rd_addr_packed,
    output wire [4*16-1:0]               o_l3_rd_dout_packed,
    output wire [3:0]                    o_l3_rd_valid,

    output wire                          o_done
);

    // --- FSM <-> PU / Mem wires ---
    wire                  w_w_rd_en;
    wire [MEM_ADDR-1:0]   w_w_rd_addr;
    wire                  w_w_rd_valid;
    wire [63:0]           w_w_rd_dout;
    wire                  w_bias_en;

    wire                  w_uram_rd_en;
    wire [MEM_ADDR-1:0]   w_uram_rd_addr;

    wire                  w_IDLE_rst;
    wire                  w_is_pad_valid;
    wire [1:0]            w_out_ch_cnt;
    wire                  w_done;

    // --- L2_PU outputs ---
    wire                  w_pixel_valid;
    wire [15:0]           w_pixel_data;
    wire                  w_line_rd_done;
    wire                  w_pe_done;
    wire                  w_img_done;

    // =========================================================================
    // L2_local_FSM (= FSM_pad)
    // =========================================================================
    FSM_pad #(
        .I_NUM(152),
        .MEM_ADDR_WIDTH(MEM_ADDR)
    ) u_fsm (
        .i_clk                     (i_clk),
        .i_rstn                    (i_rstn),
        .i_start                   (i_start),
        .i_line_rd_done            (w_line_rd_done),
        .i_adder_done              (w_img_done),    // drain-aligned (NOT w_pe_done)
        .i_uram_we                 (1'b0),

        .o_weight_bram_rd_en       (w_w_rd_en),
        .o_weight_bram_rd_addr     (w_w_rd_addr),
        .o_bias_en                 (w_bias_en),

        .o_input_bram_rd_en        (w_uram_rd_en),
        .o_input_bram_rd_addr      (w_uram_rd_addr),

        .o_IDLE_rst                (w_IDLE_rst),

        .o_intermid_uram_rd_en     (),
        .o_intermid_uram_rd_addr   (),
        .fifo_rd_en                (),

        .o_input_bram_rd_line_done (),
        .o_is_pad                  (),
        .o_is_pad_valid            (w_is_pad_valid),
        .o_line_done               (),
        .o_line_shift_en           (),
        .o_done                    (w_done),
        .o_out_ch_cnt              (w_out_ch_cnt)
    );

    // =========================================================================
    // L2 Weight BRAM (64-bit × 76)
    //   - L2 weight 19 word/out_ch × 4 out_ch = 76 entries total
    // =========================================================================
    simple_dual_port_bram #(
        .WIDTH(64),
        .DEPTH(76),
        .INIT_FILE(WEIGHT_INIT)
    ) u_l2_w_bram (
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
    // intermid1_2 URAM R-port forwarding (image_bit MSB prepended)
    // =========================================================================
    assign o_l1_rd_en   = w_uram_rd_en;
    assign o_l1_rd_addr = {i_image_bit, w_uram_rd_addr};

    // =========================================================================
    // L2_PU
    // =========================================================================
    L2_PU u_pu (
        .i_clk              (i_clk),
        .i_rstn             (i_rstn),
        .i_IDLE_rst         (w_IDLE_rst),

        .i_input_valid      (i_l1_rd_valid),
        .i_uram_data        (i_l1_rd_dout),
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

    // =========================================================================
    // intermid2_3 URAM Write Address Counter (shared across 4 channel URAMs)
    // =========================================================================
    reg [14:0] r_uram_wr_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)              r_uram_wr_addr <= 15'd0;
        else if (w_IDLE_rst)      r_uram_wr_addr <= 15'd0;
        else if (w_pixel_valid)   r_uram_wr_addr <= r_uram_wr_addr + 1'b1;
    end

    wire [MEM_ADDR:0] w_uram_wr_full_addr = {i_image_bit, r_uram_wr_addr};

    // =========================================================================
    // 4 × intermid2_3 URAM (16-bit × 45000) — one URAM per output channel
    //   - L2_PU outputs 1 channel pixels during each out_ch iteration
    //   - Channel-k URAM accepts writes only when out_ch_cnt == k
    // =========================================================================
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : gen_intermid2_3
            wire w_wr_en_ch = w_pixel_valid & (w_out_ch_cnt == k[1:0]);

            simple_dual_port_uram #(
                .WIDTH(16),
                .DEPTH(45000)
            ) u_intermid2_3 (
                .clk      (i_clk),
                .wr_en    (w_wr_en_ch),
                .wr_addr  (w_uram_wr_full_addr),
                .wr_din   (w_pixel_data),
                .rd_en    (i_l3_rd_en[k]),
                .rd_addr  (i_l3_rd_addr_packed[(MEM_ADDR+1)*k +: (MEM_ADDR+1)]),
                .rd_valid (o_l3_rd_valid[k]),
                .rd_dout  (o_l3_rd_dout_packed[16*k +: 16])
            );
        end
    endgenerate

    // FSM_pad fires o_done once per out_ch iteration (4 times total per image).
    // global_FSM expects one done pulse per image, so only expose the 4th pulse.
    reg [1:0] r_done_cnt;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) r_done_cnt <= 2'd0;
        else if (w_done) r_done_cnt <= r_done_cnt + 2'd1;
    end
    assign o_done = w_done & (r_done_cnt == 2'd3);

endmodule
