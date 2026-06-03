`timescale 1ns / 1ps

module FSM_pad #(
    parameter WEIGHT_SIZE     = 9,
    parameter PAD             = 1,
    parameter O_NUM           = 150,
    parameter I_NUM           = O_NUM + 2*PAD,
    parameter LB_LINE         = 3,
    parameter INIT_INPUT_SIZE = I_NUM * LB_LINE,
    parameter SHIFT_ROW       = 150,
    parameter I_TOTAL         = I_NUM * I_NUM,
    parameter MEM_ADDR_WIDTH  = 15,
    parameter CNT_WIDTH       = $clog2(I_NUM)
)(
    input                               i_clk,
    input                               i_rstn,
    input                               i_start,
    input                               i_line_rd_done,
    input                               i_adder_done,
    input                               i_uram_we,

    // Weight BRAM
    output reg                          o_weight_bram_rd_en,
    output reg [MEM_ADDR_WIDTH - 1:0]   o_weight_bram_rd_addr,
    output reg                          o_bias_en,

    // L1 Input BRAM / L2 intermid URAM read
    output reg                          o_input_bram_rd_en,
    output reg [MEM_ADDR_WIDTH - 1:0]   o_input_bram_rd_addr,

    output reg                          o_IDLE_rst,

    // Intermediate URAM
    output reg                          o_intermid_uram_rd_en,
    output reg [MEM_ADDR_WIDTH - 3:0]   o_intermid_uram_rd_addr,

    // FIFO Read Enable
    output reg                          fifo_rd_en,

    output reg                          o_input_bram_rd_line_done,
    output reg                          o_is_pad,
    output reg                          o_is_pad_valid,
    output reg                          o_line_done,
    output reg                          o_line_shift_en,
    output reg                          o_done,

    // ★ exposed for L2_top: which out_ch's pixel is currently being produced
    output wire [1:0]                   o_out_ch_cnt
);

localparam S_IDLE     = 2'd0;
localparam S_W_READ   = 2'd1;
localparam S_I_STREAM = 2'd2;
localparam S_DONE     = 2'd3;

reg [1:0] r_ps, r_ns;

reg [1:0] layer_cnt;
reg [1:0] out_ch_cnt;
reg [1:0] uram_en_cnt;

reg [MEM_ADDR_WIDTH-1:0] r_cnt;
reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;

reg [CNT_WIDTH-1:0] r_pad_row;
reg [CNT_WIDTH-1:0] r_pad_col;
reg [1:0] r_wgap_cnt;
reg [4:0] r_word_idx;
reg       r_bias_pre;

wire w_pad_area;
wire w_valid_pad_area;

assign o_out_ch_cnt = out_ch_cnt;

// 레이어별 파라미터 LUT (L2 고정값)
reg [2:0]                lut_out_ch;
reg [4:0]                lut_w_words;
reg [MEM_ADDR_WIDTH-1:0] lut_w_base;
reg [1:0]                lut_sub_max;
reg [MEM_ADDR_WIDTH-1:0] lut_oc_stride;
reg [1:0]                lut_word_stride;

always @(*) begin
    // L2 fixed: 8 in_ch -> 4 out_ch
    lut_out_ch      = 3'd4;
    lut_w_words     = 5'd19;
    lut_sub_max     = 2'd1;
    lut_oc_stride   = 'd19;
    lut_word_stride = 2'd1;
end

assign w_pad_area = (
        (r_pad_row == 0)          ||
        (r_pad_row == I_NUM - 1)  ||
        (r_pad_col == 0)          ||
        (r_pad_col == I_NUM - 1)
        );

assign w_valid_pad_area = (r_ps == S_I_STREAM) ? w_pad_area : 1'b0;

always @(posedge i_clk or negedge i_rstn) begin
    if(!i_rstn) r_ps <= S_IDLE;
    else        r_ps <= r_ns;
end

always @(*) begin
    r_ns = r_ps;
    case(r_ps)
        S_IDLE :
            if(i_start || (out_ch_cnt != 2'd0))
                r_ns = S_W_READ;
        S_W_READ :
            if(r_word_idx >= lut_w_words)
                r_ns = S_I_STREAM;
        S_I_STREAM :
            if((r_pad_row == I_NUM - 1) && (r_pad_col == I_NUM - 1))
                r_ns = S_DONE;
        S_DONE :
            if(o_done)
                r_ns = S_IDLE;
            else
                r_ns = S_DONE;
        default :
            r_ns = S_IDLE;
    endcase
end

always @(posedge i_clk or negedge i_rstn) begin
    if(!i_rstn) begin
        r_cnt                       <= 0;
        r_bram_addr                 <= 0;
        r_pad_row                   <= 0;
        r_pad_col                   <= 0;
        layer_cnt                   <= 0;
        out_ch_cnt                  <= 0;
        uram_en_cnt                 <= 0;
        r_wgap_cnt                  <= 0;
        r_word_idx                  <= 0;
        r_bias_pre                  <= 0;
        o_weight_bram_rd_en         <= 0;
        o_weight_bram_rd_addr       <= 0;
        o_bias_en                   <= 0;
        o_input_bram_rd_en          <= 0;
        o_input_bram_rd_addr        <= 0;
        o_intermid_uram_rd_en       <= 0;
        o_intermid_uram_rd_addr     <= 0;
        fifo_rd_en                  <= 0;
        o_input_bram_rd_line_done   <= 0;
        o_line_shift_en             <= 0;
        o_is_pad                    <= 0;
        o_is_pad_valid              <= 0;
        o_line_done                 <= 0;
        o_done                      <= 0;
    end
    else begin
        o_is_pad_valid              <= o_is_pad;
        o_weight_bram_rd_en         <= 0;
        o_input_bram_rd_en          <= 0;
        o_intermid_uram_rd_en       <= 0;
        fifo_rd_en                  <= 0;
        o_input_bram_rd_line_done   <= 0;
        o_line_shift_en             <= 0;
        o_line_done                 <= o_input_bram_rd_line_done;
        o_is_pad                    <= w_valid_pad_area;

        o_bias_en                   <= r_bias_pre;
        r_bias_pre                  <= 1'b0;

        case(r_ps)
            S_IDLE : begin
                r_cnt                     <= 0;
                r_bram_addr               <= 0;
                r_pad_row                 <= 0;
                r_pad_col                 <= 0;
                uram_en_cnt               <= 0;
                r_wgap_cnt                <= 0;
                r_word_idx                <= 0;
                o_IDLE_rst                <= 0;
                o_done                    <= 0;
                if (i_start) begin
                    out_ch_cnt <= 0;
                end
            end

            S_W_READ : begin
                if (r_word_idx >= lut_w_words) begin
                    r_cnt      <= 0;
                    r_word_idx <= 0;
                    r_wgap_cnt <= 0;
                end else begin
                   if (r_wgap_cnt == 2'd0) begin
                        o_weight_bram_rd_en   <= 1'b1;
                        o_weight_bram_rd_addr <= lut_w_base
                                               + (out_ch_cnt * lut_oc_stride)
                                               + (r_word_idx * lut_word_stride);
                        if (r_word_idx == lut_w_words - 1) begin
                            r_bias_pre <= 1'b1;
                        end
                        r_word_idx            <= r_word_idx + 1;
                        r_wgap_cnt            <= lut_sub_max - 1;
                    end else begin
                        r_wgap_cnt            <= r_wgap_cnt - 1;
                    end
                end
            end

            S_I_STREAM : begin
                if(r_pad_col == I_NUM - 1) begin
                    r_pad_col <= 0;
                    r_pad_row <= r_pad_row + 1;
                end else begin
                    r_pad_col <= r_pad_col + 1;
                end

                if(!w_valid_pad_area) begin
                    o_input_bram_rd_en   <= 1;
                    o_input_bram_rd_addr <= r_bram_addr;
                    r_bram_addr <= r_bram_addr + 1'b1;
                end
            end

            S_DONE : begin
                if(o_done) begin
                    o_done         <= 0;
                    o_IDLE_rst     <= 1'b1;

                    r_bram_addr <= 0;
                    uram_en_cnt <= 0;
                    r_pad_row   <= 0;
                    r_pad_col   <= 0;

                    if (out_ch_cnt < lut_out_ch - 1) begin
                        out_ch_cnt <= out_ch_cnt + 1;
                    end else begin
                        out_ch_cnt <= 0;
                    end
                end else begin
                    if(i_adder_done) begin
                        o_done <= 1'b1;
                    end
                end
            end
        endcase
    end
end

endmodule
