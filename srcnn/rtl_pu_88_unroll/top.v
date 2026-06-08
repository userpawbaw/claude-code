`timescale 1ns / 1ps
// top (preset 8_8 UNROLL) : 8-way (L1/L2) + 4-way (L3) parallel SRCNN.
//
//   - 단일 PU (PU.v, 8-way unroll + L3 4-way)
//   - weight BRAM 128bit × 93 word
//   - input BRAM **128bit × 8664** word (3 img × 152 row × 19 col_word).
//   - URAM_L1 8 bank, **128bit × 2888** word (= 8 px × 152 row × 19 col_word).
//   - URAM_L2 8 bank, **128bit × 2888** word.
//   - L3 path : URAM_L2 read every-other clk + 4-px depacker mux (upper/lower 64b).
//   - 8 packer_8x : PU 8 oc 출력 → URAM_L1 / URAM_L2[oc] 128-bit word write.
//   - L3 final output : 4 px / clk via per-lane valid mask (user-provided downstream packer).
//
//   FSM 통신 :
//     - L1 : i_rd_addr / i_rd_en  (128b input BRAM)
//     - L2 : intermid_uram_rd_en + intermid_uram_rd_addr (URAM_L1 8 banks 병렬 read)
//     - L3 : intermid_uram_rd_en + intermid_uram_rd_addr (URAM_L2 8 banks 병렬 read,
//                                                         half rate for 4-px stream)

module top #(
    parameter MEM_ADDR = 17,
    parameter URAM_AW  = 13,
    parameter NPIX_IMG = 2888,
    parameter MAX_CH   = 8
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,
    output wire        o_img_done,
    output wire        o_all_done,
    output wire        o_pixel_valid,
    output wire [63:0] o_pixel_data,        // L3 : 4 px × 16 bit packed
    output wire [3:0]  o_lane_valid         // L3 per-px valid
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
    wire                       w_fifo_rd_en;       // unused (kept for FSM compat)
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
    // Weight BRAM (unchanged)
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

    // ------------------------------------------------------------------
    // Input BRAM : 128-bit × 8664 word (3 img × 2888 word / img).
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
    // URAMs : 8 bank each, 128-bit × 2888 (= 8 px × 152 row × 19 word).
    // ------------------------------------------------------------------
    wire [127:0]        w_uram_L1_dout    [0:MAX_CH-1];
    wire                w_uram_L1_rd_valid[0:MAX_CH-1];
    wire [127:0]        w_uram_L2_dout    [0:MAX_CH-1];
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
                .WIDTH(128), .DEPTH(2888), .INIT_FILE("")
            ) u_uram_L1 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd0) && w_pack_we[b]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_pack_dout_flat[128*b +: 128]),
                .rd_en    ((w_layer_cnt == 2'd1) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L1_rd_valid[b]),
                .rd_dout  (w_uram_L1_dout[b])
            );
        end
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_uram_L2
            simple_dual_port_uram #(
                .WIDTH(128), .DEPTH(2888), .INIT_FILE("")
            ) u_uram_L2 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd1) && (w_out_ch_cnt == b[2:0]) && w_pack_we[0]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_pack_dout_flat[0 +: 128]),
                .rd_en    ((w_layer_cnt == 2'd2) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L2_rd_valid[b]),
                .rd_dout  (w_uram_L2_dout[b])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // L3 path depacker : URAM_L2 128b/ch (8 px) → 4 px/clk via half-toggle.
    //   FSM 가 L3 동안 intermid_uram_rd_en 을 every-other-clk 으로 토글한다고
    //   가정. URAM read 결과를 latch 한 뒤 r_l3_half=0 → upper 64b (px 0..3),
    //   r_l3_half=1 → lower 64b (px 4..7). 매 clk i_input_valid 로 line buffer
    //   에 4 px 공급.
    // ------------------------------------------------------------------
    reg [127:0] r_l3_word [0:MAX_CH-1];
    reg         r_l3_half;
    reg         r_l3_in_valid;

    integer hi;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for (hi = 0; hi < MAX_CH; hi = hi + 1) r_l3_word[hi] <= 0;
            r_l3_half     <= 0;
            r_l3_in_valid <= 0;
        end else if (w_IDLE_rst || w_dispatch_rst) begin
            for (hi = 0; hi < MAX_CH; hi = hi + 1) r_l3_word[hi] <= 0;
            r_l3_half     <= 0;
            r_l3_in_valid <= 0;
        end else if (w_layer_cnt == 2'd2) begin
            // capture URAM read result (1-clk read latency).
            if (w_uram_L2_rd_valid[0]) begin
                for (hi = 0; hi < MAX_CH; hi = hi + 1) r_l3_word[hi] <= w_uram_L2_dout[hi];
                r_l3_half <= 0;        // newly captured word → present upper half.
            end else begin
                r_l3_half <= ~r_l3_half;
            end
            r_l3_in_valid <= 1'b1;
        end else begin
            r_l3_in_valid <= 1'b0;
        end
    end

    // 4-px-per-ch slice : upper 64b = px 0..3 (cols K*4..K*4+3), lower = px 4..7.
    wire [MAX_CH*64-1:0] w_pu_data_l3;
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_l3_slice
            assign w_pu_data_l3[((MAX_CH-1)-b)*64 +: 64] =
                r_l3_half ? r_l3_word[b][63:0] : r_l3_word[b][127:64];
        end
    endgenerate

    // ------------------------------------------------------------------
    // PU input routing for L1/L2 wide path :
    //   L1 : slot 0 (MSB 128b) = input BRAM, 나머지 0.
    //   L2 : 8 slot = w_uram_L1_dout[0..7].
    // ------------------------------------------------------------------
    wire [MAX_CH*128-1:0] w_pu_data_wide;
    assign w_pu_data_wide =
        (w_layer_cnt == 2'd0) ?
            { w_i_dout, {(MAX_CH-1){128'h0}} } :
            { w_uram_L1_dout[0], w_uram_L1_dout[1],
              w_uram_L1_dout[2], w_uram_L1_dout[3],
              w_uram_L1_dout[4], w_uram_L1_dout[5],
              w_uram_L1_dout[6], w_uram_L1_dout[7] };

    wire w_pu_input_valid =
        (w_layer_cnt == 2'd0) ? w_i_rd_valid :
        (w_layer_cnt == 2'd1) ? w_uram_L1_rd_valid[0] :
                                r_l3_in_valid;

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
    // 8 packer_8x
    //   L1: oc 0..7 모두 활성, 각 oc slot 128b → URAM_L1[oc].
    //   L2: oc slot 0 만 활성, 128b → URAM_L2[ out_ch_cnt ].
    //   L3: packer 사용 안 함 (final output 직접 stream).
    // ------------------------------------------------------------------
    generate
        for (b = 0; b < MAX_CH; b = b + 1) begin : gen_pack
            wire en_b = (b == 0)
                ? (w_pu_emit_valid && w_pu_oc_mask[0])
                : (w_pu_emit_valid && w_pu_oc_mask[b] && (w_layer_cnt == 2'd0));
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
    // L3 final output : oc 0 slot, 4 px × 16 bit (= 64 bit) + per-px valid.
    // ------------------------------------------------------------------
    assign o_pixel_valid = (w_layer_cnt == 2'd2) && w_pu_emit_valid && w_pu_oc_mask[0];
    assign o_pixel_data  = w_pu_pixel_data[0 + (4*16) +: 64];   // lane 0..3 (MSB 64 bit of slot 0)
    assign o_lane_valid  = w_pu_lane_mask[3:0];

endmodule
