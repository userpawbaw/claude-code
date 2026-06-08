// line_buffer_wide_l3.v — 4-pixel shift, 3×6 window line buffer for L3 unroll.
//
// L3 layer (8 in_ch → 1 out_ch, no ReLU) uses 4-way output unroll to keep
// per-clock output = 4 × 16-bit = 64 bit, matching the URAM word width.
//
// Design notes :
//   - Slice position : 1-px-shifted-from-LSB, bits [WIN_BITS+DATA_BIT-1 : DATA_BIT]
//                    = [111:16], 6 pixels covering cols [4K-3 .. 4K+2] of input row.
//   - Per-word lane→col mapping (word_cnt K of input row R):
//       lane k → out col (4K - 2 + k), for k = 0..3.
//       * K = 0      : lanes map to cols (-2, -1, 0, 1) → lanes 2,3 valid only
//                      (out cols 0, 1). lanes 0,1 invalid.
//       * K = 1..37  : lanes map to cols (4K-2 .. 4K+1) → all 4 lanes valid.
//   - 3×3 conv input picks per lane k (slice indices, win[0]=LSB=newest):
//       win[5-k] (left), win[4-k] (center), win[3-k] (right).
//   - Output schedule per output row r ∈ [1..150]:
//       word_cnt = 0      of input row (r+1) → out cols 0, 1     (2 valid lanes)
//       word_cnt = 1..37  of input row (r+1) → out cols 2..149   (4 valid each)
//     Total = 1 + 37 = 38 emits, 2 + 37*4 = 150 cols per row.
//   - "col -1" slot at K=0 (= slice win[3], from previous row's col 151) is the
//     L2 right-pad zero. Lane 2's left-column input is naturally 0; no mask needed.
//
//   Lane valid output (o_lane_valid) :
//     o_lane_valid[k] = 1 ⇒ lane k output corresponds to a real out col;
//     packer downstream picks valid pixels and packs them into 4-px URAM words.
//
// Timing (same 2-clk pipeline as 8-way line_buffer_wide).

module line_buffer_wide_l3 #(
    parameter IMG_WIDTH    = 152,
    parameter WIN_ROW      = 3,
    parameter WIN_COL      = 6,
    parameter SHIFT_STEP   = 4,
    parameter DATA_BIT     = 16,
    parameter LANE_NUM     = 4,

    parameter SHIFT_BITS   = SHIFT_STEP * DATA_BIT,         // 64
    parameter LINE_SIZE    = IMG_WIDTH * DATA_BIT,          // 2432
    parameter WIN_SIZE     = WIN_ROW * WIN_COL * DATA_BIT,  // 288
    parameter WIN_BITS     = WIN_COL * DATA_BIT,            // 96
    parameter WIN_OFFSET   = DATA_BIT                       // 16  (slice LSB-side bit)
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

    localparam WORDS_PER_ROW = IMG_WIDTH / SHIFT_STEP;   // 38
    localparam ROW_LAST_IN   = IMG_WIDTH - 1;            // 151

    // -----------------------------------------------------------------
    // 1. Shift registers
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
    // 2. Column-word counter (0..37) and row counter
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
    // 3. Emit qualifier + per-lane valid
    //    All cycles where r_row in [2..151] emit. Lane valid mask varies:
    //      r_col_word == 0   → 4'b1100  (only lanes 2,3 = out cols 0, 1)
    //      r_col_word >= 1   → 4'b1111  (all 4 lanes)
    // -----------------------------------------------------------------
    wire w_valid_in_window = (r_row >= WIN_ROW - 1) && (r_row <= ROW_LAST_IN);
    wire w_done_in_window  = (r_row >= WIN_ROW - 1) && (r_col_word == WORDS_PER_ROW - 1);
    wire w_img_done        = (r_row == IMG_WIDTH);

    wire [LANE_NUM-1:0] w_lane_valid_full =
        (r_col_word == 0) ? 4'b1100 : 4'b1111;

    reg r_valid, r_done;
    reg [LANE_NUM-1:0] r_lane_valid;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_valid        <= 0;
            r_done         <= 0;
            r_lane_valid   <= 0;
            o_line_valid   <= 0;
            o_line_rd_done <= 0;
            o_img_done     <= 0;
            o_lane_valid   <= 0;
        end else if (i_IDLE_rst) begin
            r_valid        <= 0;
            r_done         <= 0;
            r_lane_valid   <= 0;
            o_line_valid   <= 0;
            o_line_rd_done <= 0;
            o_img_done     <= 0;
            o_lane_valid   <= 0;
        end else begin
            r_valid        <= i_input_valid && w_valid_in_window;
            r_done         <= i_input_valid && w_done_in_window;
            r_lane_valid   <= (i_input_valid && w_valid_in_window) ? w_lane_valid_full : {LANE_NUM{1'b0}};
            o_line_valid   <= r_valid;
            o_line_rd_done <= r_done;
            o_img_done     <= i_input_valid && w_img_done;
            o_lane_valid   <= r_lane_valid;
        end
    end

    // -----------------------------------------------------------------
    // 4. Window output : 1-px-shifted slice bits [WIN_BITS+DATA_BIT-1 : DATA_BIT]
    //    = [111:16] of each line buffer.
    //    Within each 96-bit row slice (LSB pixel = newest col side):
    //      slice[15:0]   = pixel 0 = lane 2 of newest word = col 4K+2.
    //      slice[63:48]  = pixel 3 = lane 3 of prev  word  = col 4K-1.
    //      slice[95:80]  = pixel 5 = lane 1 of prev  word  = col 4K-3.
    //    Full output : {r_line2_slice, r_line1_slice, r_line0_slice} = 288 b.
    // -----------------------------------------------------------------
    wire [WIN_BITS-1:0] w_slice0 = r_line0[WIN_OFFSET +: WIN_BITS];
    wire [WIN_BITS-1:0] w_slice1 = r_line1[WIN_OFFSET +: WIN_BITS];
    wire [WIN_BITS-1:0] w_slice2 = r_line2[WIN_OFFSET +: WIN_BITS];

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_line_data <= 0;
        end else if (i_IDLE_rst) begin
            o_line_data <= 0;
        end else if (r_valid) begin
            o_line_data <= { w_slice2, w_slice1, w_slice0 };
        end
    end

endmodule
