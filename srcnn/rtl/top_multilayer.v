`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : top_multilayer.v
// PURPOSE        : SRCNN_4_2_1 멀티레이어 통합 top.
//                  improved line_buffer / improved FSM (단일채널 흐름 검증 완료)
//                  위에 weight_dispatch + 병렬 pe_group/line_buffer/channel_accumulator
//                  + uram_bank(6뱅크 풀병렬) 를 통합한다.
// -----------------------------------------------------------------------------
// 데이터패스 (verification_notes.md 기준):
//   L1: input BRAM(16b) -> line_buffer[0] -> pe_group[0..3] (4 out_ch 동시)
//         -> 각 partial 정제(+ReLU 옵션) -> pack[0..3] -> uram_L1[0..3]
//   L2: uram_L1[0..3] -> fifo_L1[0..3] -> line_buffer[0..3] (4 in_ch 병렬)
//         -> pe_group[0..3] -> channel_accumulator(Σ4) -> pack -> uram_L2[oc]
//   L3: uram_L2[0..1] -> fifo_L2[0..1] -> line_buffer[0..1] (2 in_ch 병렬)
//         -> pe_group[0..1] -> channel_accumulator(Σ2) -> pack -> 최종 출력
//
// 회귀 안전성:
//   - L1(layer_cnt==0)에서 weight_dispatch 슬롯 순서는 기존 top 자체 카운터와 동치
//     (Python cycle 모델 검증). line_buffer[0]/pe_group[0] 경로는 improved 검증 그대로.
//   - weight BRAM 을 64bit width 로 사용 (weight.txt = 32 word, 64bit hex).
//
//   Reset Strategy : Asynchronous, active low (i_rstn)
// -FHDR------------------------------------------------------------------------

module top #(
    parameter USE_RELU    = 0,      // 1: 채널누적 출력 뒤 ReLU 적용, 0: conv-only
    parameter MEM_ADDR    = 15,
    parameter URAM_AW     = 13       // uram_bank ADDR_WIDTH
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,
    output wire        o_done,
    output wire        o_output_valid,
    output wire [63:0] o_output,
    output wire        o_line_rd_done
);

    // =========================================================================
    // FSM 신호
    // =========================================================================
    wire                       w_is_pad;
    wire                       w_is_pad_valid;
    wire                       w_input_rd_done;
    wire                       w_line_done;
    wire                       line_shift_en;       // (improved line_buffer 미사용, 호환 유지)

    wire                       w_IDLE_rst;
    wire [1:0]                 layer_cnt;
    wire [1:0]                 out_ch_cnt;
    wire                       w_dispatch_rst;
    wire                       w_wr_addr_rst;

    wire                       w_intermid_uram_rd_en;
    wire [MEM_ADDR-3:0]        w_intermid_uram_rd_addr;
    wire                       w_fifo_rd_en;

    // Weight BRAM (64bit)
    wire                       w_rd_en;
    wire [MEM_ADDR-1:0]        w_rd_addr;
    wire                       w_rd_valid;
    wire [63:0]                w_rd_dout;

    // Layer1 Input BRAM (16bit)
    wire                       i_rd_en;
    wire [MEM_ADDR-1:0]        i_rd_addr;
    wire                       i_rd_valid;
    wire signed [15:0]         i_rd_dout;

    // =========================================================================
    // weight_dispatch 출력 (4묶음 flatten)
    // =========================================================================
    localparam MAX_GROUP = 4;
    wire [16*MAX_GROUP-1:0]    w_disp_weight;   // [16*g +: 16]
    wire [9*MAX_GROUP-1:0]     w_disp_wen;      // [9*g  +: 9]

    // =========================================================================
    // 병렬 line_buffer 입력 (채널별 데이터/valid)
    //   L1: ch0만 사용(input BRAM). L2: 4ch(uram_L1). L3: 2ch(uram_L2).
    // =========================================================================
    wire signed [15:0]         w_lb_data  [0:3];
    wire                       w_lb_valid [0:3];

    // line_buffer 출력 (채널별 윈도우)
    wire [16*9-1:0]            line_data  [0:3];
    wire                       line_valid [0:3];
    wire                       line_rd_done [0:3];   // 채널 동시 -> [0] 대표 사용
    wire                       line_img_done [0:3];  // 프레임 완료 (검증본 신규)

    assign o_line_rd_done = line_rd_done[0];

    // =========================================================================
    // pe_group 출력 (채널별 partial sum)
    // =========================================================================
    wire                       pe_valid   [0:3];
    wire signed [20:0]         pe_partial [0:3];
    wire                       pe_done    [0:3];

    // =========================================================================
    // channel_accumulator 출력 (L2/L3 누적 경로)
    // =========================================================================
    wire                       ca_valid;
    wire signed [15:0]         ca_data;

    // L1 채널별 정제 출력 (누적 없음, 각 pe_group partial -> 16bit 정제)
    wire signed [15:0]         l1_refined [0:3];
    wire                       l1_refined_valid [0:3];

    // =========================================================================
    // pack writer 출력 (L1: 4개, L2/L3: 1개)
    // =========================================================================
    wire [63:0]                pack_L1_dout [0:3];
    wire                       pack_L1_we   [0:3];
    wire [63:0]                pack_main_dout;
    wire                       pack_main_we;

    // =========================================================================
    // URAM 6뱅크
    // =========================================================================
    wire [63:0]                uram_L1_dout [0:3];
    wire [63:0]                uram_L2_dout [0:1];

    // uram_bank 라우팅 출력
    wire [3:0]                 ub_L1_we;
    wire [URAM_AW-1:0]         ub_L1_wr_addr;
    wire [3:0]                 ub_L1_re;
    wire [URAM_AW-1:0]         ub_L1_rd_addr;
    wire [1:0]                 ub_L2_we;
    wire [URAM_AW-1:0]         ub_L2_wr_addr;
    wire [1:0]                 ub_L2_re;
    wire [URAM_AW-1:0]         ub_L2_rd_addr;
    wire                       ub_final_we;
    wire [URAM_AW-1:0]         ub_final_addr;

    // pack writer 공통 write 주소 (출력 픽셀 인덱스>>2)
    reg  [URAM_AW-1:0]         output_uram_addr;

    // layer 분기 write 펄스 (L1: pack_L1_we[0], L2/L3: pack_main_we)
    //   L1 에서는 channel_accumulator(pack_main) 가 padding valid 로 인해
    //   엉뚱하게 동작할 수 있으므로, layer_cnt 로 명확히 분기하여 사용한다.
    wire wr_pulse = (layer_cnt == 2'd0) ? pack_L1_we[0] : pack_main_we;

    // pe_done 지연: S_DONE 의 done 트리거를 마지막 pack write 완료 이후로 미뤄
    //   레이어 전환(라우팅/주소 리셋) 전에 마지막 출력 그룹이 보존되도록 한다.
    //   pe_done[0] = img_done+3clk (마지막 partial 시점) -> pack write 같은 clk.
    //   +2clk 지연으로 write 보존 마진 확보.
    wire w_pe_done_dly;
    delay_shift #(.WIDTH(1), .DELAY(2)) u_pe_done_dly (
        .clk (i_clk), .rst (~i_rstn), .en (1'b1),
        .din (pe_done[0]), .dout (w_pe_done_dly)
    );

    // =========================================================================
    // FIFO (L1->L2 4개, L2->L3 2개)
    // =========================================================================
    wire signed [15:0]         fifo_L1_dout [0:3];
    wire                       fifo_L1_valid [0:3];
    wire signed [15:0]         fifo_L2_dout [0:3];   // 0..1 사용, 2..3 더미
    wire                       fifo_L2_valid [0:3];
    assign fifo_L2_dout[2]  = 16'h0;
    assign fifo_L2_dout[3]  = 16'h0;
    assign fifo_L2_valid[2] = 1'b0;
    assign fifo_L2_valid[3] = 1'b0;

    // 최종 출력 연결
    assign o_output       = pack_main_dout;        // L3 경로
    assign o_output_valid = ub_final_we;

    // =========================================================================
    // 1. FSM Instance (improved)
    // =========================================================================
    FSM_pad #(
        .O_NUM(150),
        .MEM_ADDR_WIDTH(MEM_ADDR)
    ) fsm_0 (
        .i_clk                     (i_clk),
        .i_rstn                    (i_rstn),
        .i_start                   (i_start),
        .i_line_rd_done            (line_rd_done[0]),
        .i_adder_done              (w_pe_done_dly),
        .i_uram_we                 (wr_pulse),  // layer 분기 완료 트리거

        .o_layer_cnt               (layer_cnt),
        .o_out_ch_cnt              (out_ch_cnt),
        .o_weight_bram_rd_en       (w_rd_en),
        .o_weight_bram_rd_addr     (w_rd_addr),

        .o_input_bram_rd_en        (i_rd_en),
        .o_input_bram_rd_addr      (i_rd_addr),

        .o_IDLE_rst                (w_IDLE_rst),
        .o_dispatch_rst            (w_dispatch_rst),
        .o_wr_addr_rst             (w_wr_addr_rst),

        .o_intermid_uram_rd_en     (w_intermid_uram_rd_en),
        .o_intermid_uram_rd_addr   (w_intermid_uram_rd_addr),
        .fifo_rd_en                (w_fifo_rd_en),

        .o_input_bram_rd_line_done (w_input_rd_done),
        .o_is_pad                  (w_is_pad),
        .o_is_pad_valid            (w_is_pad_valid),
        .o_line_done               (w_line_done),
        .o_line_shift_en           (line_shift_en),
        .o_done                    (o_done)
    );

    // =========================================================================
    // 2. Weight BRAM (64bit) — weight.txt 32 word
    // =========================================================================
    simple_dual_port_bram #(
        .WIDTH(64),
        .DEPTH(32),
        .INIT_FILE("weight.txt")
    ) w_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (w_rd_en),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .rd_addr  (w_rd_addr),
        .wr_din   (64'h0),
        .rd_valid (w_rd_valid),
        .rd_dout  (w_rd_dout)
    );

    // =========================================================================
    // 3. Weight Dispatch — 64bit word -> 4묶음 9슬롯 분배
    // =========================================================================
    weight_dispatch #(
        .MAX_GROUP(MAX_GROUP)
    ) u_wdisp (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_dispatch_rst (w_dispatch_rst),
        .i_layer_cnt    (layer_cnt),
        .i_wword_valid  (w_rd_valid),
        .i_wword        (w_rd_dout),
        .o_weight       (w_disp_weight),
        .o_wen          (w_disp_wen)
    );

    // =========================================================================
    // 4. Layer1 Input BRAM (16bit)
    // =========================================================================
    simple_dual_port_bram #(
        .WIDTH(16),
        .DEPTH(150*150),
        .INIT_FILE("input.txt")
    ) i_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (i_rd_en),
        .wr_addr  ({MEM_ADDR{1'b0}}),
        .rd_addr  (i_rd_addr),
        .wr_din   (16'h0),
        .rd_valid (i_rd_valid),
        .rd_dout  (i_rd_dout)
    );

    // =========================================================================
    // 5. URAM 6뱅크 + uram_bank 라우팅
    // =========================================================================
    uram_bank #(
        .ADDR_WIDTH(URAM_AW)
    ) u_uram_bank (
        .i_layer_cnt  (layer_cnt),
        .i_out_ch_cnt (out_ch_cnt),
        .i_wr_en      (wr_pulse),
        .i_wr_addr    (output_uram_addr),
        .i_rd_en      (w_intermid_uram_rd_en),
        .i_rd_addr    (w_intermid_uram_rd_addr[URAM_AW-1:0]),
        .o_L1_we      (ub_L1_we),
        .o_L1_wr_addr (ub_L1_wr_addr),
        .o_L1_re      (ub_L1_re),
        .o_L1_rd_addr (ub_L1_rd_addr),
        .o_L2_we      (ub_L2_we),
        .o_L2_wr_addr (ub_L2_wr_addr),
        .o_L2_re      (ub_L2_re),
        .o_L2_rd_addr (ub_L2_rd_addr),
        .o_final_we   (ub_final_we),
        .o_final_addr (ub_final_addr)
    );

    genvar b;
    generate
        // uram_L1[0..3]
        for (b = 0; b < 4; b = b + 1) begin : gen_uram_L1
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L1 (
                .clk      (i_clk),
                .wr_en    (ub_L1_we[b] & pack_L1_we[b]),
                .wr_addr  (ub_L1_wr_addr),
                .wr_din   (pack_L1_dout[b]),
                .rd_en    (ub_L1_re[b]),
                .rd_addr  (ub_L1_rd_addr),
                .rd_valid (),
                .rd_dout  (uram_L1_dout[b])
            );
        end
        // uram_L2[0..1]
        for (b = 0; b < 2; b = b + 1) begin : gen_uram_L2
            simple_dual_port_uram #(
                .WIDTH(64), .DEPTH(8192), .INIT_FILE("")
            ) u_uram_L2 (
                .clk      (i_clk),
                .wr_en    (ub_L2_we[b] & pack_main_we),
                .wr_addr  (ub_L2_wr_addr),
                .wr_din   (pack_main_dout),
                .rd_en    (ub_L2_re[b]),
                .rd_addr  (ub_L2_rd_addr),
                .rd_valid (),
                .rd_dout  (uram_L2_dout[b])
            );
        end
    endgenerate

    // =========================================================================
    // 6. FIFO 6개 (L1->L2 4개, L2->L3 2개)
    //    64bit din -> 16bit dout (Standard FIFO, MSB-first 4분할).
    //    실제 IP 설정 Valid_Flag=false -> valid 포트 없음.
    //    모든 채널이 동일 w_fifo_rd_en 으로 read 되므로 valid 는 공통.
    //    rd_en -> 1clk 후 dout 유효 -> delay_shift(1) 로 valid 생성.
    // =========================================================================
    wire w_fifo_valid_common;
    delay_shift #(.WIDTH(1), .DELAY(1)) u_fifo_valid_gen (
        .clk (i_clk), .rst (~i_rstn), .en (1'b1),
        .din (w_fifo_rd_en), .dout (w_fifo_valid_common)
    );

    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_fifo_L1
            fifo_generator_0 u_fifo_L1 (
                .clk         (i_clk),
                .srst        (~i_rstn),
                .din         (uram_L1_dout[b]),
                .wr_en       (ub_L1_re[b]),
                .rd_en       (w_fifo_rd_en),
                .dout        (fifo_L1_dout[b]),
                .full        (),
                .empty       (),
                .wr_rst_busy (),
                .rd_rst_busy ()
            );
            assign fifo_L1_valid[b] = w_fifo_valid_common;
        end
        for (b = 0; b < 2; b = b + 1) begin : gen_fifo_L2
            fifo_generator_0 u_fifo_L2 (
                .clk         (i_clk),
                .srst        (~i_rstn),
                .din         (uram_L2_dout[b]),
                .wr_en       (ub_L2_re[b]),
                .rd_en       (w_fifo_rd_en),
                .dout        (fifo_L2_dout[b]),
                .full        (),
                .empty       (),
                .wr_rst_busy (),
                .rd_rst_busy ()
            );
            assign fifo_L2_valid[b] = w_fifo_valid_common;
        end
    endgenerate

    // =========================================================================
    // 7. line_buffer 입력 MUX (채널별)
    //    L1: ch0 <- input BRAM, ch1..3 미사용
    //    L2: ch0..3 <- fifo_L1[0..3]
    //    L3: ch0..1 <- fifo_L2[0..1], ch2..3 미사용
    //    padding 은 모든 채널 공통 (FSM o_is_pad_valid).
    // =========================================================================
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_lb_mux
            wire signed [15:0] ch_data;
            wire               ch_valid;

            // L1: 입력 1채널을 4묶음이 공유 (weight 만 out_ch별로 다름)
            //     -> 4채널 모두 input BRAM 데이터/valid 를 받는다.
            // L2: ch0..3 <- fifo_L1[0..3]
            // L3: ch0..1 <- fifo_L2[0..1], ch2..3 미사용
            assign ch_data  = (layer_cnt == 2'd0) ? i_rd_dout :
                              (layer_cnt == 2'd1) ? fifo_L1_dout[g] :
                              (g < 2)             ? fifo_L2_dout[g] : 16'h0;

            assign ch_valid = (layer_cnt == 2'd0) ? i_rd_valid :
                              (layer_cnt == 2'd1) ? fifo_L1_valid[g] :
                              (g < 2)             ? fifo_L2_valid[g] : 1'b0;

            // padding: is_pad_valid 면 0 데이터, valid=1
            assign w_lb_data[g]  = w_is_pad_valid ? 16'h0 : ch_data;
            assign w_lb_valid[g] = w_is_pad_valid ? 1'b1  : ch_valid;
        end
    endgenerate

    // =========================================================================
    // 8. line_buffer 병렬 인스턴스 (검증본: LSB-in 시프트, o_img_done)
    // =========================================================================
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_lb
            line_buffer_improved #(
                .IMG_WIDTH(152), .WIN_ROW(3), .WIN_COL(3), .DATA_BIT(16)
            ) u_lb (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (w_IDLE_rst),
                .i_input_valid  (w_lb_valid[g]),
                .i_input_data   (w_lb_data[g]),
                .o_line_data    (line_data[g]),
                .o_line_valid   (line_valid[g]),
                .o_line_rd_done (line_rd_done[g]),
                .o_img_done     (line_img_done[g])
            );
        end
    endgenerate

    // =========================================================================
    // 9. pe_group 병렬 인스턴스
    //    weight: weight_dispatch o_weight[16*g+:16], o_wen[9*g+:9]
    // =========================================================================
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_pe
            pe_group u_pe (
                .i_clk        (i_clk),
                .i_rstn       (i_rstn),
                .i_line_valid (line_valid[g]),
                .i_line_data  (line_data[g]),
                .i_weight     (w_disp_weight[16*g +: 16]),
                .i_wen        (w_disp_wen[9*g +: 9]),
                .i_line_done  (line_rd_done[g]),
                .i_line_img_done (line_img_done[g]),
                .o_valid      (pe_valid[g]),
                .o_partial    (pe_partial[g]),
                .o_pe_done    (pe_done[g])
            );
        end
    endgenerate

    // =========================================================================
    // 10. L1 채널별 정제 (누적 없음) — 각 pe_partial -> 16bit {sign,[14:0]}
    //     (+ReLU 옵션)
    // =========================================================================
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_l1_refine
            reg                r_v;
            reg signed [15:0]  r_d;
            wire signed [20:0] p = pe_partial[g];
            wire signed [15:0] refined = {p[20], p[14:0]};
            wire signed [15:0] relu_d  = (USE_RELU && refined[15]) ? 16'sd0 : refined;
            always @(posedge i_clk or negedge i_rstn) begin
                if (~i_rstn) begin r_v <= 0; r_d <= 0; end
                else begin r_v <= pe_valid[g]; r_d <= relu_d; end
            end
            assign l1_refined[g]       = r_d;
            assign l1_refined_valid[g] = r_v;
        end
    endgenerate

    // =========================================================================
    // 11. channel_accumulator (L2/L3 누적 경로)
    //     i_partial = {pe_partial[3],pe_partial[2],pe_partial[1],pe_partial[0]}
    //     i_active_ch = L2:4, L3:2
    // =========================================================================
    wire [2:0] active_ch = (layer_cnt==2'd1) ? 3'd4 :
                           (layer_cnt==2'd2) ? 3'd2 : 3'd1;

    wire [21*4-1:0] ca_partial_flat = { pe_partial[3], pe_partial[2],
                                        pe_partial[1], pe_partial[0] };

    channel_accumulator #(
        .MAX_CH(4)
    ) u_ca (
        .i_clk       (i_clk),
        .i_rstn      (i_rstn),
        .i_valid     (pe_valid[0]),
        .i_partial   (ca_partial_flat),
        .i_active_ch (active_ch),
        .o_valid     (ca_valid),
        .o_data      (ca_data)
    );

    // ReLU on accumulator output (L2/L3)
    wire signed [15:0] ca_relu = (USE_RELU && ca_data[15]) ? 16'sd0 : ca_data;

    // =========================================================================
    // 12. pack writer
    //     L1: 4개 (각 채널 독립) -> uram_L1[0..3]
    //     L2/L3: 1개 (누적 출력) -> uram_L2 / 최종
    // =========================================================================
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_pack_L1
            fifo_add_to_uram u_pack_L1 (
                .i_clk         (i_clk),
                .i_rstn        (i_rstn),
                .i_fifo_en     (l1_refined_valid[g]),
                .i_data        (l1_refined[g]),
                .o_output_uram (pack_L1_dout[g]),
                .o_uram_we     (pack_L1_we[g])
            );
        end
    endgenerate

    fifo_add_to_uram u_pack_main (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_fifo_en     (ca_valid),
        .i_data        (ca_relu),
        .o_output_uram (pack_main_dout),
        .o_uram_we     (pack_main_we)
    );

    // =========================================================================
    // 13. output_uram_addr 카운터 (pack write 시 증가, wr_addr_rst 시 0)
    //     L1: pack_L1_we[0] 기준 (4채널 동시라 같은 주소)
    //     L2/L3: pack_main_we 기준  (wr_pulse 로 상단에서 분기 선언)
    // =========================================================================
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            output_uram_addr <= {URAM_AW{1'b0}};
        end else if (w_wr_addr_rst) begin
            output_uram_addr <= {URAM_AW{1'b0}};
        end else if (wr_pulse) begin
            output_uram_addr <= output_uram_addr + 1'b1;
        end
    end

endmodule
