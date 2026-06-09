`timescale 1ns / 1ps

// L3 local FSM (streamline)
//  - L3: in_ch=4, out_ch=1 -> out_ch loop 없음, 1 iter/image
//  - Weight BRAM 10 word: 9 weight (1 word/tap) + 1 bias
//  - bias_en: 마지막 word(idx=9)에서 1clk delay로 pulse (BRAM dout 정렬)
//  - Padding: L3_top에서 원본 intermid2_3 URAM 150x150 valid만 읽고
//    쪽마다 zero 주입 없이 PU 안에서 is_pad_valid로 mux.

module L3_local_FSM #(
    parameter PAD             = 1,
    parameter O_NUM           = 150,
    parameter I_NUM           = O_NUM + 2*PAD,
    parameter MEM_ADDR_WIDTH  = 15,
    parameter CNT_WIDTH       = $clog2(I_NUM),
    parameter W_TOTAL         = 10   // 9 weight + 1 bias
)(
    input                               i_clk,
    input                               i_rstn,
    input                               i_start,
    input                               i_adder_done,

    // Weight BRAM
    output reg                          o_weight_bram_rd_en,
    output reg [MEM_ADDR_WIDTH - 1:0]   o_weight_bram_rd_addr,
    output reg                          o_bias_en,

    // intermid2_3 URAM read (drives L2_top's R-port)
    output reg                          o_input_bram_rd_en,
    output reg [MEM_ADDR_WIDTH - 1:0]   o_input_bram_rd_addr,

    // Padding control to PU
    output reg                          o_is_pad,
    output reg                          o_is_pad_valid,

    output reg                          o_IDLE_rst,
    output reg                          o_done
);

localparam S_IDLE     = 2'd0;
localparam S_W_READ   = 2'd1;
localparam S_I_STREAM = 2'd2;
localparam S_DONE     = 2'd3;

reg [1:0] r_ps, r_ns;

reg [MEM_ADDR_WIDTH-1:0] r_bram_addr;
reg [CNT_WIDTH-1:0]      r_pad_row;
reg [CNT_WIDTH-1:0]      r_pad_col;
reg [4:0]                r_word_idx;
reg                      r_bias_pre;

wire w_pad_area;
wire w_valid_pad_area;

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
            if(i_start) r_ns = S_W_READ;
        S_W_READ :
            if(r_word_idx >= W_TOTAL) r_ns = S_I_STREAM;
        S_I_STREAM :
            if((r_pad_row == I_NUM - 1) && (r_pad_col == I_NUM - 1))
                r_ns = S_DONE;
        S_DONE :
            if(o_done) r_ns = S_IDLE;
        default :
            r_ns = S_IDLE;
    endcase
end

always @(posedge i_clk or negedge i_rstn) begin
    if(!i_rstn) begin
        r_bram_addr             <= 0;
        r_pad_row               <= 0;
        r_pad_col               <= 0;
        r_word_idx              <= 0;
        r_bias_pre              <= 0;
        o_weight_bram_rd_en     <= 0;
        o_weight_bram_rd_addr   <= 0;
        o_bias_en               <= 0;
        o_input_bram_rd_en      <= 0;
        o_input_bram_rd_addr    <= 0;
        o_IDLE_rst              <= 0;
        o_is_pad                <= 0;
        o_is_pad_valid          <= 0;
        o_done                  <= 0;
    end else begin
        o_is_pad_valid          <= w_valid_pad_area;
        o_is_pad                <= w_valid_pad_area;
        o_weight_bram_rd_en     <= 0;
        o_input_bram_rd_en      <= 0;

        // bias_en: BRAM dout 정렬용 1clk delay
        o_bias_en               <= r_bias_pre;
        r_bias_pre              <= 1'b0;

        case(r_ps)
            S_IDLE : begin
                r_bram_addr <= 0;
                r_pad_row   <= 0;
                r_pad_col   <= 0;
                r_word_idx  <= 0;
                o_IDLE_rst  <= 0;
                o_done      <= 0;
            end

            S_W_READ : begin
                if (r_word_idx < W_TOTAL) begin
                    o_weight_bram_rd_en   <= 1'b1;
                    o_weight_bram_rd_addr <= r_word_idx;
                    if (r_word_idx == W_TOTAL - 1) begin
                        r_bias_pre <= 1'b1;   // last word == bias
                    end
                    r_word_idx            <= r_word_idx + 1;
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
                    o_input_bram_rd_en   <= 1'b1;
                    o_input_bram_rd_addr <= r_bram_addr;
                    r_bram_addr          <= r_bram_addr + 1'b1;
                end
            end

            S_DONE : begin
                if(o_done) begin
                    o_done     <= 0;
                    o_IDLE_rst <= 1'b1;
                end else if(i_adder_done) begin
                    o_done <= 1'b1;
                end
            end
        endcase
    end
end

endmodule
