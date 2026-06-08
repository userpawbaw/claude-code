// line_buffer_wide.v — 8-pixel shift, 3×10 window line buffer for 8-px unroll.
//
// Design notes (post-revision):
//   - Treats 3-line buffer as a continuous stream (row boundary is implicit).
//   - 8-px shift per clock. Slice position is offset such that, after word_cnt
//     K of row R is shifted in, the 10-pixel window of r_line0 covers input
//     cols {((K-1)*8 - 1) .. (K*8)} of row R (with col -1 = dummy at slice[9]
//     for K=1, and col K*8 = the freshest pixel of word K at slice[0]).
//
//   Slice bit range : `r_lineX[(WIN_COL+SHIFT_STEP-1)*DATA_BIT-1 : (SHIFT_STEP-1)*DATA_BIT]`
//                   = bits [271:112], 10 pixels (160 bits).
//                   slice[9] (MSB pixel) = leftmost col (= "col -1" at the row-start emit).
//                   slice[0] (LSB pixel) = rightmost col (newest pixel of current word).
//
//   Emission schedule (per output row r ∈ [1..150]):
//     word_cnt = 1..18 of input row (r+1) → output cols 0..143 of out_row r.
//     word_cnt = 0     of input row (r+2) → output cols 144..151 of out_row r.
//   ⇒ Output row 150 needs word_cnt=0 of "input row 152", i.e. **one extra
//     dummy input word at the end of the L1 stream**. FSM must feed it.
//
//   Lane mask (handled internally) :
//     - At word_cnt=1 emit (row-start), slice[9] of every row holds stale data
//       from the previous row (not zero), so we force it to 0 to model col=-1
//       left padding. This makes PU lane 0's left-column input = 0.
//     - At word_cnt=0 emit (row-end), slice[0] = next-row col 0 = 0 from the
//       pre-padded 152×152 input (col=0 zero padding), so no extra mask
//       needed; PU lane 7's right-column input is naturally 0.
//
// Timing (same 2-clk pipeline pattern):
//   Clock N  : i_input_valid → shift register updates, counters update.
//   Clock N+1: r_valid captures.
//   Clock N+2: o_line_valid asserts, o_line_data available.

module line_buffer_wide #(
    parameter IMG_WIDTH    = 152,
    parameter WIN_ROW      = 3,
    parameter WIN_COL      = 10,
    parameter SHIFT_STEP   = 8,
    parameter DATA_BIT     = 16,
    parameter LANE_NUM     = SHIFT_STEP,                    // 8 output lanes

    parameter SHIFT_BITS   = SHIFT_STEP * DATA_BIT,         // 128
    parameter LINE_SIZE    = IMG_WIDTH * DATA_BIT,          // 2432
    parameter WIN_SIZE     = WIN_ROW * WIN_COL * DATA_BIT,  // 480
    parameter WIN_BITS     = WIN_COL * DATA_BIT,            // 160
    parameter WIN_OFFSET   = (SHIFT_STEP - 1) * DATA_BIT    // 112  (slice LSB bit)
)(
    input  wire                       i_clk,
    input  wire                       i_rstn,
    input  wire                       i_IDLE_rst,
    input  wire                       i_input_valid,
    input  wire [SHIFT_BITS-1:0]      i_input_data,

    output reg  [WIN_SIZE-1:0]        o_line_data,
    output reg  [LANE_NUM-1:0]        o_lane_valid,
    output reg                        o_line_valid,
    output reg                        o_line_rd_done,
    output reg                        o_img_done
);

    localparam WORDS_PER_ROW = IMG_WIDTH / SHIFT_STEP;       // 19
    localparam ROW_LAST_IN   = IMG_WIDTH - 1;                // 151
    localparam ROW_DUMMY_END = IMG_WIDTH;                    // 152 (extra-cycle phantom row)

    // -----------------------------------------------------------------
    // 1. Shift registers (3 rows, LINE_SIZE bits each, SHIFT_BITS shift step)
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
    //    r_row is allowed to reach IMG_WIDTH (=152) on the dummy-shift cycle
    //    that flushes out the last 8 output cols.
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
    // 3. Emit qualifier
    //    Emit at (r_row in 2..151 && r_col_word in 1..18)
    //         OR (r_row in 3..152 && r_col_word == 0).
    //    r_row==152 requires FSM to feed one extra dummy word (zero) after
    //    the real last word (row 151, col_word 18).
    // -----------------------------------------------------------------
    wire w_in_body_range  = (r_row >= WIN_ROW - 1) && (r_row <= ROW_LAST_IN);
    wire w_in_tail_range  = (r_row >= WIN_ROW)     && (r_row <= ROW_DUMMY_END);

    wire w_valid_in_window = (w_in_body_range && (r_col_word != 0))
                          || (w_in_tail_range && (r_col_word == 0));

    wire w_done_in_window  = (r_row == ROW_DUMMY_END) && (r_col_word == 0);
    wire w_img_done        = (r_row == ROW_DUMMY_END) && (r_col_word == 0);

    reg r_valid, r_done;
    reg r_mask_lane0;   // high when slice[9] of this emit is stale (= "col -1" pad slot)

    // Per-lane padding mask :
    //   r_col_word == 1 (row-start emit, out cols 0..7) → lane 0 = col 0  = pad (0).
    //   r_col_word == 0 (boundary emit, out cols 144..151) → lane 7 = col 151 = pad.
    //   other → all 8 lanes valid.
    wire [LANE_NUM-1:0] w_lane_valid_full =
        (r_col_word == 1) ? 8'b1111_1110 :
        (r_col_word == 0) ? 8'b0111_1111 :
                             8'b1111_1111;

    reg [LANE_NUM-1:0] r_lane_valid;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_valid        <= 0;
            r_done         <= 0;
            r_mask_lane0   <= 0;
            r_lane_valid   <= 0;
            o_line_valid   <= 0;
            o_line_rd_done <= 0;
            o_img_done     <= 0;
            o_lane_valid   <= 0;
        end else if (i_IDLE_rst) begin
            r_valid        <= 0;
            r_done         <= 0;
            r_mask_lane0   <= 0;
            r_lane_valid   <= 0;
            o_line_valid   <= 0;
            o_line_rd_done <= 0;
            o_img_done     <= 0;
            o_lane_valid   <= 0;
        end else begin
            r_valid        <= w_valid_in_window;
            r_done         <= w_done_in_window;
            r_mask_lane0   <= w_valid_in_window && (r_col_word == 1);
            r_lane_valid   <= w_valid_in_window ? w_lane_valid_full : {LANE_NUM{1'b0}};
            o_line_valid   <= r_valid;
            o_line_rd_done <= r_done;
            o_img_done     <= w_img_done;
            o_lane_valid   <= r_lane_valid;
        end
    end

    // -----------------------------------------------------------------
    // 4. Window output
    //    Slice = bits [WIN_OFFSET +: WIN_BITS] of each line buffer.
    //    Within each row's 160-bit slice : LSB pixel = slice[0] = newest col
    //    in window, MSB pixel = slice[9] = leftmost col (oldest / "col -1"
    //    at row-start emit).
    //
    //    Lane-0 mask : when r_mask_lane0=1, force the MSB pixel (slice[9])
    //    of every row to 0 to emulate col=-1 left padding.
    // -----------------------------------------------------------------
    wire [WIN_BITS-1:0] w_slice0 = r_line0[WIN_OFFSET +: WIN_BITS];
    wire [WIN_BITS-1:0] w_slice1 = r_line1[WIN_OFFSET +: WIN_BITS];
    wire [WIN_BITS-1:0] w_slice2 = r_line2[WIN_OFFSET +: WIN_BITS];

    // Mask the MSB DATA_BIT of each slice (= slice[9]) when needed.
    function [WIN_BITS-1:0] mask_msb_px;
        input [WIN_BITS-1:0] s;
        input                m;
        begin
            mask_msb_px = m
                        ? { {DATA_BIT{1'b0}}, s[WIN_BITS-DATA_BIT-1:0] }
                        : s;
        end
    endfunction

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_line_data <= 0;
        end else if (i_IDLE_rst) begin
            o_line_data <= 0;
        end else if (r_valid) begin
            o_line_data <= { mask_msb_px(w_slice2, r_mask_lane0),
                             mask_msb_px(w_slice1, r_mask_lane0),
                             mask_msb_px(w_slice0, r_mask_lane0) };
        end
    end

endmodule
