`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// L1 Local FSM (streamline)
//   - L1: in_ch = 1, out_ch = 8 (full-parallel out_ch, no time partitioning)
//   - Weight BRAM 20 words/iter: 18 weight + 2 bias (b0..b3 / b4..b7)
//   - L1_PU latches bias internally from i_w_rd_en + internal weight_addr,
//     so this FSM does NOT emit a separate o_bias_en.
//   - Padding: 150x150 valid image stored in BRAM; FSM synthesizes 152x152
//     padded stream by gating w_valid_pad_area (BRAM read suppressed on pad).
// -----------------------------------------------------------------------------

module L1_local_FSM #(
    parameter PAD             = 1,
    parameter O_NUM           = 150,
    parameter I_NUM           = O_NUM + 2*PAD,
    parameter MEM_ADDR_WIDTH  = 15,
    parameter CNT_WIDTH       = $clog2(I_NUM),
    parameter W_TOTAL         = 20    // 18 weight + 2 bias
)(
    input                               i_clk,
    input                               i_rstn,
    input                               i_start,         // from global FSM (image_cnt gated)
    input                               i_adder_done,    // L1_PU.o_pixel_valid for last pixel

    // Weight BRAM
    output reg                          o_weight_bram_rd_en,
    output reg [MEM_ADDR_WIDTH - 1:0]   o_weight_bram_rd_addr,

    // L1 Input BRAM (raw image, 150x150 valid storage)
    output reg                          o_input_bram_rd_en,
    output reg [MEM_ADDR_WIDTH - 1:0]   o_input_bram_rd_addr,

    // Padding control to L1_top mux
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

wire w_pad_area;
wire w_valid_pad_area;

assign w_pad_area = (
        (r_pad_row == 0)          ||
        (r_pad_row == I_NUM - 1)  ||
        (r_pad_col == 0)          ||
        (r_pad_col == I_NUM - 1)
        );

assign w_valid_pad_area = (r_ps == S_I_STREAM) ? w_pad_area : 1'b0;

// State Register
always @(posedge i_clk or negedge i_rstn) begin
    if(!i_rstn) r_ps <= S_IDLE;
    else        r_ps <= r_ns;
end

// Next State Logic
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

// Output & Counter Logic
always @(posedge i_clk or negedge i_rstn) begin
    if(!i_rstn) begin
        r_bram_addr             <= 0;
        r_pad_row               <= 0;
        r_pad_col               <= 0;
        r_word_idx              <= 0;
        o_weight_bram_rd_en     <= 0;
        o_weight_bram_rd_addr   <= 0;
        o_input_bram_rd_en      <= 0;
        o_input_bram_rd_addr    <= 0;
        o_IDLE_rst              <= 0;
        o_is_pad                <= 0;
        o_is_pad_valid          <= 0;
        o_done                  <= 0;
    end else begin
        // default clears + 1clk delayed pad valid
        o_is_pad_valid          <= o_is_pad;
        o_is_pad                <= w_valid_pad_area;
        o_weight_bram_rd_en     <= 0;
        o_input_bram_rd_en      <= 0;

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
                    r_word_idx            <= r_word_idx + 1;
                end
            end

            S_I_STREAM : begin
                // 2D raster counter (0,0 ~ 151,151)
                if(r_pad_col == I_NUM - 1) begin
                    r_pad_col <= 0;
                    r_pad_row <= r_pad_row + 1;
                end else begin
                    r_pad_col <= r_pad_col + 1;
                end

                // Read raw image BRAM only on valid (non-pad) pixels
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
