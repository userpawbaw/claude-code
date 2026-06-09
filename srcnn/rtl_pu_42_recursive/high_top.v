`timescale 1ns / 1ps
// high_top.v — top.v + write packer + fifo_generator_1 (64-bit→16-bit).
//
// Write packer: same r_half / r_hold logic as out_buf.v.
//   lane_valid 4'b1100 (col_word=0, 2 valid px) → accumulate into hold.
//   lane_valid 4'b1111 (col_word≥1, 4 valid px) → direct or paired write.
//   5625 64-bit writes per image, 22500 16-bit reads per image.
//
// FIFO: fifo_generator_1 (64-bit write, 16-bit read, valid output).
//   rd_en = ~empty  → continuous drain at 1 px/clk.
//   valid           → o_pix_valid.
//
// o_img_done: counts 22500 valid pulses, pulses 1 clk per image.

module high_top (
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,

    output wire        o_all_done,
    output wire        o_pix_valid,
    output wire [15:0] o_pix_data,
    output reg         o_img_done
);
    // -----------------------------------------------------------------------
    // top.v
    // -----------------------------------------------------------------------
    wire        w_top_img_done;
    wire        w_pix_valid;
    wire [63:0] w_pix_data;
    wire [3:0]  w_lane_valid;

    top u_top (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_start       (i_start),
        .o_img_done    (w_top_img_done),
        .o_all_done    (o_all_done),
        .o_pixel_valid (w_pix_valid),
        .o_pixel_data  (w_pix_data),
        .o_lane_valid  (w_lane_valid)
    );

    // -----------------------------------------------------------------------
    // Write packer  (64-bit words → fifo_generator_1)
    // -----------------------------------------------------------------------
    wire [15:0] w_px0 = w_pix_data[63:48];
    wire [15:0] w_px1 = w_pix_data[47:32];
    wire [15:0] w_px2 = w_pix_data[31:16];
    wire [15:0] w_px3 = w_pix_data[15: 0];
    wire        w_is2 = (w_lane_valid == 4'b1100);

    reg         r_half;
    reg [31:0]  r_hold;
    reg         r_fifo_wr_en;
    reg [63:0]  r_fifo_din;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_half       <= 0;
            r_hold       <= 0;
            r_fifo_wr_en <= 0;
            r_fifo_din   <= 0;
        end else begin
            r_fifo_wr_en <= 0;

            if (w_top_img_done) begin
                r_half <= 0;
            end else if (w_pix_valid) begin
                if (w_is2) begin
                    if (!r_half) begin
                        r_hold <= {w_px2, w_px3};
                        r_half <= 1'b1;
                    end else begin
                        r_fifo_wr_en <= 1'b1;
                        r_fifo_din   <= {r_hold, w_px2, w_px3};
                        r_half       <= 1'b0;
                    end
                end else begin  // 4 valid
                    if (!r_half) begin
                        r_fifo_wr_en <= 1'b1;
                        r_fifo_din   <= {w_px0, w_px1, w_px2, w_px3};
                    end else begin
                        r_fifo_wr_en <= 1'b1;
                        r_fifo_din   <= {r_hold, w_px0, w_px1};
                        r_hold       <= {w_px2, w_px3};
                        // r_half stays 1
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // fifo_generator_1 (64-bit write / 16-bit read)
    // -----------------------------------------------------------------------
    // srst: synchronous reset. Assert for 1 cycle when coming out of rstn.
    reg r_srst;
    always @(posedge i_clk) r_srst <= ~i_rstn;

    wire w_fifo_empty;
    wire w_fifo_valid;
    wire w_fifo_full;

    fifo_generator_1 u_fifo (
        .clk        (i_clk),
        .srst       (r_srst),
        .din        (r_fifo_din),
        .wr_en      (r_fifo_wr_en),
        .rd_en      (~w_fifo_empty),
        .dout       (o_pix_data),
        .full       (w_fifo_full),
        .empty      (w_fifo_empty),
        .valid      (w_fifo_valid),
        .underflow  (),
        .wr_rst_busy(),
        .rd_rst_busy()
    );

    assign o_pix_valid = w_fifo_valid;

    // -----------------------------------------------------------------------
    // o_img_done: pulse every 22500 valid pixels
    // -----------------------------------------------------------------------
    localparam NPIX_IMG = 22500;
    reg [14:0] r_px_cnt;   // 0 .. 22499

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_px_cnt   <= 0;
            o_img_done <= 0;
        end else begin
            o_img_done <= 0;
            if (w_fifo_valid) begin
                if (r_px_cnt == NPIX_IMG - 1) begin
                    r_px_cnt   <= 0;
                    o_img_done <= 1;
                end else begin
                    r_px_cnt <= r_px_cnt + 15'd1;
                end
            end
        end
    end

endmodule
