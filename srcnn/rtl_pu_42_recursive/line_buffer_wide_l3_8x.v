// line_buffer_wide_l3_8x.v — 8-pixel shift, 3×10 window line buffer for L3 8-way unroll.
//
// L3 layer (2 in_ch → 1 out_ch, no ReLU) 의 LSB-aligned 변종.
//   - 슬라이스 위치를 LSB 쪽 (= line_buffer_wide 와 다르게) 으로 둬서, K=0 emit 시
//     lane 0,1 = col -2,-1 (이미지 바깥) 으로 lane_valid mask 적용.
//   - per-word lane→col mapping :
//       lane k → out col 8K - 2 + k, k=0..7.
//       K = 0      : lanes 0,1 invalid (cols -2,-1), lanes 2..7 valid (cols 0..5).
//       K = 1..18  : lanes 0..7 valid (cols 8K-2..8K+5).
//   - row 당 emit = 19 (K=0..18), valid px 총 6 + 18*8 = 150.
//   - 152/8 = 19 → IMG_WIDTH = 152 와 정수 정렬.
//
//   Slice 위치 : `r_lineX[(WIN_COL+1)*DATA_BIT-1 : DATA_BIT]` = [175:16], 10 px (160 bit).
//
//   3×3 conv input picks per lane k (slice indices, win[0]=LSB=newest) :
//     win[9-k] (left), win[8-k] (center), win[7-k] (right).

module line_buffer_wide_l3_8x #(
    parameter IMG_WIDTH    = 152,
    parameter WIN_ROW      = 3,
    parameter WIN_COL      = 10,
    parameter SHIFT_STEP   = 8,
    parameter DATA_BIT     = 16,
    parameter LANE_NUM     = 8,

    parameter SHIFT_BITS   = SHIFT_STEP * DATA_BIT,         // 128
    parameter LINE_SIZE    = IMG_WIDTH * DATA_BIT,          // 2432
    parameter WIN_SIZE     = WIN_ROW * WIN_COL * DATA_BIT,  // 480
    parameter WIN_BITS     = WIN_COL * DATA_BIT,            // 160
    parameter WIN_OFFSET   = DATA_BIT                       // 16
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

    localparam WORDS_PER_ROW = IMG_WIDTH / SHIFT_STEP;   // 19
    localparam ROW_LAST_IN   = IMG_WIDTH - 1;            // 151

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

    wire w_valid_in_window = (r_row >= WIN_ROW - 1) && (r_row <= ROW_LAST_IN);
    wire w_done_in_window  = (r_row >= WIN_ROW - 1) && (r_col_word == WORDS_PER_ROW - 1);
    wire w_img_done = (r_row == IMG_WIDTH - 1) && (r_col_word == WORDS_PER_ROW - 1);

    // K=0 → lane 0,1 invalid (cols -2,-1). K>=1 → all 8 valid.
    wire [LANE_NUM-1:0] w_lane_valid_full =
        (r_col_word == 0) ? 8'b11111100 : 8'b11111111;

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

    // Window output : slice [175:16] = 10 px × 16 bit per row.
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
