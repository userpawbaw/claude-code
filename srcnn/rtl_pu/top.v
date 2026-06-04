`timescale 1ns / 1ps
// top : PU-based SRCNN 4_2 (1->4->2->1), 3-image 연속 처리.
//   - L1_PU / L2_PU / L3_PU 인스턴스, 각 PU 가 bias+ReLU(L3 제외) 통합.
//   - weight BRAM 64bit x 35 word, input BRAM 16bit x 67500 word (3 img concat).
//   - URAM_L1 4뱅크 + URAM_L2 2뱅크. img 간 재사용.
//   - L1 출력은 4 oc 동시 → 4 packer 가 ch 별로 spatial 4-pix word 패킹.
//   - L2/L3 는 16-bit/cycle 단일 stream → 1 packer.
//   - o_img_done : 매 img L3 완료 시 1-clk pulse.
//   - o_all_done : 3 img 모두 완료 후 latch.
module top #(
    parameter MEM_ADDR = 17,
    parameter URAM_AW  = 13,
    parameter NPIX_IMG = 22500
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,
    output wire        o_img_done,
    output wire        o_all_done,
    output wire        o_pixel_valid,
    output wire [15:0] o_pixel_data
);
    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    wire                       w_w_rd_en;
    wire [MEM_ADDR-1:0]        w_w_rd_addr;
    wire                       w_bias_en_fsm;
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
    wire                       w_out_ch_cnt;
    wire [1:0]                 w_img_cnt;

    // packer pulses (per-layer)
    wire [3:0]                 w_pack_L1_we;
    wire [4*64-1:0]            w_pack_L1_dout_flat;
    wire                       w_pack_L2_we;
    wire [63:0]                w_pack_L2_dout;
    wire                       w_pack_L3_we;
    wire [63:0]                w_pack_L3_dout;

    // adder/pe done (FSM 에 layer-specific 신호 라우팅)
    wire                       w_L1_img_done;
    wire                       w_L2_img_done;
    wire                       w_L3_img_done;

    wire w_active_pe_done_raw =
        (w_layer_cnt == 2'd0) ? w_L1_img_done :
        (w_layer_cnt == 2'd1) ? w_L2_img_done :
                                w_L3_img_done;
    // PU 의 pe_done 은 pipeline 산수 끝단에서 +3clk 가량인데, packer 의 마지막
    // pack_we 가 그것보다 더 뒤에 발사된다. layer_cnt advance 전에 모든 pack_we
    // 가 URAM 에 commit 되도록 추가 지연.
    wire w_active_pe_done;
    delay_shift #(.DELAY(6)) u_pe_done_dly (
        .clk(i_clk), .rst(~i_rstn), .en(1'b1),
        .din(w_active_pe_done_raw), .dout(w_active_pe_done)
    );
    wire w_active_wr_pulse =
        (w_layer_cnt == 2'd0) ? w_pack_L1_we[0] :
        (w_layer_cnt == 2'd1) ? w_pack_L2_we     :
                                w_pack_L3_we;

    FSM_pad #(.MEM_ADDR_WIDTH(MEM_ADDR), .NPIX_IMG(NPIX_IMG)) u_fsm (
        .i_clk                   (i_clk),
        .i_rstn                  (i_rstn),
        .i_start                 (i_start),
        .i_line_img_done         (1'b0),                // 미사용 (PU 가 자체 처리)
        .i_pe_done               (w_active_pe_done),
        .i_uram_we               (w_active_wr_pulse),
        .o_w_rd_en               (w_w_rd_en),
        .o_w_rd_addr             (w_w_rd_addr),
        .o_bias_en               (w_bias_en_fsm),
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
    wire [63:0]         w_w_dout;
    simple_dual_port_bram #(
        .WIDTH(64), .DEPTH(64), .INIT_FILE("weight.txt")
    ) u_w_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (w_w_rd_en),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .rd_addr  (w_w_rd_addr),
        .wr_din   (64'h0),
        .rd_valid (w_w_rd_valid),
        .rd_dout  (w_w_dout)
    );

    // bias_en pulse 는 1clk 후 BRAM dout 안착과 정렬 (FSM 에서 이미 정렬됨)
    wire w_bias_en = w_bias_en_fsm;

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
    // URAMs (uram_L1[0..3], uram_L2[0..1])
    // ------------------------------------------------------------------
    wire [63:0]         w_uram_L1_dout    [0:3];
    wire                w_uram_L1_rd_valid[0:3];
    wire [63:0]         w_uram_L2_dout    [0:1];
    wire                w_uram_L2_rd_valid[0:1];

    // write addr counter per layer (공유)
    reg [URAM_AW-1:0]   r_wr_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)             r_wr_addr <= 0;
        else if (w_wr_addr_rst)  r_wr_addr <= 0;
        else if (w_active_wr_pulse) r_wr_addr <= r_wr_addr + 1'b1;
    end

    // L1 URAM write: layer==0 일 때 4 채널 동시 (각 pack_L1_we[g])
    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_uram_L1
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L1 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd0) && w_pack_L1_we[b]),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_pack_L1_dout_flat[64*b +: 64]),
                .rd_en    ((w_layer_cnt == 2'd1) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L1_rd_valid[b]),
                .rd_dout  (w_uram_L1_dout[b])
            );
        end
        for (b = 0; b < 2; b = b + 1) begin : gen_uram_L2
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L2 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd1) && (w_out_ch_cnt == b[0]) && w_pack_L2_we),
                .wr_addr  (r_wr_addr),
                .wr_din   (w_pack_L2_dout),
                .rd_en    ((w_layer_cnt == 2'd2) && w_intermid_uram_rd_en),
                .rd_addr  (w_intermid_uram_rd_addr[URAM_AW-1:0]),
                .rd_valid (w_uram_L2_rd_valid[b]),
                .rd_dout  (w_uram_L2_dout[b])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // FIFOs (4 for L1->L2, 2 for L2->L3) — 64bit din, 16bit dout
    // ------------------------------------------------------------------
    wire signed [15:0] w_fifo_L1_dout [0:3];
    wire signed [15:0] w_fifo_L2_dout [0:1];
    wire               w_fifo_valid;
    delay_shift #(.DELAY(1)) u_fifo_v (
        .clk(i_clk), .rst(~i_rstn), .en(1'b1),
        .din(w_fifo_rd_en), .dout(w_fifo_valid)
    );
    wire w_fifo_srst = ~i_rstn | w_dispatch_rst;

    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_fifo_L1
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
        for (b = 0; b < 2; b = b + 1) begin : gen_fifo_L2
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
    // L1_PU (1 in_ch, 4 out_ch) — 활성: layer_cnt==0
    // ------------------------------------------------------------------
    wire signed [15:0] w_L1_in_data;
    wire               w_L1_in_valid;
    assign w_L1_in_data  = w_is_pad_valid ? 16'sd0 : w_i_dout;
    // L1_PU 는 layer_cnt==0 일 때만 input valid. 다른 layer 에서 pad-valid 펄스가
    // 새는 것을 막아 packer fifo_cnt 가 drift 하지 않도록.
    assign w_L1_in_valid = (w_layer_cnt == 2'd0) &&
                           (w_is_pad_valid ? 1'b1 : w_i_rd_valid);

    wire [4*16-1:0]    w_L1_pixels;
    wire               w_L1_pixel_valid;
    L1_PU u_L1 (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (w_IDLE_rst),
        .i_input_valid  (w_L1_in_valid),
        .i_pixel_data   (w_L1_in_data),
        .i_w_rd_valid   (w_w_rd_valid && (w_layer_cnt == 2'd0)),
        .i_bias_en      (w_bias_en && (w_layer_cnt == 2'd0)),
        .i_w_word       (w_w_dout),
        .i_dispatch_rst (w_dispatch_rst),
        .o_pixel_valid  (w_L1_pixel_valid),
        .o_pixel_data   (w_L1_pixels),
        .o_img_done     (w_L1_img_done)
    );

    // L1 출력 → 4 packer (ch별 spatial 4-pix word)
    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_pack_L1
            fifo_add_to_uram u_pack (
                .i_clk         (i_clk),
                .i_rstn        (i_rstn),
                .i_fifo_en     (w_L1_pixel_valid),
                .i_data        (w_L1_pixels[16*((4-1)-b) +: 16]),
                .o_output_uram (w_pack_L1_dout_flat[64*b +: 64]),
                .o_uram_we     (w_pack_L1_we[b])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // L2_PU (4 in_ch, 2 out_ch time-mux) — 활성: layer_cnt==1
    // ------------------------------------------------------------------
    wire [4*16-1:0] w_L2_in_concat = {
        w_fifo_L1_dout[0], w_fifo_L1_dout[1], w_fifo_L1_dout[2], w_fifo_L1_dout[3]
    };
    wire signed [15:0] w_L2_pixel;
    wire               w_L2_pixel_valid;
    L2_PU u_L2 (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (w_IDLE_rst),
        .i_dispatch_rst (w_dispatch_rst),
        .i_ch_valid     (w_fifo_valid && (w_layer_cnt == 2'd1)),
        .i_ch_data      (w_L2_in_concat),
        .i_is_pad_valid (w_is_pad_valid && (w_layer_cnt == 2'd1)),
        .i_w_rd_valid   (w_w_rd_valid && (w_layer_cnt == 2'd1)),
        .i_bias_en      (w_bias_en && (w_layer_cnt == 2'd1)),
        .i_w_word       (w_w_dout),
        .i_out_ch_cnt   (w_out_ch_cnt),
        .o_pixel_valid  (w_L2_pixel_valid),
        .o_pixel_data   (w_L2_pixel),
        .o_img_done     (w_L2_img_done)
    );

    fifo_add_to_uram u_pack_L2 (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_fifo_en     (w_L2_pixel_valid),
        .i_data        (w_L2_pixel),
        .o_output_uram (w_pack_L2_dout),
        .o_uram_we     (w_pack_L2_we)
    );

    // ------------------------------------------------------------------
    // L3_PU (2 in_ch, 1 out_ch) — 활성: layer_cnt==2
    // ------------------------------------------------------------------
    wire [2*16-1:0] w_L3_in_concat = {
        w_fifo_L2_dout[0], w_fifo_L2_dout[1]
    };
    wire signed [15:0] w_L3_pixel;
    wire               w_L3_pixel_valid;
    L3_PU u_L3 (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (w_IDLE_rst),
        .i_dispatch_rst (w_dispatch_rst),
        .i_ch_valid     (w_fifo_valid && (w_layer_cnt == 2'd2)),
        .i_ch_data      (w_L3_in_concat),
        .i_is_pad_valid (w_is_pad_valid && (w_layer_cnt == 2'd2)),
        .i_w_rd_valid   (w_w_rd_valid && (w_layer_cnt == 2'd2)),
        .i_bias_en      (w_bias_en && (w_layer_cnt == 2'd2)),
        .i_w_word       (w_w_dout),
        .o_pixel_valid  (w_L3_pixel_valid),
        .o_pixel_data   (w_L3_pixel),
        .o_img_done     (w_L3_img_done)
    );

    fifo_add_to_uram u_pack_L3 (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_fifo_en     (w_L3_pixel_valid),
        .i_data        (w_L3_pixel),
        .o_output_uram (w_pack_L3_dout),
        .o_uram_we     (w_pack_L3_we)
    );

    // ------------------------------------------------------------------
    // 최종 출력 (L3 stream)
    // ------------------------------------------------------------------
    assign o_pixel_valid = w_L3_pixel_valid;
    assign o_pixel_data  = w_L3_pixel;
endmodule
