`timescale 1ns / 1ps
// FSM_pad (preset 8_8 unroll):
//   L1/L3: 8 px/clk (128b word, col_word 0..18, row 0..151)
//   L2:    1 px/clk, 8 out_ch 공간 병렬 (시분할 제거)
//   is_pad 제거 — 메모리에 사전 패딩된 152×152 저장
//
// Weight BRAM layout (128b × 93 word, baseline 동일):
//   L1: addr 0..8 (9 weights) + 9 (bias) = 10 words
//   L2: addr 10..81 (72 weights, 8oc×9tap) + 82 (bias) = 73 words
//   L3: addr 83..91 (9 weights) + 92 (bias) = 10 words
//
// Input BRAM: 128b × 8664 (3 img × 2888). addr = img*2888 + word_idx.
// URAM: 128b word. L2 read every 8 clk (dispatch 1px/clk via FIFO).
//                   L3 read every clk (direct 128b feed).
module FSM_pad #(
    parameter PAD             = 1,
    parameter I_NUM           = 152,
    parameter O_NUM           = 150,
    parameter WORDS_PER_ROW   = 19,
    parameter NPIX_IMG        = 2888,
    parameter MEM_ADDR_WIDTH  = 17,
    parameter CNT_WIDTH       = 8,
    parameter NUM_IMG         = 3
)(
    input                               i_clk,
    input                               i_rstn,
    input                               i_start,
    input                               i_line_img_done,
    input                               i_pe_done,
    input                               i_uram_we,

    output reg                          o_w_rd_en,
    output reg [MEM_ADDR_WIDTH-1:0]     o_w_rd_addr,
    output reg                          o_bias_en,

    output reg                          o_i_rd_en,
    output reg [MEM_ADDR_WIDTH-1:0]     o_i_rd_addr,

    output reg                          o_intermid_uram_rd_en,
    output reg [MEM_ADDR_WIDTH-3:0]     o_intermid_uram_rd_addr,

    output reg                          o_fifo_rd_en,

    output reg                          o_IDLE_rst,
    output reg                          o_dispatch_rst,
    output reg                          o_wr_addr_rst,
    output reg                          o_is_pad,
    output reg                          o_is_pad_valid,
    output reg                          o_line_done,

    output wire [1:0]                   o_layer_cnt,
    output wire [2:0]                   o_out_ch_cnt,
    output wire [1:0]                   o_img_cnt,
    output reg                          o_img_done,
    output reg                          o_all_done
);
    localparam S_IDLE     = 2'd0;
    localparam S_W_READ   = 2'd1;
    localparam S_I_STREAM = 2'd2;
    localparam S_DONE     = 2'd3;

    reg [1:0] r_ps, r_ns;

    reg [1:0]                r_layer_cnt;
    reg [1:0]                r_img_cnt;
    reg                      r_bias_pre;
    reg [6:0]                r_word_idx;
    reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;
    reg [CNT_WIDTH-1:0]      r_pad_row;
    reg [CNT_WIDTH-1:0]      r_col_cnt;
    reg [2:0]                r_uram_en_cnt;
    reg [MEM_ADDR_WIDTH-3:0] r_uram_addr;

    assign o_layer_cnt  = r_layer_cnt;
    assign o_out_ch_cnt = 3'd0;
    assign o_img_cnt    = r_img_cnt;

    // ------------------------------------------------------------------
    // weight LUT per layer
    // ------------------------------------------------------------------
    reg [MEM_ADDR_WIDTH-1:0] lut_w_base;
    reg [MEM_ADDR_WIDTH-1:0] lut_bias_addr;
    reg [6:0]                lut_n_w;

    always @(*) begin
        case (r_layer_cnt)
            2'd0:    begin lut_w_base = 0;  lut_n_w = 9;  lut_bias_addr = 9;  end
            2'd1:    begin lut_w_base = 10; lut_n_w = 72; lut_bias_addr = 82; end
            2'd2:    begin lut_w_base = 83; lut_n_w = 9;  lut_bias_addr = 92; end
            default: begin lut_w_base = 0;  lut_n_w = 0;  lut_bias_addr = 0;  end
        endcase
    end

    wire [6:0] w_total_words = lut_n_w + 7'd1;
    wire       w_last_layer  = (r_layer_cnt == 2'd2);

    // L1/L3: col_word wraps at 18, L2: col wraps at 151
    wire w_col_last = (r_layer_cnt == 2'd1)
                    ? (r_col_cnt == I_NUM - 1)
                    : (r_col_cnt == WORDS_PER_ROW - 1);

    // ------------------------------------------------------------------
    // state register
    // ------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) r_ps <= S_IDLE;
        else         r_ps <= r_ns;
    end

    wire w_more_work = (r_layer_cnt != 2'd0) || (r_img_cnt != 2'd0);

    always @(*) begin
        r_ns = r_ps;
        case (r_ps)
            S_IDLE:
                if (!o_all_done && (i_start || w_more_work))
                    r_ns = S_W_READ;
            S_W_READ:
                if (r_word_idx >= w_total_words)
                    r_ns = S_I_STREAM;
            S_I_STREAM:
                if ((r_pad_row == I_NUM - 1) && w_col_last)
                    r_ns = S_DONE;
            S_DONE:
                if (o_all_done)     r_ns = S_DONE;
                else if (i_pe_done) r_ns = S_IDLE;
            default: r_ns = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // main sequential
    // ------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_bram_addr             <= 0;
            r_pad_row               <= 0;
            r_col_cnt               <= 0;
            r_layer_cnt             <= 0;
            r_img_cnt               <= 0;
            r_uram_en_cnt           <= 0;
            r_uram_addr             <= 0;
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
            // defaults (pulse signals clear each cycle)
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

            o_bias_en  <= r_bias_pre;
            r_bias_pre <= 1'b0;

            case (r_ps)
                // ============================================
                S_IDLE: begin
                    r_bram_addr   <= 0;
                    r_pad_row     <= 0;
                    r_col_cnt     <= 0;
                    r_uram_en_cnt <= 0;
                    r_uram_addr   <= 0;
                    r_word_idx    <= 0;
                    o_IDLE_rst    <= 0;
                end

                // ============================================
                S_W_READ: begin
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
                            if (r_layer_cnt != 2'd0) begin
                                o_intermid_uram_rd_en   <= 1'b1;
                                o_intermid_uram_rd_addr <= {(MEM_ADDR_WIDTH-2){1'b0}};
                                r_uram_addr             <= 1;
                            end
                        end

                        r_word_idx <= r_word_idx + 7'd1;
                    end
                end

                // ============================================
                S_I_STREAM: begin
                    // column/row advance
                    if (w_col_last) begin
                        r_col_cnt <= 0;
                        r_pad_row <= r_pad_row + 1;
                    end else begin
                        r_col_cnt <= r_col_cnt + 1;
                    end

                    case (r_layer_cnt)
                        2'd0: begin // L1: input BRAM 128b read every clk
                            o_i_rd_en   <= 1'b1;
                            o_i_rd_addr <= r_img_cnt * NPIX_IMG + r_bram_addr;
                            r_bram_addr <= r_bram_addr + 1;
                        end

                        2'd1: begin // L2: FIFO dispatch 1 px/clk, URAM read every 8 clk
                            o_fifo_rd_en <= 1'b1;
                            if (r_uram_en_cnt == 3'd0) begin
                                o_intermid_uram_rd_en   <= 1'b1;
                                o_intermid_uram_rd_addr <= r_uram_addr;
                                r_uram_addr             <= r_uram_addr + 1;
                            end
                            r_uram_en_cnt <= r_uram_en_cnt + 3'd1;
                            r_bram_addr   <= r_bram_addr + 1;
                        end

                        2'd2: begin // L3: URAM read every clk, 128b direct feed
                            o_intermid_uram_rd_en   <= 1'b1;
                            o_intermid_uram_rd_addr <= r_uram_addr;
                            r_uram_addr             <= r_uram_addr + 1;
                            r_bram_addr             <= r_bram_addr + 1;
                        end

                        default: ;
                    endcase
                end

                // ============================================
                S_DONE: begin
                    if (i_pe_done) begin
                        o_IDLE_rst     <= 1'b1;
                        o_dispatch_rst <= 1'b1;
                        r_bram_addr    <= 0;
                        r_uram_en_cnt  <= 0;
                        r_uram_addr    <= 0;
                        r_pad_row      <= 0;
                        r_col_cnt      <= 0;
                        r_word_idx     <= 0;

                        if (!w_last_layer) begin
                            r_layer_cnt <= r_layer_cnt + 2'd1;
                        end else begin
                            o_img_done  <= 1'b1;
                            r_layer_cnt <= 2'd0;
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
