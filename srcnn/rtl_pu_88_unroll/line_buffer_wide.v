// line_buffer_wide.v — 8-pixel shift, 3×10 window line buffer for 8-px unroll.
//
// Input:  128-bit (8 px × 16-bit) per valid clock. MSB = lane 0 (leftmost col).
// Output: 480-bit window (3 rows × 10 cols × 16-bit). Same MSB convention.
//         After each shift, the 10-col window = {2 overlap from prev word, 8 new cols}.
//         From this, the PU extracts 8 overlapping 3×3 windows (lanes 0..7).
//
// Timing (same 2-clk pipeline as line_buffer_improved):
//   Clock N  : i_input_valid → shift register updates, counters update.
//   Clock N+1: r_valid captures. Window settles.
//   Clock N+2: o_line_valid asserts, o_line_data available.
//
// Valid condition: r_row >= 2 (all col_words valid from col_word 0).
//   Lane 6/7 of col_word 0 produce border/garbage → masked by packer.
//   See design doc for full analysis.

module line_buffer_wide #(
    parameter IMG_WIDTH    = 152,
    parameter WIN_ROW      = 3,
    parameter WIN_COL      = 10,
    parameter SHIFT_STEP   = 8,
    parameter DATA_BIT     = 16,

    parameter SHIFT_BITS   = SHIFT_STEP * DATA_BIT,        // 128
    parameter LINE_SIZE    = IMG_WIDTH * DATA_BIT,          // 2432
    parameter WIN_SIZE     = WIN_ROW * WIN_COL * DATA_BIT   // 480
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_input_valid,
    input  wire [SHIFT_BITS-1:0]      i_input_data,

    output reg  [WIN_SIZE-1:0]        o_line_data,
    output reg                        o_line_valid,
    output reg                        o_line_rd_done,
    output reg                        o_img_done
);

    localparam WORDS_PER_ROW = IMG_WIDTH / SHIFT_STEP;  // 19
    localparam WIN_BITS      = WIN_COL * DATA_BIT;       // 160

    // -----------------------------------------------------------------
    // 1. Shift registers (3 rows, 2432 bits each, 128-bit shift step)
    // -----------------------------------------------------------------
    (* shreg_extract = "yes" *) reg [LINE_SIZE-1:0] r_line0;
    (* shreg_extract = "yes" *) reg [LINE_SIZE-1:0] r_line1;
    (* shreg_extract = "yes" *) reg [LINE_SIZE-1:0] r_line2;

    always @(posedge i_clk) begin
        if (~i_rstn) begin
            r_line0 <= 0;
            r_line1 <= 0;
            r_line2 <= 0;
        end else if (i_IDLE_rst) begin
            r_line0 <= 0;
            r_line1 <= 0;
            r_line2 <= 0;
        end else if (i_input_valid) begin
            r_line0 <= {r_line0[LINE_SIZE-1-SHIFT_BITS:0], i_input_data};
            r_line1 <= {r_line1[LINE_SIZE-1-SHIFT_BITS:0], r_line0[LINE_SIZE-1 -: SHIFT_BITS]};
            r_line2 <= {r_line2[LINE_SIZE-1-SHIFT_BITS:0], r_line1[LINE_SIZE-1 -: SHIFT_BITS]};
        end
    end

    // -----------------------------------------------------------------
    // 2. Column-word counter (0..18) and row counter
    // -----------------------------------------------------------------
    reg [$clog2(WORDS_PER_ROW)-1:0] r_col_word;
    reg [15:0]                       r_row;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_col_word <= 0;
            r_row      <= 0;
        end else if (i_IDLE_rst) begin
            r_col_word <= 0;
            r_row      <= 0;
        end else if (i_input_valid) begin
            if (r_col_word == WORDS_PER_ROW - 1) begin
                r_col_word <= 0;
                r_row      <= r_row + 1;
            end else begin
                r_col_word <= r_col_word + 1;
            end
        end
    end

    // -----------------------------------------------------------------
    // 3. Valid / done / img_done (2-clock pipeline, baseline pattern)
    // -----------------------------------------------------------------
    wire w_valid_in_window = (r_row >= WIN_ROW - 1);
    wire w_done_in_window  = (r_row >= WIN_ROW - 1)
                           && (r_col_word == WORDS_PER_ROW - 1);
    wire w_img_done        = (r_row == IMG_WIDTH);

    reg r_valid, r_done;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_valid        <= 0;
            r_done         <= 0;
            o_line_valid   <= 0;
            o_line_rd_done <= 0;
            o_img_done     <= 0;
        end else if (i_IDLE_rst) begin
            r_valid        <= 0;
            r_done         <= 0;
            o_line_valid   <= 0;
            o_line_rd_done <= 0;
            o_img_done     <= 0;
        end else begin
            r_valid        <= w_valid_in_window;
            r_done         <= w_done_in_window;
            o_line_valid   <= r_valid;
            o_line_rd_done <= r_done;
            o_img_done     <= w_img_done;
        end
    end

    // -----------------------------------------------------------------
    // 4. Window output: bottom WIN_COL pixels (160 bits) of each row
    //    Packing: win[9] at MSB, win[0] at LSB per row (newest col = LSB).
    //    Full output: {row2_160b, row1_160b, row0_160b} = 480 bits.
    // -----------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_line_data <= 0;
        end else if (i_IDLE_rst) begin
            o_line_data <= 0;
        end else if (r_valid) begin
            o_line_data <= { r_line2[WIN_BITS-1:0],
                             r_line1[WIN_BITS-1:0],
                             r_line0[WIN_BITS-1:0] };
        end
    end

endmodule
