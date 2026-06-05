`timescale 1ns / 1ps
// top : Recursive PU-based SRCNN 4_2. 단일 PU 가 layer_cnt 로 L1/L2/L3 시분할.
//   - 단일 PU 인스턴스 (PU.v)
//   - weight BRAM 64bit x 35 word (L1 + L2 + L3 weights + bias)
//   - input BRAM 16bit x 67500 word (3 img concat, img당 22500 offset)
//   - URAM_L1 4뱅크 + URAM_L2 2뱅크 (img 간 재사용)
//   - 4 packer (PU 의 4-ch 병렬 출력 → URAM_L1[0..3] / URAM_L2[oc] / final)
//     L1: packer 4 개 모두 활성 (oc 0..3 → URAM_L1[0..3])
//     L2: packer[0] 만 활성 (출력 slot0 → URAM_L2[out_ch_cnt])
//     L3: packer[0] 만 활성 (출력 slot0 → final output)
//   - o_img_done : 매 img L3 완료 시 1-clk pulse
//   - o_all_done : 3 img 모두 완료 후 latch
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
    wire                       w_IDLE_rst;
    wire                       w_dispatch_rst;
    wire                       w_wr_addr_rst;
    wire                       w_is_pad;
    wire                       w_is_pad_valid;
    wire                       w_line_done;
    wire [1:0]                 w_layer_cnt;
    wire                       w_out_ch_cnt;
    wire [1:0]                 w_img_cnt;

    // PU outputs
    wire                       w_pu_pixel_valid;
    wire [4*16-1:0]            w_pu_pixel_data;
    wire                       w_pu_img_done;

    // Packer signals (4 packers, layer 별 활성 분기)
    wire [3:0]                 w_pack_we;
    wire [4*64-1:0]            w_pack_dout_flat;

    // active pack pulse for FSM (layer 별 1 채널 선택)
    //   L1: 4 packer 동시 → 어느 하나 (예: [0]) 사용 (모두 같은 clk).
    //   L2: packer[0]
    //   L3: packer[0]
    wire w_active_wr_pulse = w_pack_we[0];

    // ------------------------------------------------------------------
    // FSM : pe_done 은 PU.o_img_done + 추가 지연 (packer commit 대기)
    // ------------------------------------------------------------------
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
        .i_line_img_done         (1'b0),                // 미사용
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
    // URAMs
    // ------------------------------------------------------------------
    wire [63:0]         w_uram_L1_dout    [0:3];
    wire                w_uram_L1_rd_valid[0:3];
    wire [63:0]         w_uram_L2_dout    [0:1];
    wire                w_uram_L2_rd_valid[0:1];

    // write addr counter (layer 공유)
    reg [URAM_AW-1:0]   r_wr_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)             r_wr_addr <= 0;
        else if (w_wr_addr_rst)  r_wr_addr <= 0;
        else if (w_active_wr_pulse) r_wr_addr <= r_wr_addr + 1'b1;
    end

    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_uram_L1
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
        for (b = 0; b < 2; b = b + 1) begin : gen_uram_L2
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L2 (
                .clk      (i_clk),
                .wr_en    ((w_layer_cnt == 2'd1) && (w_out_ch_cnt == b[0]) && w_pack_we[0]),
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
    // FIFOs (L1->L2 4개, L2->L3 2개)
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
    // PU 입력 라우팅 (layer 별)
    //   L1: input BRAM (pad mux 통해), ch_data slot 0 (= bits[63:48]) 만 의미.
    //       PU 내부에서 ch0 을 4 line_buffer 에 broadcast 함.
    //   L2: 4 FIFO (L1->L2) 의 출력 4 채널 packed.
    //   L3: 2 FIFO (L2->L3) 의 출력 2 채널 packed (slot 0,1).
    // ------------------------------------------------------------------
    wire signed [15:0] w_L1_in_data  = w_is_pad_valid ? 16'sd0 : w_i_dout;
    wire               w_L1_in_valid = w_is_pad_valid ? 1'b1   : w_i_rd_valid;

    wire [4*16-1:0] w_pu_ch_data =
        (w_layer_cnt == 2'd0) ? {w_L1_in_data, 48'd0} :
        (w_layer_cnt == 2'd1) ? {w_fifo_L1_dout[0], w_fifo_L1_dout[1],
                                  w_fifo_L1_dout[2], w_fifo_L1_dout[3]} :
                                 {w_fifo_L2_dout[0], w_fifo_L2_dout[1], 32'd0};

    wire w_pu_input_valid =
        (w_layer_cnt == 2'd0) ? w_L1_in_valid :
                                w_fifo_valid;

    // ------------------------------------------------------------------
    // 단일 PU 인스턴스
    // ------------------------------------------------------------------
    PU u_pu (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (w_IDLE_rst),
        .i_dispatch_rst (w_dispatch_rst),
        .i_layer_cnt    (w_layer_cnt),
        .i_out_ch_cnt   (w_out_ch_cnt),
        .i_input_valid  (w_pu_input_valid),
        .i_ch_data      (w_pu_ch_data),
        .i_is_pad_valid (w_is_pad_valid),
        .i_w_rd_valid   (w_w_rd_valid),
        .i_w_word       (w_w_dout),
        .i_bias_en      (w_bias_en),
        .o_pixel_valid  (w_pu_pixel_valid),
        .o_pixel_data   (w_pu_pixel_data),
        .o_img_done     (w_pu_img_done)
    );

    // ------------------------------------------------------------------
    // 4 packer
    //   L1: 각 packer[g] 가 PU 출력 slot g 를 받음. 모두 동일 valid.
    //   L2/L3: packer[0] 만 PU 출력 slot 0 받음. packer[1..3] 비활성.
    // ------------------------------------------------------------------
    wire w_packer_en_layer1plus = (w_layer_cnt != 2'd0);

    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_pack
            wire en_b = (b == 0) ? w_pu_pixel_valid
                                 : (w_pu_pixel_valid && (w_layer_cnt == 2'd0));
            wire signed [15:0] data_b = w_pu_pixel_data[16*((4-1)-b) +: 16];
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

    // ------------------------------------------------------------------
    // 최종 출력 (L3 stream)
    // ------------------------------------------------------------------
    assign o_pixel_valid = (w_layer_cnt == 2'd2) ? w_pu_pixel_valid : 1'b0;
    assign o_pixel_data  = w_pu_pixel_data[48 +: 16];
endmodule
