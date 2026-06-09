`timescale 1ns / 1ps

module L2_PU #(
    parameter IN_CH        = 8,
    parameter W_PIXEL_NUM  = 4,
    parameter DATA_BIT     = 16,
    parameter W_BRAM_WIDTH = W_PIXEL_NUM * DATA_BIT
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_IDLE_rst,

    // 1. Feature Map Input (from L2_top: URAM read data, 128-bit packed 8ch)
    input  wire                          i_input_valid,
    input  wire [IN_CH*DATA_BIT-1:0]     i_uram_data,
    input  wire                          i_is_pad_valid, // FSM??o_is_pad_valid ?곌껐

    // 2. Weight & Bias Input (from L2_local_FSM + Weight BRAM)
    input  wire                          i_w_rd_en,         // 1clk-delayed weight valid (= o_weight_bram_rd_en delayed)
    input  wire [W_BRAM_WIDTH-1:0]       i_weight_bram_data,
    input  wire                          i_bias_en,         // FSM o_bias_en (1clk-delayed bias word indicator)

    // 3. Status outputs to FSM
    output wire                          o_line_rd_done,
    output wire                          o_pe_done,

    // 4. Final Output (to L2_top ??intermid2_3 URAM)
    output reg                           o_pixel_valid,
    output reg  [15:0]                   o_pixel_data,
    output wire                          o_img_done
);

    // --- per-channel arrays ---
    wire [143:0]       w_line_data       [0:IN_CH-1];
    wire               w_line_valid      [0:IN_CH-1];
    wire signed [31:0] w_partial         [0:IN_CH-1];
    wire               w_pe_valid        [0:IN_CH-1];
    wire               w_pe_done         [0:IN_CH-1];
    wire [IN_CH-1:0]   w_line_rd_done_ch;
    wire [IN_CH-1:0]   w_img_done_ch;
    wire               w_line_rd_done = w_line_rd_done_ch[0];
    wire               w_img_done     = w_img_done_ch[0];

    // =========================================================================
    // Weight Address Generation
    //   - 湲곗?? registered group_en/tap_en?? �??cycle???�??��???capture媛�? 1 cycle late??��?�� 踰꾧?�� ??���???    //     combinational decode�????��?�� (weight_addr媛�? ?꾩옱 bus mem[weight_addr]?????��?��)
    //   - clk:weight_data(W_In_Out_Tap) -> 0: w000 w100 w200 w300, 1: w400 w500 w600 w700, 2: w001 w101 w201 w301
    //   - i_w_rd_en??18clk??���? ?�쒖�? ??2clk留덈?�� tap ??���???    // =========================================================================
    reg [5:0]       weight_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)        weight_addr <= 0;
        else if (i_w_rd_en) weight_addr <= weight_addr + 1;
        else                weight_addr <= 0;
    end

    // L2: weight_addr 0~17 = weight, 18 = bias word
    // bias word?�?�???tap_en ?�?�? 0 (9bit << 9 overflow) ??PE no capture
    wire is_w_phase = i_w_rd_en && (weight_addr < 18);
    wire [IN_CH-1:0]    w_weight_group_en  = is_w_phase ? { {4{weight_addr[0]}}, {4{~weight_addr[0]}} } : {IN_CH{1'b0}};
    wire [8:0]          w_weight_tap_en    = is_w_phase ? (9'b1 << weight_addr[4:1]) : 9'd0;


    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_ch
            // padding mux per ch (1ch top 諛⑹?��)
            wire signed [15:0] w_lb_data;
            wire               w_lb_valid;
            assign w_lb_data  = i_is_pad_valid ? 16'h0 : i_uram_data[16*i +: 16];
            assign w_lb_valid = i_is_pad_valid ? 1'b1 : i_input_valid;

            line_buffer_improved #(
                .IMG_WIDTH(152),
                .WIN_ROW(3),
                .WIN_COL(3),
                .DATA_BIT(16)
            ) u_line_buffer (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (i_IDLE_rst),
                .i_input_valid  (w_lb_valid),
                .i_input_data   (w_lb_data),
                .o_line_data    (w_line_data[i]),
                .o_line_valid   (w_line_valid[i]),
                .o_line_rd_done (w_line_rd_done_ch[i]),
                .o_img_done     (w_img_done_ch[i])
            );

            pe_group pe_inst (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_line_valid   (w_line_valid[i]),
                .i_line_data    (w_line_data[i]),
                .i_weight       (i_weight_bram_data[16*(i[1:0]) +: 16]),
                .i_w_tap_en     ({9{w_weight_group_en[i]}} & w_weight_tap_en),
                .i_line_done    (w_line_rd_done),
                .o_valid        (w_pe_valid[i]),
                .o_partial      (w_partial[i]),
                .o_pe_done      (w_pe_done[i])
            );
        end
    endgenerate

    // Status outputs (all channels aligned -> use ch0)
    assign o_line_rd_done = w_line_rd_done;
    assign o_pe_done      = w_pe_done[0];

    // =========================================================================
    // [3] Channel Integration Adder Tree (?�듦�? 蹂묐?�� 8�?꾨꼸 ??���?)
    // =========================================================================
    reg signed [31:0] r_add_stage1 [0:3];
    reg signed [31:0] r_add_stage2 [0:1];
    reg signed [31:0] r_add_stage3;
    reg               r_valid_stage1, r_valid_stage2, r_valid_stage3;

    always @(posedge i_clk) begin
        r_add_stage1[0] <= $signed(w_partial[0]) + $signed(w_partial[1]);
        r_add_stage1[1] <= $signed(w_partial[2]) + $signed(w_partial[3]);
        r_add_stage1[2] <= $signed(w_partial[4]) + $signed(w_partial[5]);
        r_add_stage1[3] <= $signed(w_partial[6]) + $signed(w_partial[7]);
        r_valid_stage1  <= w_pe_valid[0];

        r_add_stage2[0] <= $signed(r_add_stage1[0]) + $signed(r_add_stage1[1]);
        r_add_stage2[1] <= $signed(r_add_stage1[2]) + $signed(r_add_stage1[3]);
        r_valid_stage2  <= r_valid_stage1;

        r_add_stage3    <= $signed(r_add_stage2[0]) + $signed(r_add_stage2[1]);
        r_valid_stage3  <= r_valid_stage2;
    end

    // =========================================================================
    // [4] Bias Latch & ReLU + Saturation Pipeline
    // =========================================================================
    reg signed [15:0] r_bias;
    wire signed [31:0] w_final_sum_q8_8   = ( $signed(r_add_stage3)>>>8 ) + $signed(r_bias);

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias        <= 0;
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            if (i_bias_en) r_bias <= i_weight_bram_data[63 -: DATA_BIT];

            o_pixel_valid <= r_valid_stage3;

            if (w_final_sum_q8_8 <= 0) begin
                o_pixel_data <= 16'd0;
            end else if (w_final_sum_q8_8 > 32'sd32767) begin
                o_pixel_data <= 16'h7FFF;
            end else begin
                o_pixel_data <= w_final_sum_q8_8[15:0];
            end
        end
    end

    // =========================================================================
    // [5] img_done propagation (for FSM)
    // =========================================================================
    delay_shift #(
        .DELAY(3+3+1)
    ) d3_line_buff_done_to_PU (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(w_img_done),
        .dout(o_img_done)
    );

endmodule

