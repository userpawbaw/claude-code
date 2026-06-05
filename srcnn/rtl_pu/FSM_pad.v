`timescale 1ns / 1ps
// FSM_pad : 3-image 연속 처리 + L1/L2/L3 layer 순환 + per-layer weight 재로드.
//   Layer 별 weight BRAM 영역 (DESIGN.md):
//     L1: addr  0.. 9 (9 weight + 1 bias)
//     L2: addr 10..28 (oc-interleave stride=2; oc0=10,12..26+28bias; oc1=11,13..27)
//     L3: addr 29..34 (5 weight + 1 bias)
//   Input BRAM addr = img_cnt * 22500 + r_bram_addr (img 당 22500 word offset).
//   Padding 은 기존 방식 (150×150 저장, FSM 이 경계 cycle 삽입).
//
//   img 한 장 완료 (L3 끝) -> o_img_done 1-clk pulse, img_cnt++.
//   3 장 모두 끝 -> o_all_done = 1 (latched until reset).
module FSM_pad #(
    parameter PAD             = 1,
    parameter I_NUM           = 152,
    parameter O_NUM           = 150,
    parameter NPIX_IMG        = 22500,    // 150 * 150
    parameter MEM_ADDR_WIDTH  = 17,       // 67500 픽셀 = >16bit
    parameter CNT_WIDTH       = 8,
    parameter NUM_IMG         = 3
)(
    input                               i_clk,
    input                               i_rstn,
    input                               i_start,
    input                               i_line_img_done,   // line_buffer 의 o_img_done (pipeline 정렬 후 PE_pe_done 와 동치)
    input                               i_pe_done,         // L3_PU/L2_PU/L1_PU 의 o_pe_done (해당 layer 의 마지막 픽셀 write 완료 신호)
    input                               i_uram_we,         // 현재 layer 의 pack write pulse

    // weight BRAM (64bit, 35 word)
    output reg                          o_w_rd_en,
    output reg [MEM_ADDR_WIDTH-1:0]     o_w_rd_addr,
    output reg                          o_bias_en,         // 1-clk pulse (BRAM read 1clk 지연 정렬)

    // Layer1 Input BRAM (img-offset addressing)
    output reg                          o_i_rd_en,
    output reg [MEM_ADDR_WIDTH-1:0]     o_i_rd_addr,

    // Intermediate URAM
    output reg                          o_intermid_uram_rd_en,
    output reg [MEM_ADDR_WIDTH-3:0]     o_intermid_uram_rd_addr,

    // FIFO
    output reg                          o_fifo_rd_en,

    // line buffer / padding 제어
    output reg                          o_IDLE_rst,
    output reg                          o_dispatch_rst,
    output reg                          o_wr_addr_rst,
    output reg                          o_is_pad,
    output reg                          o_is_pad_valid,
    output reg                          o_line_done,

    // image / layer 컨트롤
    output wire [1:0]                   o_layer_cnt,
    output wire                         o_out_ch_cnt,
    output wire [1:0]                   o_img_cnt,
    output reg                          o_img_done,         // 1-clk pulse
    output reg                          o_all_done          // latched
);
    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    localparam S_IDLE     = 2'd0;
    localparam S_W_READ   = 2'd1;
    localparam S_I_STREAM = 2'd2;
    localparam S_DONE     = 2'd3;

    reg [1:0] r_ps, r_ns;

    reg [1:0] r_layer_cnt;
    reg       r_out_ch_cnt;
    reg [1:0] r_img_cnt;
    reg [1:0] r_uram_en_cnt;
    reg       r_bias_pre;
    reg [4:0] r_word_idx;
    reg [1:0] r_wgap_cnt;
    reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;     // intra-image input addr
    reg [CNT_WIDTH-1:0] r_pad_row;
    reg [CNT_WIDTH-1:0] r_pad_col;

    assign o_layer_cnt  = r_layer_cnt;
    assign o_out_ch_cnt = r_out_ch_cnt;
    assign o_img_cnt    = r_img_cnt;

    // ------------------------------------------------------------------
    // per-(layer, out_ch_cnt) weight 영역 LUT
    // ------------------------------------------------------------------
    reg [MEM_ADDR_WIDTH-1:0] lut_w_base;
    reg [4:0]                lut_w_words;      // weight 갯수 (bias 포함, bias 가 마지막 word)
    reg                      lut_has_bias;
    reg [1:0]                lut_sub_max;
    reg [1:0]                lut_word_stride;

    always @(*) begin
        case (r_layer_cnt)
            2'd0: begin // L1: 9 weight + 1 bias
                lut_w_base      = 17'd0;
                lut_w_words     = 5'd10;
                lut_has_bias    = 1'b1;
                lut_sub_max     = 2'd1;
                lut_word_stride = 2'd1;
            end
            2'd1: begin // L2
                lut_w_base      = (r_out_ch_cnt == 1'b0) ? 17'd10 : 17'd11;
                // oc0: 9 weight + 1 bias (addr 28). oc1: 9 weight only.
                lut_w_words     = (r_out_ch_cnt == 1'b0) ? 5'd10 : 5'd9;
                lut_has_bias    = (r_out_ch_cnt == 1'b0);
                lut_sub_max     = 2'd1;
                lut_word_stride = 2'd2;
            end
            2'd2: begin // L3: 5 weight + 1 bias
                lut_w_base      = 17'd29;
                lut_w_words     = 5'd6;
                lut_has_bias    = 1'b1;
                lut_sub_max     = 2'd2;
                lut_word_stride = 2'd1;
            end
            default: begin
                lut_w_base = 0; lut_w_words = 0; lut_has_bias = 0;
                lut_sub_max = 1; lut_word_stride = 1;
            end
        endcase
    end

    // 마지막 out_ch 인가 (L2 에서만 의미 있음, L1/L3 은 항상 0)
    wire w_last_out_ch = (r_layer_cnt == 2'd1) ? (r_out_ch_cnt == 1'b1) : 1'b1;
    // 마지막 layer 인가
    wire w_last_layer  = (r_layer_cnt == 2'd2);

    // pad 영역 판정
    wire w_pad_area = (
            (r_pad_row == 0)        ||
            (r_pad_row == I_NUM-1)  ||
            (r_pad_col == 0)        ||
            (r_pad_col == I_NUM-1));
    wire w_valid_pad_area = (r_ps == S_I_STREAM) ? w_pad_area : 1'b0;

    // ------------------------------------------------------------------
    // 1. State Register
    // ------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) r_ps <= S_IDLE;
        else         r_ps <= r_ns;
    end

    // ------------------------------------------------------------------
    // 2. Next State
    // ------------------------------------------------------------------
    wire w_more_work = (r_layer_cnt != 2'd0) || (r_out_ch_cnt != 1'b0) || (r_img_cnt != 2'd0);
    always @(*) begin
        r_ns = r_ps;
        case (r_ps)
            S_IDLE :
                if (!o_all_done && (i_start || w_more_work))
                    r_ns = S_W_READ;
            S_W_READ :
                if (r_word_idx >= lut_w_words) r_ns = S_I_STREAM;
            S_I_STREAM :
                if ((r_pad_row == I_NUM-1) && (r_pad_col == I_NUM-1))
                    r_ns = S_DONE;
            S_DONE :
                if (o_all_done)     r_ns = S_DONE;
                else if (i_pe_done) r_ns = S_IDLE;
                else                r_ns = S_DONE;
            default :
                r_ns = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // 3. Output / Counter
    // ------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_bram_addr             <= 0;
            r_pad_row               <= 0;
            r_pad_col               <= 0;
            r_layer_cnt             <= 0;
            r_out_ch_cnt            <= 0;
            r_img_cnt               <= 0;
            r_uram_en_cnt           <= 0;
            r_wgap_cnt              <= 0;
            r_word_idx              <= 0;
            r_bias_pre              <= 0;
            o_w_rd_en               <= 0;
            o_w_rd_addr             <= 0;
            o_bias_en               <= 0;
            o_i_rd_en               <= 0;
            o_i_rd_addr             <= 0;
            o_intermid_uram_rd_en   <= 0;
            o_intermid_uram_rd_addr <= 0;
            o_fifo_rd_en            <= 0;
            o_IDLE_rst              <= 0;
            o_dispatch_rst          <= 0;
            o_wr_addr_rst           <= 0;
            o_is_pad                <= 0;
            o_is_pad_valid          <= 0;
            o_line_done             <= 0;
            o_img_done              <= 0;
            o_all_done              <= 0;
        end else begin
            // 매 clk 기본 클리어 (펄스성)
            o_w_rd_en             <= 0;
            o_i_rd_en             <= 0;
            o_intermid_uram_rd_en <= 0;
            o_fifo_rd_en          <= 0;
            o_is_pad_valid        <= o_is_pad;
            o_is_pad              <= w_valid_pad_area;
            o_dispatch_rst        <= 0;
            o_wr_addr_rst         <= 0;
            o_img_done            <= 0;
            o_line_done           <= 0;

            // bias_en: r_bias_pre 가 1clk 후 BRAM dout 안착과 정렬됨
            o_bias_en  <= r_bias_pre;
            r_bias_pre <= 1'b0;

            case (r_ps)
                S_IDLE : begin
                    r_bram_addr   <= 0;
                    r_pad_row     <= 0;
                    r_pad_col     <= 0;
                    r_uram_en_cnt <= 0;
                    r_wgap_cnt    <= 0;
                    r_word_idx    <= 0;
                    o_IDLE_rst    <= 0;
                end

                S_W_READ : begin
                    if (r_word_idx < lut_w_words) begin
                        if (r_wgap_cnt == 2'd0) begin
                            o_w_rd_en   <= 1'b1;
                            o_w_rd_addr <= lut_w_base + (r_word_idx * lut_word_stride);
                            // 마지막 word == bias (lut_has_bias 인 경우만)
                            if (lut_has_bias && (r_word_idx == lut_w_words - 1)) begin
                                r_bias_pre <= 1'b1;
                            end
                            if (r_word_idx == 5'd0) begin
                                o_wr_addr_rst <= 1'b1;
                                // L2 oc1 시작 시 prefetch URAM word #0 (L1 reload 후 L2 input)
                                if (r_layer_cnt != 2'd0) begin
                                    o_intermid_uram_rd_en   <= 1'b1;
                                    o_intermid_uram_rd_addr <= {(MEM_ADDR_WIDTH-2){1'b0}};
                                end
                            end
                            r_word_idx <= r_word_idx + 5'd1;
                            r_wgap_cnt <= lut_sub_max - 2'd1;
                        end else begin
                            r_wgap_cnt <= r_wgap_cnt - 2'd1;
                        end
                    end
                end

                S_I_STREAM : begin
                    // 좌표
                    if (r_pad_col == I_NUM-1) begin
                        r_pad_col <= 0;
                        r_pad_row <= r_pad_row + 1'b1;
                    end else begin
                        r_pad_col <= r_pad_col + 1'b1;
                    end

                    // 유효영역 read
                    if (!w_valid_pad_area) begin
                        if (r_layer_cnt == 2'd0) begin
                            o_i_rd_en   <= 1'b1;
                            // img 당 22500 word offset
                            o_i_rd_addr <= r_img_cnt * NPIX_IMG + r_bram_addr;
                        end else begin
                            o_fifo_rd_en            <= 1'b1;
                            o_intermid_uram_rd_addr <= r_bram_addr[MEM_ADDR_WIDTH-1:2] + 1'b1;
                            if (r_uram_en_cnt == 2'b00) begin
                                o_intermid_uram_rd_en <= 1'b1;
                            end
                            r_uram_en_cnt <= r_uram_en_cnt + 1'b1;
                        end
                        r_bram_addr <= r_bram_addr + 1'b1;
                    end
                end

                S_DONE : begin
                    if (i_pe_done) begin
                        // 한 layer-oc 의 마지막 픽셀 write 완료. 다음 단계 결정.
                        o_IDLE_rst     <= 1'b1;
                        o_dispatch_rst <= 1'b1;
                        r_bram_addr    <= 0;
                        r_uram_en_cnt  <= 0;
                        r_pad_row      <= 0;
                        r_pad_col      <= 0;
                        r_word_idx     <= 0;

                        if (!w_last_out_ch) begin
                            // L2 의 oc0 → oc1
                            r_out_ch_cnt <= r_out_ch_cnt + 1'b1;
                        end else if (!w_last_layer) begin
                            // layer 진행 (L1 → L2 → L3)
                            r_out_ch_cnt <= 1'b0;
                            r_layer_cnt  <= r_layer_cnt + 2'd1;
                        end else begin
                            // 한 img 의 L3 까지 끝 → img_done
                            o_img_done   <= 1'b1;
                            r_out_ch_cnt <= 1'b0;
                            r_layer_cnt  <= 2'd0;
                            if (r_img_cnt == NUM_IMG-1) begin
                                o_all_done <= 1'b1;
                            end else begin
                                r_img_cnt <= r_img_cnt + 1'b1;
                            end
                        end
                    end
                end
            endcase
        end
    end
endmodule
