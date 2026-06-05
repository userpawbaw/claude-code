`timescale 1ns / 1ps
// top (preset 8_8) : Recursive PU-based SRCNN.  단일 PU 가 layer_cnt 로 L1/L2/L3 시분할.
//   - 단일 PU (PU.v, MAX_CH=8)
//   - weight BRAM 128bit x 93 word
//   - input BRAM 16bit x 67500 word (3 img concat)
//   - URAM_L1 8 bank + URAM_L2 8 bank
//   - 8 packer (PU 8-ch 출력 → URAM_L1[0..7] / URAM_L2[oc] / final)
//     L1: 8 packer 활성 (oc 0..7 → URAM_L1[0..7])
//     L2: packer[0] 만 (slot0 → URAM_L2[out_ch_cnt])
//     L3: packer[0] 만 (slot0 → final output)
//   - o_img_done: img L3 완료 시 1-clk pulse
//   - o_all_done: 3 img 모두 완료 후 latched
module top #(
    parameter MEM_ADDR = 17,
    parameter URAM_AW  = 13,
    parameter NPIX_IMG = 22500,
    parameter MAX_CH   = 8
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,
    output wire        o_img_done,
    output wire        o_all_done,
    output wire        o_pixel_valid,
    output wire [15:0] o_pixel_data
);
    wire                       w_w_rd_en;
    wire [MEM_ADDR-1:0]        w_w_rd_addr;
    wire                       w_bias_en;
    wire                       w_i_rd_en;
    wire [MEM_ADDR-1:0]        w_i_rd_addr;
    wire                       w_intermid_uram_rd_en;
    wire [MEM_ADDR-3:0]        w_intermid_uram_rd_addr;
    wire                       w_fifo_rd_en;
    wire                       w_IDLE_rst;
    wire                       w_dispatch_rst;
    wire                       w_wr_addr_rst;
    wire                       w_is_pad;
    wire                       w_is_pad_valid;
    wire                       w_line_done;
    wire [1:0]                 w_layer_cnt;
    wire [2:0]                 w_out_ch_cnt;
    wire [1:0]                 w_img_cnt;

    wire                       w_pu_pixel_valid;
    wire [MAX_CH*16-1:0]       w_pu_pixel_data;
    wire                       w_pu_img_done;

    wire [MAX_CH-1:0]          w_pack_we;
    wire [MAX_CH*64-1:0]       w_pack_dout_flat;

    wire w_active_wr_pulse = w_pack_we[0];

    wire w_active_pe_done;
    delay_shift #(.DELAY(6)) u_pe_done_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pu_img_done),
        .dout (w_active_pe_done)
    );

    FSM_pad #(.MEM_ADDR_WIDTH(MEM_ADDR), .NPIX_IMG(NPIX_IMG)) u_fsm (
        .i_clk                   (i_clk),
        .i_rstn                  (i_rstn),
        .i_start                 (i_start),
        .i_line_img_done         (1'b0),
        .i_pe_done               (w_active_pe_done),
        .i_uram_we               (w_active_wr_pulse),
        .o_w_rd_en               (w_w_rd_en),
        .o_w_rd_addr             (w_w_rd_addr),
        .o_bias_en               (w_bias_en),
        .o_i_rd_en               (w_i_rd_en),
        .o_i_rd_addr             (w_i_rd_addr),
        .o_intermid_uram_rd_en   (w_intermid_uram_rd_en),
        .o_intermid_uram_rd_addr (w_intermid_uram_rd_addr),
        .o_fifo_rd_en            (w_fifo_rd_en),
        .o_IDLE_rst              (w_IDLE_rst),
        .o_dispatch_rst          (w_dispatch_rst),
        .o_wr_addr_rst           (w_wr_addr_rst),
        .o_is_pad                (w_is_pad),
        .o_is_pad_valid          (w_is_pad_valid),
        .o_line_done             (w_line_done),
        .o_layer_cnt             (w_layer_cnt),
        .o_out_ch_cnt            (w_out_ch_cnt),
        .o_img_cnt               (w_img_cnt),
        .o_img_done              (o_img_done),
        .o_all_done              (o_all_done)
    );

    // ------------------------------------------------------------------
    // BRAMs
    // ------------------------------------------------------------------
    wire                w_w_rd_valid;
    wire [127:0]        w_w_dout;
    simple_dual_port_bram #(
        .WIDTH(128), .DEPTH(128), .INIT_FILE("weight.txt")
    ) u_w_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (w_w_rd_en),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .rd_addr  (w_w_rd_addr),
        .wr_din   (128'h0),
        .rd_valid (w_w_rd_valid),
        .rd_dout  (w_w_dout)
    );

    wire                w_i_rd_valid;
    wire signed [15:0]  w_i_dout;
    simple_dual_port_bram #(
        .WIDTH(16), .DEPTH(67500), .INIT_FILE("input.txt")
    ) u_i_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (w_i_rd_en),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .rd_addr  (w_i_rd_addr),
        .wr_din   (16'h0),
        .rd_valid (w_i_rd_valid),
        .rd_dout  (w_i_dout)
    );

    // ------------------------------------------------------------------
    // URAMs : 8 bank each
    // ------------------------------------------------------------------
    wire [63:0]         w_uram_L1_dout    [0:MAX_CH-1];
    wire                w_uram_L1_rd_valid[0:MAX_CH-1];
    wire [63:0]         w_uram_L2_dout    [0:MAX_CH-1];
    wire                w_uram_L2_rd_valid[0:MAX_CH-1];

    reg [URAM_AW-1:0]   r_wr_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)                r_wr_addr <= 0;
        else if (w_wr_addr_rst)     r_wr_addr <= 0;
        else if (w_active_wr_pulse) r_wr_addr <= r_wr_addr + 1'b1;
    end

    genvar b;
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_uram_L1
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L1 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd0) && w_pack_we[b]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_pack_dout_flat[64*b +: 64]),
                .rd_en    ((w_layer_cnt == 2'd1) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L1_rd_valid[b]),
                .rd_dout  (w_uram_L1_dout[b])
            );
        end
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_uram_L2
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L2 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd1) && (w_out_ch_cnt == b[2:0]) && w_pack_we[0]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_pack_dout_flat[0 +: 64]),
                .rd_en    ((w_layer_cnt == 2'd2) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L2_rd_valid[b]),
                .rd_dout  (w_uram_L2_dout[b])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // FIFOs : 8 L1->L2 + 8 L2->L3
    // ------------------------------------------------------------------
    wire signed [15:0] w_fifo_L1_dout [0:MAX_CH-1];
    wire signed [15:0] w_fifo_L2_dout [0:MAX_CH-1];
    wire               w_fifo_valid;
    delay_shift #(.DELAY(1)) u_fifo_v (
        .clk(i_clk), .rst(~i_rstn), .en(1'b1),
        .din(w_fifo_rd_en), .dout(w_fifo_valid)
    );
    wire w_fifo_srst = ~i_rstn | w_dispatch_rst;

    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_fifo_L1
            fifo_generator_0 u_fifo (
                .clk         (i_clk),
                .srst        (w_fifo_srst),
                .din         (w_uram_L1_dout[b]),
                .wr_en       (w_uram_L1_rd_valid[b]),
                .rd_en       (w_fifo_rd_en),
                .dout        (w_fifo_L1_dout[b]),
                .full        (), .empty(), .wr_rst_busy(), .rd_rst_busy()
            );
        end
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_fifo_L2
            fifo_generator_0 u_fifo (
                .clk         (i_clk),
                .srst        (w_fifo_srst),
                .din         (w_uram_L2_dout[b]),
                .wr_en       (w_uram_L2_rd_valid[b]),
                .rd_en       (w_fifo_rd_en),
                .dout        (w_fifo_L2_dout[b]),
                .full        (), .empty(), .wr_rst_busy(), .rd_rst_busy()
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // PU 입력 라우팅 (layer 별)
    //   L1: input BRAM (pad mux), ch_data slot 0 (= bits[127:112]) 만 의미.
    //   L2: 8 FIFO (L1->L2) packed (slot 0..7).
    //   L3: 8 FIFO (L2->L3) packed (slot 0..7).
    // ------------------------------------------------------------------
    wire signed [15:0] w_L1_in_data  = w_is_pad_valid ? 16'sd0 : w_i_dout;
    wire               w_L1_in_valid = w_is_pad_valid ? 1'b1   : w_i_rd_valid;

    wire [MAX_CH*16-1:0] w_pu_ch_data =
        (w_layer_cnt == 2'd0) ? { w_L1_in_data, {(MAX_CH-1){16'd0}} } :
        (w_layer_cnt == 2'd1) ? { w_fifo_L1_dout[0], w_fifo_L1_dout[1],
                                  w_fifo_L1_dout[2], w_fifo_L1_dout[3],
                                  w_fifo_L1_dout[4], w_fifo_L1_dout[5],
                                  w_fifo_L1_dout[6], w_fifo_L1_dout[7] } :
                                { w_fifo_L2_dout[0], w_fifo_L2_dout[1],
                                  w_fifo_L2_dout[2], w_fifo_L2_dout[3],
                                  w_fifo_L2_dout[4], w_fifo_L2_dout[5],
                                  w_fifo_L2_dout[6], w_fifo_L2_dout[7] };

    wire w_pu_input_valid =
        (w_layer_cnt == 2'd0) ? w_L1_in_valid :
                                w_fifo_valid;

    PU #(.MAX_CH(MAX_CH)) u_pu (
        .i_clk              (i_clk),
        .i_rstn             (i_rstn),
        .i_IDLE_rst         (w_IDLE_rst),
        .i_dispatch_rst     (w_dispatch_rst),
        .i_layer_cnt        (w_layer_cnt),
        .i_out_ch_cnt       (w_out_ch_cnt),
        .i_input_valid      (w_pu_input_valid),
        .i_uram_data        (w_pu_ch_data),
        .i_is_pad_valid     (w_is_pad_valid),
        .i_w_rd_en          (w_w_rd_valid),
        .i_weight_bram_data (w_w_dout),
        .i_bias_en          (w_bias_en),
        .o_pixel_valid      (w_pu_pixel_valid),
        .o_pixel_data       (w_pu_pixel_data),
        .o_img_done         (w_pu_img_done)
    );

    // ------------------------------------------------------------------
    // 8 packer
    //   L1: packer[g] 모두 활성 (PU 출력 slot g 받음)
    //   L2/L3: packer[0] 만 활성 (slot 0 받음)
    // ------------------------------------------------------------------
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_pack
            wire en_b = (b == 0) ? w_pu_pixel_valid
                                 : (w_pu_pixel_valid && (w_layer_cnt == 2'd0));
            wire signed [15:0] data_b = w_pu_pixel_data[16*((MAX_CH-1)-b) +: 16];
            fifo_add_to_uram u_pack (
                .i_clk         (i_clk),
                .i_rstn        (i_rstn),
                .i_fifo_en     (en_b),
                .i_data        (data_b),
                .o_output_uram (w_pack_dout_flat[64*b +: 64]),
                .o_uram_we     (w_pack_we[b])
            );
        end
    endgenerate

    assign o_pixel_valid = (w_layer_cnt == 2'd2) ? w_pu_pixel_valid : 1'b0;
    assign o_pixel_data  = w_pu_pixel_data[16*(MAX_CH-1) +: 16];
endmodule
