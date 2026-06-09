`timescale 1ns / 1ps
// high_top.v (rtl_pu_88_unroll) — top.v + 3-bank output URAM + fifo_generator_1.
//
// top.v outputs: o_pixel_valid, o_pixel_data[63:0] (4 px × 16-bit), o_lane_valid[3:0].
// Write packer: r_half / r_hold → 5625 64-bit URAM words per image.
// 3-bank URAM (16875 words total): absolute addr never resets.
// Read: 1 word/4 clk starting at first img_done → fifo_generator_1 → 16-bit serial.
// o_img_done: counts 22500 valid pixels per image.

module high_top #(
    parameter NPIX_IMG   = 22500,
    parameter NWORDS     = NPIX_IMG / 4,       // 5625
    parameter NUM_IMG    = 3,
    parameter URAM_DEPTH = NUM_IMG * NWORDS,   // 16875
    parameter AW         = 15                  // ceil(log2(16875))=15
)(
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
    // Write packer → URAM
    // -----------------------------------------------------------------------
    wire [15:0] w_px0 = w_pix_data[63:48];
    wire [15:0] w_px1 = w_pix_data[47:32];
    wire [15:0] w_px2 = w_pix_data[31:16];
    wire [15:0] w_px3 = w_pix_data[15: 0];
    wire        w_is2 = (w_lane_valid == 4'b1100);

    reg          r_half;
    reg [31:0]   r_hold;
    reg [AW-1:0] r_wr_abs;
    reg [1:0]    r_wr_bank;

    reg          r_uram_wr_en;
    reg [AW-1:0] r_uram_wr_addr;
    reg [63:0]   r_uram_wr_din;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_half       <= 0;
            r_hold       <= 0;
            r_wr_abs     <= 0;
            r_wr_bank    <= 0;
            r_uram_wr_en <= 0;
        end else begin
            r_uram_wr_en <= 0;

            if (w_top_img_done) begin
                r_wr_bank <= (r_wr_bank == NUM_IMG - 1) ? 2'd0 : r_wr_bank + 2'd1;
                r_half    <= 0;
            end else if (w_pix_valid) begin
                if (w_is2) begin
                    if (!r_half) begin
                        r_hold <= {w_px2, w_px3};
                        r_half <= 1'b1;
                    end else begin
                        r_uram_wr_en   <= 1'b1;
                        r_uram_wr_addr <= r_wr_abs;
                        r_uram_wr_din  <= {r_hold, w_px2, w_px3};
                        r_wr_abs       <= r_wr_abs + 1'b1;
                        r_half         <= 1'b0;
                    end
                end else begin // 4 valid
                    if (!r_half) begin
                        r_uram_wr_en   <= 1'b1;
                        r_uram_wr_addr <= r_wr_abs;
                        r_uram_wr_din  <= {w_px0, w_px1, w_px2, w_px3};
                        r_wr_abs       <= r_wr_abs + 1'b1;
                    end else begin
                        r_uram_wr_en   <= 1'b1;
                        r_uram_wr_addr <= r_wr_abs;
                        r_uram_wr_din  <= {r_hold, w_px0, w_px1};
                        r_wr_abs       <= r_wr_abs + 1'b1;
                        r_hold         <= {w_px2, w_px3};
                        // r_half stays 1
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Output URAM (64-bit × 16875)
    // -----------------------------------------------------------------------
    reg          r_uram_rd_en;
    reg [AW-1:0] r_uram_rd_addr;
    wire         w_uram_rd_valid;
    wire [63:0]  w_uram_rd_dout;

    simple_dual_port_uram #(.WIDTH(64), .DEPTH(URAM_DEPTH)) u_out_uram (
        .clk     (i_clk),
        .wr_en   (r_uram_wr_en),
        .wr_addr ({{(15-AW){1'b0}}, r_uram_wr_addr}),
        .wr_din  (r_uram_wr_din),
        .rd_en   (r_uram_rd_en),
        .rd_addr ({{(15-AW){1'b0}}, r_uram_rd_addr}),
        .rd_valid(w_uram_rd_valid),
        .rd_dout (w_uram_rd_dout)
    );

    // -----------------------------------------------------------------------
    // Read controller: 1 word/4 clk, addr 0..16874 sequential.
    // Starts on first w_top_img_done. Banks are guaranteed fully written
    // before each read window reaches them.
    // -----------------------------------------------------------------------
    reg          r_read_started;
    reg [AW-1:0] r_rd_ptr;
    reg [1:0]    r_rd_phase;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_read_started <= 0;
            r_rd_ptr       <= 0;
            r_rd_phase     <= 0;
            r_uram_rd_en   <= 0;
            r_uram_rd_addr <= 0;
        end else begin
            r_uram_rd_en <= 0;

            if (!r_read_started) begin
                if (w_top_img_done) begin
                    r_read_started <= 1;
                    r_rd_ptr       <= 0;
                    r_rd_phase     <= 0;
                end
            end else begin
                r_rd_phase <= r_rd_phase + 2'd1;
                if (r_rd_phase == 2'd0 && r_rd_ptr < r_wr_abs && r_rd_ptr < URAM_DEPTH[AW:0]) begin
                    r_uram_rd_en   <= 1'b1;
                    r_uram_rd_addr <= r_rd_ptr[AW-1:0];
                    r_rd_ptr       <= r_rd_ptr + 1'b1;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // fifo_generator_1 (64-bit write / 16-bit read)
    // URAM → FIFO: 1 write per 4 clk (steady-state FIFO level ≤ 4 entries)
    // FIFO → output: rd_en = ~empty, 1 pixel/clk
    // -----------------------------------------------------------------------
    reg r_srst;
    always @(posedge i_clk) r_srst <= ~i_rstn;

    wire w_fifo_empty;
    wire w_fifo_valid;

    fifo_generator_1 u_fifo (
        .clk        (i_clk),
        .srst       (r_srst),
        .din        (w_uram_rd_dout),
        .wr_en      (w_uram_rd_valid),
        .rd_en      (~w_fifo_empty),
        .dout       (o_pix_data),
        .full       (),
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
    reg [14:0] r_px_cnt;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_px_cnt   <= 0;
            o_img_done <= 0;
        end else begin
            o_img_done <= 0;
            if (w_fifo_valid) begin
                if (r_px_cnt == NPIX_IMG[14:0] - 1) begin
                    r_px_cnt   <= 0;
                    o_img_done <= 1'b1;
                end else begin
                    r_px_cnt <= r_px_cnt + 1'b1;
                end
            end
        end
    end

endmodule
