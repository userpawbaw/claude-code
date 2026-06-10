`timescale 1ns / 1ps
// out_buf.v : L3 64-bit/clk output -> BRAM buffer -> 16-bit/clk serial stream.
//
// -- Write packer ----------------------------------------------------------
//   lane_valid pattern (from line_buffer_wide_l3):
//     col_word=0    : 4'b1100 -> 2 valid px (lanes 2,3 = padded cols 0,1)
//     col_word=1..37: 4'b1111 -> 4 valid px
//   2-phase accumulation via r_half / r_hold -> 22500 / 4 = 5625 words/image.
//
//   r_half state transitions (r_half is 0 at img_done since 150 rows is even):
//     r_half=0, 2valid : hold -> r_half=1                       (no write)
//     r_half=0, 4valid : write {px0,px1,px2,px3}                (r_half stays 0)
//     r_half=1, 2valid : write {hold,px2,px3}                   (r_half -> 0)
//     r_half=1, 4valid : write {hold,px0,px1}, hold {px2,px3}   (r_half stays 1)
//
// -- BRAM bank -------------------------------------------------------------
//   3 banks (NUM_IMG x 5625 words). r_wr_abs is monotonically incrementing.
//   Bank b spans absolute addresses b*5625 .. (b+1)*5625-1.
//   No address conflicts for the 3-image sim (production would need
//   ping-pong + rd_done handshake).
//
// -- Read serializer -------------------------------------------------------
//   BRAM read latency = 1 clk. Pipeline:
//     RS_IDLE  : wait for img_done.
//     RS_START : issue rd_en[word 0].
//     RS_START2: rd_valid[word 0] -> r_cur; issue rd_en[word 1].
//     RS_RUN   : rd_valid[word 1] -> r_nxt; start output (px_cnt=0).
//       px_cnt=2: pre-issue rd_en[word K+1].
//       px_cnt=3: rd_valid[word K+1] -> r_nxt; r_cur <- old r_nxt; px_cnt=0.
//       After 5625 words -> RS_DONE.
//     RS_DONE  : 1-clk o_img_done pulse.

module out_buf #(
    parameter NPIX_IMG   = 22500,
    parameter NWORDS     = NPIX_IMG / 4,    // 5625
    parameter NUM_IMG    = 3,
    parameter BRAM_DEPTH = NUM_IMG * NWORDS, // 16875
    parameter AW         = 15               // ceil(log2(16875))=15 (2^15=32768)
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_pixel_valid,
    input  wire [63:0] i_pixel_data,
    input  wire [3:0]  i_lane_valid,
    input  wire        i_img_done,

    output reg         o_pix_valid,
    output reg  [15:0] o_pix_data,
    output reg         o_img_done
);
    // -----------------------------------------------------------------------
    // BRAM (64-bit x BRAM_DEPTH)
    // -----------------------------------------------------------------------
    reg          r_bram_wr_en;
    reg  [AW-1:0] r_bram_wr_addr;
    reg  [63:0]  r_bram_wr_din;
    reg          r_bram_rd_en;
    reg  [AW-1:0] r_bram_rd_addr;
    wire         w_bram_rd_valid;
    wire [63:0]  w_bram_rd_dout;

    simple_dual_port_bram #(.WIDTH(64), .DEPTH(BRAM_DEPTH)) u_bram (
        .clk      (i_clk),
        .wr_en    (r_bram_wr_en),
        .rd_en    (r_bram_rd_en),
        .wr_addr  ({{(17-AW){1'b0}}, r_bram_wr_addr}),
        .rd_addr  ({{(17-AW){1'b0}}, r_bram_rd_addr}),
        .wr_din   (r_bram_wr_din),
        .rd_valid (w_bram_rd_valid),
        .rd_dout  (w_bram_rd_dout)
    );

    // -----------------------------------------------------------------------
    // Write packer
    // -----------------------------------------------------------------------
    wire [15:0] w_px0 = i_pixel_data[63:48];
    wire [15:0] w_px1 = i_pixel_data[47:32];
    wire [15:0] w_px2 = i_pixel_data[31:16];
    wire [15:0] w_px3 = i_pixel_data[15: 0];
    wire        w_is2 = (i_lane_valid == 4'b1100);

    reg         r_half;
    reg [31:0]  r_hold;       // {held_px_a, held_px_b}
    reg [AW-1:0] r_wr_abs;   // absolute BRAM write address (never resets)
    reg [1:0]   r_wr_bank;   // write bank (0..NUM_IMG-1)

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_half       <= 0;
            r_hold       <= 0;
            r_wr_abs     <= 0;
            r_wr_bank    <= 0;
            r_bram_wr_en <= 0;
        end else begin
            r_bram_wr_en <= 0;

            if (i_img_done) begin
                // Bank flip for next image. r_half guaranteed 0 after 150 rows.
                r_wr_bank <= (r_wr_bank == NUM_IMG - 1) ? 2'd0 : r_wr_bank + 2'd1;
                r_half    <= 0;
            end else if (i_pixel_valid) begin
                if (w_is2) begin
                    if (!r_half) begin
                        r_hold <= {w_px2, w_px3};
                        r_half <= 1'b1;
                    end else begin
                        // write {hold, px2, px3}
                        r_bram_wr_en  <= 1'b1;
                        r_bram_wr_addr <= r_wr_abs;
                        r_bram_wr_din  <= {r_hold, w_px2, w_px3};
                        r_wr_abs      <= r_wr_abs + 1'b1;
                        r_half        <= 1'b0;
                    end
                end else begin // 4 valid
                    if (!r_half) begin
                        // write directly
                        r_bram_wr_en  <= 1'b1;
                        r_bram_wr_addr <= r_wr_abs;
                        r_bram_wr_din  <= {w_px0, w_px1, w_px2, w_px3};
                        r_wr_abs      <= r_wr_abs + 1'b1;
                    end else begin
                        // write {hold, px0, px1}, keep {px2, px3}
                        r_bram_wr_en  <= 1'b1;
                        r_bram_wr_addr <= r_wr_abs;
                        r_bram_wr_din  <= {r_hold, w_px0, w_px1};
                        r_wr_abs      <= r_wr_abs + 1'b1;
                        r_hold        <= {w_px2, w_px3};
                        // r_half stays 1
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Read serializer
    // -----------------------------------------------------------------------
    localparam RS_IDLE   = 3'd0;
    localparam RS_START  = 3'd1;
    localparam RS_START2 = 3'd2;
    localparam RS_RUN    = 3'd3;
    localparam RS_DONE   = 3'd4;

    reg [2:0]    r_rs;
    reg [AW-1:0] r_rd_ptr;      // next word addr to issue rd_en for
    reg [AW-1:0] r_rd_base;     // start addr of current read bank
    reg [12:0]   r_words_done;  // words fully serialized (0..NWORDS-1)
    reg [12:0]   r_words_issued; // rd_en count

    reg [1:0]    r_px_cnt;
    reg [63:0]   r_cur_word;
    reg [63:0]   r_nxt_word;

    // When img_done fires, r_wr_bank still holds the JUST-FINISHED bank
    // (non-blocking update in write always block → not yet visible here).
    wire [AW-1:0] w_rd_base_next = r_wr_bank * NWORDS[AW-1:0];

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_rs           <= RS_IDLE;
            r_rd_ptr       <= 0;
            r_rd_base      <= 0;
            r_words_done   <= 0;
            r_words_issued <= 0;
            r_px_cnt       <= 0;
            r_cur_word     <= 0;
            r_nxt_word     <= 0;
            r_bram_rd_en   <= 0;
            r_bram_rd_addr <= 0;
            o_pix_valid    <= 0;
            o_pix_data     <= 0;
            o_img_done     <= 0;
        end else begin
            o_pix_valid <= 0;
            o_img_done  <= 0;
            r_bram_rd_en <= 0;

            case (r_rs)
                RS_IDLE : begin
                    if (i_img_done) begin
                        // r_wr_bank is OLD value (hasn't flipped yet in this cycle)
                        r_rd_base      <= w_rd_base_next;
                        r_rd_ptr       <= w_rd_base_next + {{(AW-1){1'b0}}, 1'b1};
                        r_words_done   <= 0;
                        r_words_issued <= 1;
                        // Issue first read
                        r_bram_rd_en   <= 1;
                        r_bram_rd_addr <= w_rd_base_next;
                        r_rs           <= RS_START2;
                    end
                end

                RS_START2 : begin
                    // rd_valid[word0] arrives. Capture and issue rd_en[word1].
                    if (w_bram_rd_valid) begin
                        r_cur_word <= w_bram_rd_dout;
                        if (r_words_issued < NWORDS[12:0]) begin
                            r_bram_rd_en   <= 1;
                            r_bram_rd_addr <= r_rd_ptr;
                            r_rd_ptr       <= r_rd_ptr + 1'b1;
                            r_words_issued <= r_words_issued + 13'd1;
                        end
                        r_px_cnt <= 0;
                        r_rs     <= RS_RUN;
                    end
                end

                RS_RUN : begin
                    // Capture rd_valid into r_nxt (arrives at px_cnt=3 from px_cnt=2 issue).
                    if (w_bram_rd_valid)
                        r_nxt_word <= w_bram_rd_dout;

                    // Output pixel
                    o_pix_valid <= 1;
                    o_pix_data  <= r_cur_word[(3 - r_px_cnt) * 16 +: 16];

                    if (r_px_cnt == 2'd2) begin
                        // Pre-fetch next word
                        if (r_words_issued < NWORDS[12:0]) begin
                            r_bram_rd_en   <= 1;
                            r_bram_rd_addr <= r_rd_ptr;
                            r_rd_ptr       <= r_rd_ptr + 1'b1;
                            r_words_issued <= r_words_issued + 13'd1;
                        end
                    end

                    if (r_px_cnt == 2'd3) begin
                        r_words_done <= r_words_done + 13'd1;
                        if (r_words_done + 13'd1 == NWORDS[12:0]) begin
                            r_rs <= RS_DONE;
                        end else begin
                            r_cur_word <= r_nxt_word;
                            r_px_cnt   <= 0;
                        end
                    end else begin
                        r_px_cnt <= r_px_cnt + 2'd1;
                    end
                end

                RS_DONE : begin
                    o_img_done <= 1;
                    r_rs       <= RS_IDLE;
                end

                default: r_rs <= RS_IDLE;
            endcase
        end
    end

endmodule
