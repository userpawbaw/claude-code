`timescale 1ns / 1ps
// FSM_pad (preset 8_8 UNROLL, rewrite for full unroll datapath).
//
// 단계별 시퀀스 (per layer / pass) :
//   S_IDLE → S_W_READ → S_PAD_TOP → S_I_STREAM → S_DRAIN → S_PAD_BOT → S_DONE
//
//   S_W_READ : weight 9 + bias 1 = 10 cycle 로딩.
//              L1 : addr 0..8 + 9    (oc 8 슬롯 동시)
//              L2 : addr 10+oc*9 .. + 8  + 82 (bias 공유)
//              L3 : addr 83..91 + 92
//   S_PAD_TOP : 19 cycle. o_pad_wr_en=1 → top.v 가 URAM_L1[..]/URAM_L2[oc] addr 0..18 에 0 write.
//   S_I_STREAM :
//              L1 : BRAM read 2888 cycle (addr base + 0..2887) + 1 dummy.
//              L2 : URAM_L1 read 2888 cycle + 1 dummy.
//              L3 : URAM_L2 read every-other clk × 2888 reads = 5776 cycle.
//                   매 URAM read 은 depacker (top.v) 가 upper/lower 64b 로 2 cycle 분할.
//   S_DRAIN : PU pipeline + line_buffer 까지 8~12 cycle 정도. 충분히 30 cycle 대기.
//   S_PAD_BOT : 19 cycle. addr 2869..2887 에 0 write.
//   S_DONE : i_pe_done (= delay_shift(6) of PU.o_img_done) 대기 → 다음 layer/pass.
//
// L2 시퀀스 : 8 oc 시분할 — 각 oc 마다 위 시퀀스 1 회. 다음 oc 으로 갈 때 weight 재 load
//             (lut_w_base = 10 + oc*9). bias 는 addr 82 마다.
//
// 출력 :
//   o_w_rd_en / o_w_rd_addr    : weight BRAM read.
//   o_bias_en                  : bias latch pulse (1 cycle, S_W_READ 의 bias slot).
//   o_i_rd_en / o_i_rd_addr    : input BRAM read (L1 만).
//   o_intermid_uram_rd_en /
//   o_intermid_uram_rd_addr    : URAM_L1 read (L2) / URAM_L2 read (L3).
//   o_input_dummy_valid        : (NEW) L1/L2 의 dummy cycle 또는 L3 의 toggle 사이 valid 신호.
//   o_pad_wr_en                : S_PAD_TOP / S_PAD_BOT 동안 1.
//   o_IDLE_rst / o_dispatch_rst / o_wr_addr_rst : reset pulse 신호.
//   o_layer_cnt / o_out_ch_cnt / o_img_cnt / o_img_done / o_all_done.

module FSM_pad #(
    parameter PAD            = 1,
    parameter I_NUM          = 152,
    parameter O_NUM          = 150,
    parameter WORDS_PER_ROW  = 19,
    parameter NPIX_IMG       = 2888,    // 152 × 19 padded image words
    parameter MEM_ADDR_WIDTH = 17,
    parameter CNT_WIDTH      = 16,
    parameter NUM_IMG        = 3
)(
    input                               i_clk,
    input                               i_rstn,
    input                               i_start,
    input                               i_line_img_done,  // unused
    input                               i_pe_done,
    input                               i_uram_we,        // unused (kept for compat)

    output reg                          o_w_rd_en,
    output reg [MEM_ADDR_WIDTH-1:0]     o_w_rd_addr,
    output reg                          o_bias_en,

    output reg                          o_i_rd_en,
    output reg [MEM_ADDR_WIDTH-1:0]     o_i_rd_addr,

    output reg                          o_intermid_uram_rd_en,
    output reg [MEM_ADDR_WIDTH-3:0]     o_intermid_uram_rd_addr,

    output reg                          o_fifo_rd_en,        // unused (kept for compat)
    output reg                          o_input_dummy_valid, // NEW: input_valid w/ zero data
    output reg                          o_pad_wr_en,         // NEW: URAM padding write enable

    output reg                          o_IDLE_rst,
    output reg                          o_dispatch_rst,
    output reg                          o_wr_addr_rst,
    output reg                          o_is_pad,            // unused
    output reg                          o_is_pad_valid,      // unused
    output reg                          o_line_done,         // unused

    output wire [1:0]                   o_layer_cnt,
    output wire [2:0]                   o_out_ch_cnt,
    output wire [1:0]                   o_img_cnt,
    output reg                          o_img_done,
    output reg                          o_all_done
);
    localparam S_IDLE     = 3'd0;
    localparam S_W_READ   = 3'd1;
    localparam S_PAD_TOP  = 3'd2;
    localparam S_I_STREAM = 3'd3;
    localparam S_DRAIN    = 3'd4;
    localparam S_PAD_BOT  = 3'd5;
    localparam S_DONE     = 3'd6;

    reg [2:0] r_ps, r_ns;

    reg [1:0]                r_layer_cnt;
    reg [2:0]                r_out_ch_cnt;
    reg [1:0]                r_img_cnt;
    reg                      r_bias_pre;
    reg [6:0]                r_word_idx;
    reg [CNT_WIDTH-1:0]      r_pad_cnt;
    reg [CNT_WIDTH-1:0]      r_stream_cnt;
    reg [CNT_WIDTH-1:0]      r_drain_cnt;
    reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;
    reg [MEM_ADDR_WIDTH-3:0] r_uram_addr;
    reg                      r_l3_toggle;       // for L3 every-other-clk URAM read

    assign o_layer_cnt  = r_layer_cnt;
    assign o_out_ch_cnt = r_out_ch_cnt;
    assign o_img_cnt    = r_img_cnt;

    // ------------------------------------------------------------------
    // weight LUT per layer / pass
    // ------------------------------------------------------------------
    reg [MEM_ADDR_WIDTH-1:0] lut_w_base;
    reg [MEM_ADDR_WIDTH-1:0] lut_bias_addr;
    reg [6:0]                lut_n_w;

    always @(*) begin
        case (r_layer_cnt)
            2'd0:    begin lut_w_base = 17'd0;
                           lut_n_w    = 7'd9;
                           lut_bias_addr = 17'd9;  end
            2'd1:    begin lut_w_base = 17'd10 + r_out_ch_cnt * 17'd9;
                           lut_n_w    = 7'd9;
                           lut_bias_addr = 17'd82; end
            2'd2:    begin lut_w_base = 17'd83;
                           lut_n_w    = 7'd9;
                           lut_bias_addr = 17'd92; end
            default: begin lut_w_base = 0; lut_n_w = 0; lut_bias_addr = 0; end
        endcase
    end

    wire [6:0] w_total_words = lut_n_w + 7'd1;
    wire       w_last_layer  = (r_layer_cnt == 2'd2);
    wire       w_last_oc     = (r_layer_cnt == 2'd1) && (r_out_ch_cnt == 3'd7);

    // stream length per layer
    localparam STREAM_L1_LEN = NPIX_IMG + 16'd1;    // 2888 + 1 dummy
    localparam STREAM_L2_LEN = NPIX_IMG + 16'd1;    // same
    localparam STREAM_L3_LEN = NPIX_IMG * 16'd2;    // 5776 (every-other-clk URAM read)

    wire [CNT_WIDTH-1:0] w_stream_len =
        (r_layer_cnt == 2'd2) ? STREAM_L3_LEN :
        (r_layer_cnt == 2'd1) ? STREAM_L2_LEN : STREAM_L1_LEN;

    localparam DRAIN_LEN  = 16'd30;
    localparam PAD_LEN_L1L2 = 16'd19;       // 19 col_words per row
    localparam PAD_LEN_L3   = 16'd0;        // L3 stores 150×150 unpadded; no URAM write here

    // ------------------------------------------------------------------
    // state register
    // ------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) r_ps <= S_IDLE;
        else         r_ps <= r_ns;
    end

    wire w_more_work = (r_layer_cnt != 2'd0)
                    || (r_out_ch_cnt != 3'd0)
                    || (r_img_cnt    != 2'd0);

    always @(*) begin
        r_ns = r_ps;
        case (r_ps)
            S_IDLE :
                if (!o_all_done && (i_start || w_more_work))
                    r_ns = S_W_READ;
            S_W_READ :
                if (r_word_idx >= w_total_words)
                    r_ns = S_PAD_TOP;
            S_PAD_TOP :
                if (r_pad_cnt == PAD_LEN_L1L2 - 1) begin
                    if (r_layer_cnt == 2'd2) r_ns = S_I_STREAM;   // L3 has no pad
                    else                     r_ns = S_I_STREAM;
                end else if (r_layer_cnt == 2'd2) begin
                    r_ns = S_I_STREAM;                            // skip pad for L3
                end
            S_I_STREAM :
                if (r_stream_cnt >= w_stream_len - 1)
                    r_ns = S_DRAIN;
            S_DRAIN :
                if (r_drain_cnt >= DRAIN_LEN - 1) begin
                    if (r_layer_cnt == 2'd2) r_ns = S_DONE;       // L3 : no bot pad
                    else                     r_ns = S_PAD_BOT;
                end
            S_PAD_BOT :
                if (r_pad_cnt == PAD_LEN_L1L2 - 1)
                    r_ns = S_DONE;
            S_DONE :
                if (o_all_done)     r_ns = S_DONE;
                else if (i_pe_done) r_ns = S_IDLE;
            default: r_ns = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // sequential : outputs + counters
    // ------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_layer_cnt             <= 0;
            r_out_ch_cnt            <= 0;
            r_img_cnt               <= 0;
            r_word_idx              <= 0;
            r_bias_pre              <= 0;
            r_pad_cnt               <= 0;
            r_stream_cnt            <= 0;
            r_drain_cnt             <= 0;
            r_bram_addr             <= 0;
            r_uram_addr             <= 0;
            r_l3_toggle             <= 0;
            o_w_rd_en               <= 0;
            o_w_rd_addr             <= 0;
            o_bias_en               <= 0;
            o_i_rd_en               <= 0;
            o_i_rd_addr             <= 0;
            o_intermid_uram_rd_en   <= 0;
            o_intermid_uram_rd_addr <= 0;
            o_fifo_rd_en            <= 0;
            o_input_dummy_valid     <= 0;
            o_pad_wr_en             <= 0;
            o_IDLE_rst              <= 0;
            o_dispatch_rst          <= 0;
            o_wr_addr_rst           <= 0;
            o_is_pad                <= 0;
            o_is_pad_valid          <= 0;
            o_line_done             <= 0;
            o_img_done              <= 0;
            o_all_done              <= 0;
        end else begin
            // pulse defaults
            o_w_rd_en             <= 0;
            o_i_rd_en             <= 0;
            o_intermid_uram_rd_en <= 0;
            o_fifo_rd_en          <= 0;
            o_dispatch_rst        <= 0;
            o_wr_addr_rst         <= 0;
            o_img_done            <= 0;
            o_line_done           <= 0;
            o_is_pad              <= 0;
            o_is_pad_valid        <= 0;
            o_input_dummy_valid   <= 0;
            o_pad_wr_en           <= 0;

            // bias_en : delayed by 1 cycle from r_bias_pre.
            o_bias_en  <= r_bias_pre;
            r_bias_pre <= 1'b0;

            case (r_ps)
                S_IDLE : begin
                    r_word_idx   <= 0;
                    r_pad_cnt    <= 0;
                    r_stream_cnt <= 0;
                    r_drain_cnt  <= 0;
                    r_bram_addr  <= 0;
                    r_uram_addr  <= 0;
                    r_l3_toggle  <= 0;
                    o_IDLE_rst   <= 0;
                end

                S_W_READ : begin
                    if (r_word_idx < w_total_words) begin
                        o_w_rd_en <= 1'b1;
                        if (r_word_idx < lut_n_w) begin
                            o_w_rd_addr <= lut_w_base + r_word_idx;
                        end else begin
                            o_w_rd_addr <= lut_bias_addr;
                            r_bias_pre  <= 1'b1;
                        end
                        if (r_word_idx == 7'd0) begin
                            o_wr_addr_rst <= 1'b1;
                        end
                        r_word_idx <= r_word_idx + 7'd1;
                    end
                end

                S_PAD_TOP : begin
                    if (r_layer_cnt == 2'd2) begin
                        r_pad_cnt <= 0;       // L3 skip
                    end else begin
                        o_pad_wr_en <= 1'b1;
                        if (r_pad_cnt == PAD_LEN_L1L2 - 1) r_pad_cnt <= 0;
                        else                                 r_pad_cnt <= r_pad_cnt + 1'b1;
                    end
                end

                S_I_STREAM : begin
                    r_stream_cnt <= r_stream_cnt + 1'b1;

                    case (r_layer_cnt)
                        2'd0 : begin // L1 : BRAM 128b read every clk.
                            if (r_stream_cnt < NPIX_IMG) begin
                                o_i_rd_en   <= 1'b1;
                                o_i_rd_addr <= r_img_cnt * NPIX_IMG + r_bram_addr;
                                r_bram_addr <= r_bram_addr + 1'b1;
                            end else begin
                                o_input_dummy_valid <= 1'b1;
                            end
                        end

                        2'd1 : begin // L2 : URAM_L1 read every clk × 8 banks parallel.
                            if (r_stream_cnt < NPIX_IMG) begin
                                o_intermid_uram_rd_en   <= 1'b1;
                                o_intermid_uram_rd_addr <= r_uram_addr;
                                r_uram_addr             <= r_uram_addr + 1'b1;
                            end else begin
                                o_input_dummy_valid <= 1'b1;
                            end
                        end

                        2'd2 : begin // L3 : URAM_L2 read every-other clk.
                            r_l3_toggle <= ~r_l3_toggle;
                            if (~r_l3_toggle && (r_uram_addr < NPIX_IMG)) begin
                                o_intermid_uram_rd_en   <= 1'b1;
                                o_intermid_uram_rd_addr <= r_uram_addr;
                                r_uram_addr             <= r_uram_addr + 1'b1;
                            end
                        end
                        default: ;
                    endcase
                end

                S_DRAIN : begin
                    r_drain_cnt <= r_drain_cnt + 1'b1;
                end

                S_PAD_BOT : begin
                    o_pad_wr_en <= 1'b1;
                    if (r_pad_cnt == PAD_LEN_L1L2 - 1) r_pad_cnt <= 0;
                    else                                 r_pad_cnt <= r_pad_cnt + 1'b1;
                end

                S_DONE : begin
                    if (i_pe_done) begin
                        o_IDLE_rst     <= 1'b1;
                        o_dispatch_rst <= 1'b1;
                        r_word_idx     <= 0;
                        r_pad_cnt      <= 0;
                        r_stream_cnt   <= 0;
                        r_drain_cnt    <= 0;
                        r_bram_addr    <= 0;
                        r_uram_addr    <= 0;
                        r_l3_toggle    <= 0;

                        if (r_layer_cnt == 2'd1 && !w_last_oc) begin
                            // next L2 pass : same layer, next oc.
                            r_out_ch_cnt <= r_out_ch_cnt + 1'b1;
                        end else if (!w_last_layer) begin
                            r_layer_cnt  <= r_layer_cnt + 2'd1;
                            r_out_ch_cnt <= 0;
                        end else begin
                            o_img_done   <= 1'b1;
                            r_layer_cnt  <= 2'd0;
                            r_out_ch_cnt <= 0;
                            if (r_img_cnt == NUM_IMG - 1) begin
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
