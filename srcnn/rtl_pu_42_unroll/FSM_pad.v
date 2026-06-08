`timescale 1ns / 1ps
// FSM_pad (preset 4_2 UNROLL, no L2 time-mux).
//
// Channel chain : 1 → 4 → 2 → 1. L2 OC는 공간 병렬 → out_ch_cnt 사용 안함.
//
// 단계별 시퀀스 (per layer) :
//   S_IDLE → S_W_READ → S_I_STREAM → S_DRAIN → S_DONE
//
//   S_W_READ   : weight 9 + bias 1 = 10 cycle 로딩.
//                L1 : addr 0..8 weight + 9  bias.
//                L2 : addr 10..18 weight + 19 bias.
//                L3 : addr 20..28 weight + 29 bias.
//   S_I_STREAM :
//                L1 : BRAM read 2888 cycle + 1 dummy.
//                L2 : URAM_L1 read 2888 cycle + 1 dummy (단일 pass).
//                L3 : URAM_L2 read every-other clk × 2888 reads = 5776 cycle.
//   S_DRAIN    : 30 cycle 대기 후 i_pe_done 수신.
//   S_DONE     : reset pulse 발생 → 다음 layer.
//
// Note : pad_top/bot 제거. URAM auto-init=0 이므로 row 0/151 은 항상 0.
//        top.v 에서 wr_addr 를 19 (WORDS_PER_ROW) 부터 시작시켜 row 1..150 만 기록.

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
    output reg                          o_input_dummy_valid,
    output reg                          o_pad_wr_en,         // always 0 (kept for compat)

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
    localparam S_I_STREAM = 3'd2;
    localparam S_DRAIN    = 3'd3;
    localparam S_DONE     = 3'd4;

    reg [2:0] r_ps, r_ns;

    reg [1:0]                r_layer_cnt;
    reg [2:0]                r_out_ch_cnt;
    reg [1:0]                r_img_cnt;
    reg                      r_bias_pre;
    reg [6:0]                r_word_idx;
    reg [CNT_WIDTH-1:0]      r_stream_cnt;
    reg [CNT_WIDTH-1:0]      r_drain_cnt;
    reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;
    reg [MEM_ADDR_WIDTH-3:0] r_uram_addr;
    reg                      r_l3_toggle;

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
            2'd1:    begin lut_w_base = 17'd10;
                           lut_n_w    = 7'd9;
                           lut_bias_addr = 17'd19; end
            2'd2:    begin lut_w_base = 17'd20;
                           lut_n_w    = 7'd9;
                           lut_bias_addr = 17'd29; end
            default: begin lut_w_base = 0; lut_n_w = 0; lut_bias_addr = 0; end
        endcase
    end

    wire [6:0] w_total_words = lut_n_w + 7'd1;
    wire       w_last_layer  = (r_layer_cnt == 2'd2);

    // stream length per layer
    localparam STREAM_L1_LEN = NPIX_IMG + 16'd2;    // 2890
    localparam STREAM_L2_LEN = NPIX_IMG + 16'd2;    // 2890
    localparam STREAM_L3_LEN = NPIX_IMG * 16'd2;    // 5776

    wire [CNT_WIDTH-1:0] w_stream_len =
        (r_layer_cnt == 2'd2) ? STREAM_L3_LEN :
        (r_layer_cnt == 2'd1) ? STREAM_L2_LEN : STREAM_L1_LEN;

    localparam DRAIN_LEN = 16'd30;

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
                    r_ns = S_I_STREAM;
            S_I_STREAM :
                if (r_stream_cnt >= w_stream_len - 1)
                    r_ns = S_DRAIN;
            S_DRAIN :
                if (i_pe_done)
                    r_ns = S_DONE;
            S_DONE :
                if (o_all_done) r_ns = S_DONE;
                else            r_ns = S_IDLE;
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
            o_pad_wr_en           <= 0;   // always 0

            o_bias_en  <= r_bias_pre;
            r_bias_pre <= 1'b0;

            case (r_ps)
                S_IDLE : begin
                    r_word_idx   <= 0;
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

                S_I_STREAM : begin
                    r_stream_cnt <= r_stream_cnt + 1'b1;

                    case (r_layer_cnt)
                        2'd0 : begin // L1 : BRAM read cnt 0..2887, dummy at cnt 2889.
                            if (r_stream_cnt < NPIX_IMG) begin
                                o_i_rd_en   <= 1'b1;
                                o_i_rd_addr <= r_img_cnt * NPIX_IMG + r_bram_addr;
                                r_bram_addr <= r_bram_addr + 1'b1;
                            end else if (r_stream_cnt == NPIX_IMG + 1) begin
                                o_input_dummy_valid <= 1'b1;
                            end
                        end

                        2'd1 : begin // L2 : URAM_L1 read cnt 0..2887, dummy at cnt 2889.
                            if (r_stream_cnt < NPIX_IMG) begin
                                o_intermid_uram_rd_en   <= 1'b1;
                                o_intermid_uram_rd_addr <= r_uram_addr;
                                r_uram_addr             <= r_uram_addr + 1'b1;
                            end else if (r_stream_cnt == NPIX_IMG + 1) begin
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

                S_DONE : begin
                    o_IDLE_rst     <= 1'b1;
                    o_dispatch_rst <= 1'b1;
                    r_word_idx     <= 0;
                    r_stream_cnt   <= 0;
                    r_drain_cnt    <= 0;
                    r_bram_addr    <= 0;
                    r_uram_addr    <= 0;
                    r_l3_toggle    <= 0;

                    if (!w_last_layer) begin
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
            endcase
        end
    end

endmodule
