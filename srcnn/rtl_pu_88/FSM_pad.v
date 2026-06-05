`timescale 1ns / 1ps
// FSM_pad (preset 8_8) : 3-image 연속 + L1/L2/L3 순환 + per-layer/oc weight 재로드.
//
//   Weight BRAM 레이아웃 (128bit × 93 word):
//     L1:  addr  0.. 8 (weights), 9 (bias)
//     L2:  oc=k(0..7) → addr (10 + k*9)..(18 + k*9) (weights)
//          L2 bias  → addr 82, oc=0 시작 직전에 한 번만 load
//     L3:  addr 83..91 (weights), 92 (bias)
//
//   Input BRAM addr = img_cnt * 22500 + r_bram_addr.
//   img 한 장 완료 (L3 끝) -> o_img_done 1-clk pulse, img_cnt++.
//   3 장 완료 -> o_all_done = 1 (latched until reset).
module FSM_pad #(
    parameter PAD             = 1,
    parameter I_NUM           = 152,
    parameter O_NUM           = 150,
    parameter NPIX_IMG        = 22500,
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

    reg [1:0] r_layer_cnt;
    reg [2:0] r_out_ch_cnt;     // 0..7 (L2)
    reg [1:0] r_img_cnt;
    reg [1:0] r_uram_en_cnt;
    reg       r_bias_pre;
    reg [4:0] r_word_idx;
    reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;
    reg [CNT_WIDTH-1:0] r_pad_row;
    reg [CNT_WIDTH-1:0] r_pad_col;

    assign o_layer_cnt  = r_layer_cnt;
    assign o_out_ch_cnt = r_out_ch_cnt;
    assign o_img_cnt    = r_img_cnt;

    // ------------------------------------------------------------------
    // per-(layer, out_ch_cnt) weight 영역 LUT
    //   n_w   : weight word 갯수 (모두 9)
    //   has_bias / bias_addr : 해당 layer-oc 가 bias word 도 끌어와야 하는지
    //     L1, L2(oc=0), L3 만 has_bias=1
    // ------------------------------------------------------------------
    reg [MEM_ADDR_WIDTH-1:0] lut_w_base;
    reg [MEM_ADDR_WIDTH-1:0] lut_bias_addr;
    reg                      lut_has_bias;

    localparam [4:0] N_W = 5'd9;
    // total words to fetch in S_W_READ for current (layer, oc)
    wire [4:0] w_total_words = N_W + (lut_has_bias ? 5'd1 : 5'd0);

    always @(*) begin
        case (r_layer_cnt)
            2'd0: begin // L1
                lut_w_base    = 17'd0;
                lut_bias_addr = 17'd9;
                lut_has_bias  = 1'b1;
            end
            2'd1: begin // L2: oc-block
                lut_w_base    = 17'd10 + (r_out_ch_cnt * 17'd9);
                lut_bias_addr = 17'd82;
                lut_has_bias  = (r_out_ch_cnt == 3'd0);
            end
            2'd2: begin // L3
                lut_w_base    = 17'd83;
                lut_bias_addr = 17'd92;
                lut_has_bias  = 1'b1;
            end
            default: begin
                lut_w_base    = 0;
                lut_bias_addr = 0;
                lut_has_bias  = 0;
            end
        endcase
    end

    // L2 의 마지막 oc 인가
    wire w_last_out_ch = (r_layer_cnt == 2'd1) ? (r_out_ch_cnt == 3'd7) : 1'b1;
    wire w_last_layer  = (r_layer_cnt == 2'd2);

    wire w_pad_area = (
            (r_pad_row == 0)        ||
            (r_pad_row == I_NUM-1)  ||
            (r_pad_col == 0)        ||
            (r_pad_col == I_NUM-1));
    wire w_valid_pad_area = (r_ps == S_I_STREAM) ? w_pad_area : 1'b0;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) r_ps <= S_IDLE;
        else         r_ps <= r_ns;
    end

    wire w_more_work = (r_layer_cnt != 2'd0) || (r_out_ch_cnt != 3'd0) || (r_img_cnt != 2'd0);
    always @(*) begin
        r_ns = r_ps;
        case (r_ps)
            S_IDLE :
                if (!o_all_done && (i_start || w_more_work))
                    r_ns = S_W_READ;
            S_W_READ :
                if (r_word_idx >= w_total_words) r_ns = S_I_STREAM;
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

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_bram_addr             <= 0;
            r_pad_row               <= 0;
            r_pad_col               <= 0;
            r_layer_cnt             <= 0;
            r_out_ch_cnt            <= 0;
            r_img_cnt               <= 0;
            r_uram_en_cnt           <= 0;
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

            o_bias_en  <= r_bias_pre;
            r_bias_pre <= 1'b0;

            case (r_ps)
                S_IDLE : begin
                    r_bram_addr   <= 0;
                    r_pad_row     <= 0;
                    r_pad_col     <= 0;
                    r_uram_en_cnt <= 0;
                    r_word_idx    <= 0;
                    o_IDLE_rst    <= 0;
                end

                S_W_READ : begin
                    if (r_word_idx < w_total_words) begin
                        o_w_rd_en <= 1'b1;
                        if (r_word_idx < N_W) begin
                            o_w_rd_addr <= lut_w_base + r_word_idx;
                        end else begin
                            // bias word
                            o_w_rd_addr <= lut_bias_addr;
                            r_bias_pre  <= 1'b1;
                        end
                        if (r_word_idx == 5'd0) begin
                            o_wr_addr_rst <= 1'b1;
                            if (r_layer_cnt != 2'd0) begin
                                o_intermid_uram_rd_en   <= 1'b1;
                                o_intermid_uram_rd_addr <= {(MEM_ADDR_WIDTH-2){1'b0}};
                            end
                        end
                        r_word_idx <= r_word_idx + 5'd1;
                    end
                end

                S_I_STREAM : begin
                    if (r_pad_col == I_NUM-1) begin
                        r_pad_col <= 0;
                        r_pad_row <= r_pad_row + 1'b1;
                    end else begin
                        r_pad_col <= r_pad_col + 1'b1;
                    end

                    if (!w_valid_pad_area) begin
                        if (r_layer_cnt == 2'd0) begin
                            o_i_rd_en   <= 1'b1;
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
                        o_IDLE_rst     <= 1'b1;
                        o_dispatch_rst <= 1'b1;
                        r_bram_addr    <= 0;
                        r_uram_en_cnt  <= 0;
                        r_pad_row      <= 0;
                        r_pad_col      <= 0;
                        r_word_idx     <= 0;

                        if (!w_last_out_ch) begin
                            r_out_ch_cnt <= r_out_ch_cnt + 3'd1;
                        end else if (!w_last_layer) begin
                            r_out_ch_cnt <= 3'd0;
                            r_layer_cnt  <= r_layer_cnt + 2'd1;
                        end else begin
                            o_img_done   <= 1'b1;
                            r_out_ch_cnt <= 3'd0;
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
