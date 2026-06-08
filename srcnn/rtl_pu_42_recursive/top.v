`timescale 1ns / 1ps
// top (preset 4_2 UNROLL) : 8-way (L1/L2) + 4-way (L3) parallel SRCNN.
//
// Channel chain :
//   L1 : 1 → 4  ch  (4 URAM_L1 banks).
//   L2 : 4 → 2  ch  (2 URAM_L2 banks, no time-mux, 2 oc 공간 병렬).
//   L3 : 2 → 1  ch  (final output stream).
//
//   - 단일 PU (PU.v, 8×8 pe_group grid 유지, 64 instances)
//     L1 : g=0..3 = oc 0..3 (in_ch=1 broadcast), lanes 0..7.
//     L2 : g=0..3 = oc=0 in_ch 0..3, g=4..7 = oc=1 in_ch 0..3, lanes 0..7.
//     L3 : g=0..1 = in_ch 0..1, lanes 0..3.
//   - weight BRAM 128b × 30 word (new layout, gen_golden.py 참고)
//   - input BRAM 128b × 8664 (3 img × 2888).
//   - URAM_L1 4 bank, 128b × 2888.
//   - URAM_L2 2 bank, 128b × 2888.

module top #(
    parameter MEM_ADDR    = 17,
    parameter URAM_AW     = 13,
    parameter NPIX_IMG    = 2888,
    parameter MAX_CH      = 8,    // PU grid size (kept 8 for 64 pe_group)
    parameter L1_OC       = 4,
    parameter L2_OC       = 2,
    parameter L2_IC       = 4,    // = L1_OC
    parameter L3_IC       = 2     // = L2_OC
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,
    output wire        o_img_done,
    output wire        o_all_done,
    // L3 raw stream (debug / direct consume) — 8 lane × 16 bit + mask.
    output wire         o_pixel_valid,
    output wire [127:0] o_pixel_data,
    output wire [7:0]   o_lane_valid,
    // Output URAM port (packed 8 px / word, post-packer + flush).
    output wire [127:0] o_out_word,
    output wire         o_out_we,
    output wire [3:0]   o_out_flush_cnt
);
    // ------------------------------------------------------------------
    // FSM signals
    // ------------------------------------------------------------------
    wire                       w_w_rd_en;
    wire [MEM_ADDR-1:0]        w_w_rd_addr;
    wire                       w_bias_en;
    wire                       w_i_rd_en;
    wire [MEM_ADDR-1:0]        w_i_rd_addr;
    wire                       w_intermid_uram_rd_en;
    wire [MEM_ADDR-3:0]        w_intermid_uram_rd_addr;
    wire                       w_fifo_rd_en;
    wire                       w_input_dummy_valid;
    wire                       w_pad_wr_en;
    wire                       w_IDLE_rst;
    wire                       w_dispatch_rst;
    wire                       w_wr_addr_rst;
    wire                       w_is_pad;
    wire                       w_is_pad_valid;
    wire                       w_line_done;
    wire [1:0]                 w_layer_cnt;
    wire [2:0]                 w_out_ch_cnt;
    wire [1:0]                 w_img_cnt;

    wire                            w_pu_emit_valid;
    wire [MAX_CH-1:0]               w_pu_oc_mask;
    wire [MAX_CH*8-1:0]             w_pu_lane_mask;
    wire [MAX_CH*8*16-1:0]          w_pu_pixel_data;
    wire                            w_pu_img_done;

    wire [MAX_CH-1:0]          w_pack_we;
    wire [MAX_CH*128-1:0]      w_pack_dout_flat;

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
        .o_input_dummy_valid     (w_input_dummy_valid),
        .o_pad_wr_en             (w_pad_wr_en),
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
    // Weight BRAM : 128-bit × 30 (preset 4_2 layout).
    // ------------------------------------------------------------------
    wire                w_w_rd_valid;
    wire [127:0]        w_w_dout;
    simple_dual_port_bram #(
        .WIDTH(128), .DEPTH(32), .INIT_FILE("weight.txt")
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

    // ------------------------------------------------------------------
    // Input BRAM : 128-bit × 8664 word.
    // ------------------------------------------------------------------
    wire        w_i_rd_valid;
    wire [127:0] w_i_dout;
    simple_dual_port_bram #(
        .WIDTH(128), .DEPTH(8664), .INIT_FILE("input.txt")
    ) u_i_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (w_i_rd_en),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .rd_addr  (w_i_rd_addr),
        .wr_din   (128'h0),
        .rd_valid (w_i_rd_valid),
        .rd_dout  (w_i_dout)
    );

    // ------------------------------------------------------------------
    // URAM_L1 : 4 banks (one per L1 oc). 128-bit × 2888.
    // URAM_L2 : 2 banks (one per L2 oc). 128-bit × 2888.
    // ------------------------------------------------------------------
    wire [127:0]        w_uram_L1_dout    [0:L1_OC-1];
    wire                w_uram_L1_rd_valid[0:L1_OC-1];
    wire [127:0]        w_uram_L2_dout    [0:L2_OC-1];
    wire                w_uram_L2_rd_valid[0:L2_OC-1];

    wire w_uram_L1_wr_en      [0:L1_OC-1];
    wire [127:0] w_uram_L1_wr_din [0:L1_OC-1];
    wire w_uram_L2_wr_en      [0:L2_OC-1];
    wire [127:0] w_uram_L2_wr_din [0:L2_OC-1];

    // L1 write : packer slot b (=oc) → URAM_L1[b], b=0..3.
    // L2 write : packer slot b (=oc) → URAM_L2[b], b=0..1 (no time-mux).
    genvar b;
    generate
        for (b = 0; b < L1_OC; b = b + 1) begin : gen_L1_wmux
            assign w_uram_L1_wr_en[b]  = (w_layer_cnt == 2'd0) && w_pack_we[b];
            assign w_uram_L1_wr_din[b] = w_pack_dout_flat[128*b +: 128];
        end
        for (b = 0; b < L2_OC; b = b + 1) begin : gen_L2_wmux
            assign w_uram_L2_wr_en[b]  = (w_layer_cnt == 2'd1) && w_pack_we[b];
            assign w_uram_L2_wr_din[b] = w_pack_dout_flat[128*b +: 128];
        end
    endgenerate

    localparam WORDS_PER_ROW = 19;
    wire w_wr_advance = w_pack_we[0];

    reg [URAM_AW-1:0]   r_wr_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)              r_wr_addr <= 0;
        else if (w_wr_addr_rst)   r_wr_addr <= WORDS_PER_ROW[URAM_AW-1:0];
        else if (w_wr_advance)    r_wr_addr <= r_wr_addr + 1'b1;
    end

    generate
        for (b = 0; b < L1_OC; b = b + 1) begin : gen_uram_L1
            simple_dual_port_uram #(
                .WIDTH(128), .DEPTH(2888), .INIT_FILE("")
            ) u_uram_L1 (
                .clk      (i_clk),
                .wr_en    (w_uram_L1_wr_en[b]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_uram_L1_wr_din[b]),
                .rd_en    ((w_layer_cnt == 2'd1) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L1_rd_valid[b]),
                .rd_dout  (w_uram_L1_dout[b])
            );
        end
        for (b = 0; b < L2_OC; b = b + 1) begin : gen_uram_L2
            simple_dual_port_uram #(
                .WIDTH(128), .DEPTH(2888), .INIT_FILE("")
            ) u_uram_L2 (
                .clk      (i_clk),
                .wr_en    (w_uram_L2_wr_en[b]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_uram_L2_wr_din[b]),
                .rd_en    ((w_layer_cnt == 2'd2) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L2_rd_valid[b]),
                .rd_dout  (w_uram_L2_dout[b])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // L3 path : URAM_L2 128b/ch (8 px) → PU 직접 공급 (every-clk read, no depacker).
    //   L3 line_buffer_wide_l3_8x 가 8 px/clk shift in 처리.
    //   2 banks active (L3_IC = 2). 나머지 슬롯은 0.
    // ------------------------------------------------------------------
    wire [MAX_CH*128-1:0] w_pu_data_l3;
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_l3_slice
            if (b < L3_IC) begin : gen_l3_active
                assign w_pu_data_l3[((MAX_CH-1)-b)*128 +: 128] = w_uram_L2_dout[b];
            end else begin : gen_l3_zero
                assign w_pu_data_l3[((MAX_CH-1)-b)*128 +: 128] = 128'h0;
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // PU input routing for L1/L2 wide path.
    //   L1 : 1 ch input → slot 0 (MSB 128b), 나머지 0.
    //   L2 : 4 in_ch = URAM_L1[0..3] → slots 0..3, slots 4..7 = 0.
    // ------------------------------------------------------------------
    wire [127:0] w_l1_data_in = w_input_dummy_valid ? 128'h0 : w_i_dout;

    wire [127:0] w_l2_ic [0:MAX_CH-1];
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_l2_ic
            if (b < L2_IC) begin : gen_l2_ic_act
                assign w_l2_ic[b] = w_input_dummy_valid ? 128'h0 : w_uram_L1_dout[b];
            end else begin : gen_l2_ic_zero
                assign w_l2_ic[b] = 128'h0;
            end
        end
    endgenerate

    wire [MAX_CH*128-1:0] w_pu_data_wide;
    assign w_pu_data_wide =
        (w_layer_cnt == 2'd0) ?
            { w_l1_data_in, {(MAX_CH-1){128'h0}} } :
            { w_l2_ic[0], w_l2_ic[1], w_l2_ic[2], w_l2_ic[3],
              w_l2_ic[4], w_l2_ic[5], w_l2_ic[6], w_l2_ic[7] };

    wire w_pu_input_valid =
        (w_layer_cnt == 2'd0) ? (w_i_rd_valid | w_input_dummy_valid) :
        (w_layer_cnt == 2'd1) ? (w_uram_L1_rd_valid[0] | w_input_dummy_valid) :
                                (w_uram_L2_rd_valid[0] | w_input_dummy_valid);

    // ------------------------------------------------------------------
    // PU
    // ------------------------------------------------------------------
    PU #(.MAX_CH(MAX_CH)) u_pu (
        .i_clk              (i_clk),
        .i_rstn             (i_rstn),
        .i_IDLE_rst         (w_IDLE_rst),
        .i_dispatch_rst     (w_dispatch_rst),
        .i_layer_cnt        (w_layer_cnt),
        .i_out_ch_cnt       (w_out_ch_cnt),
        .i_input_valid      (w_pu_input_valid),
        .i_uram_data_wide   (w_pu_data_wide),
        .i_uram_data_l3     (w_pu_data_l3),
        .i_w_rd_en          (w_w_rd_valid),
        .i_weight_bram_data (w_w_dout),
        .i_bias_en          (w_bias_en),
        .o_emit_valid       (w_pu_emit_valid),
        .o_oc_valid_mask    (w_pu_oc_mask),
        .o_lane_valid_mask  (w_pu_lane_mask),
        .o_pixel_data       (w_pu_pixel_data),
        .o_img_done         (w_pu_img_done)
    );

    // ------------------------------------------------------------------
    // packer_8x : 8 instances (one per PU oc slot).
    //   L1 : slot 0..3 active (4 oc).
    //   L2 : slot 0..1 active (2 oc, no time-mux).
    //   L3 : packer not used (direct stream out).
    // ------------------------------------------------------------------
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_pack
            wire en_b = w_pu_emit_valid && w_pu_oc_mask[b]
                && ((w_layer_cnt == 2'd0 && b < L1_OC)
                 || (w_layer_cnt == 2'd1 && b < L2_OC));
            wire [127:0] data_b = w_pu_pixel_data[b*128 +: 128];
            packer_8x u_pack (
                .i_clk         (i_clk),
                .i_rstn        (i_rstn),
                .i_en          (en_b),
                .i_data        (data_b),
                .o_output_uram (w_pack_dout_flat[b*128 +: 128]),
                .o_uram_we     (w_pack_we[b])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // L3 raw stream : oc 0 slot, 8 px × 16 bit + per-px valid.
    // ------------------------------------------------------------------
    assign o_pixel_valid = (w_layer_cnt == 2'd2) && w_pu_emit_valid && w_pu_oc_mask[0];
    assign o_pixel_data  = w_pu_pixel_data[0 +: 128];
    assign o_lane_valid  = w_pu_lane_mask[7:0];

    // ------------------------------------------------------------------
    // L3 packer (8-way) : 6/8 valid 스트림 → 8-px word stream.
    //   flush : pu_img_done (= L3 line buffer img_done) 시점에 save 남은 px 출력.
    //           PU 내부 +3 clk 지연을 거쳐 packer 출력 정렬에 맞춤.
    // ------------------------------------------------------------------
    wire w_pack_flush;
    delay_shift #(.DELAY(1)) u_flush_dly (
        .clk  (i_clk),
        .rst  (~i_rstn),
        .en   (1'b1),
        .din  (w_pu_img_done & (w_layer_cnt == 2'd2)),
        .dout (w_pack_flush)
    );

    packer_l3_8x u_pack_l3 (
        .i_clk        (i_clk),
        .i_rstn       (i_rstn),
        .i_en         (o_pixel_valid),
        .i_data       (o_pixel_data),
        .i_lane_valid (o_lane_valid),
        .i_flush      (w_pack_flush),
        .o_data       (o_out_word),
        .o_we         (o_out_we),
        .o_flush_cnt  (o_out_flush_cnt)
    );

endmodule
