`timescale 1ns / 1ps

module L1_PU #(
    parameter OUT_CH       = 8,
    parameter DATA_BIT     = 16,

    parameter W_BRAM_WIDTH = 64,   // 16-bit x 4
    parameter W_BRAM_DEPTH = 20,
    parameter WEIGHT_DEPTH = 18

)(
    input  wire                         i_clk,
    input  wire                         i_rstn,
    input  wire                         i_IDLE_rst,
    
    // input 
    input  wire                         i_input_valid,
    input  wire [DATA_BIT-1:0]          i_pixel_data, // L1은 단일 채널(16bit) 입력
    
    // 2. Weight & Bias en & data
    input  wire                         i_w_rd_en, 
    input  wire [W_BRAM_WIDTH-1:0]      i_weight_bram_data,  
    
    // 3. Final Output (To L1 Output URAM, 128-bit)
    output reg                          o_pixel_valid,
    output reg  [(OUT_CH*DATA_BIT)-1:0] o_uram_data,

    // 4. Done signal for FSM (drain-aligned)
    output wire                         o_img_done
);

    // =========================================================================
    // 1. Weight & Bias Enable Control Logic
    //   - 기존 registered group_en/tap_en은 첫 cycle을 놓치고 모든 capture가 1 cycle late되는 버그가 있어서
    //     combinational decode 방식으로 수정 (weight_addr가 현재 bus mem[weight_addr]과 일치)
    // =========================================================================
    reg [4:0]       weight_addr;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn)        weight_addr <= 0;
        else if (i_w_rd_en) weight_addr <= weight_addr + 1;
        else                weight_addr <= 0;
    end

    // weight phase(0~17): PE capture / bias phase(18~19): no PE capture, r_bias latch
    wire is_w_phase = i_w_rd_en && (weight_addr < WEIGHT_DEPTH);
    wire [OUT_CH-1:0] w_weight_group_en =
        is_w_phase ? { {4{weight_addr[0]}}, {4{~weight_addr[0]}} } : {OUT_CH{1'b0}};
    wire [8:0]        w_weight_tap_en   =
        is_w_phase ? (9'b1 << weight_addr[4:1]) : 9'd0;

    // Bias load: weight_addr 18 -> oc 0~3, 19 -> oc 4~7
    reg signed [15:0] r_bias [0:OUT_CH-1];
    integer i;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            for(i = 0; i<OUT_CH; i=i+1) r_bias[i] <= 0;
        end else if (i_w_rd_en && (weight_addr >= WEIGHT_DEPTH)) begin
            for(i=0; i<4; i=i+1) begin
                r_bias[ {weight_addr[0], i[1:0]} ] <= i_weight_bram_data[DATA_BIT*i +:DATA_BIT];
            end
        end
    end

    // =========================================================================
    // 2. 1 Line Buffer & 8 PE Groups Generate (Broadcast)
    // =========================================================================
    wire [143:0]       w_line_data;
    wire               w_line_valid;
    wire               w_line_rd_done;
    wire               w_img_done;

    // L1: in_Ch 1개 (Line buffer LUT 최적화해서 병렬처리해도 부담 낮긴 함)
    line_buffer_improved #(
        .IMG_WIDTH(152),
        .WIN_ROW(3),
        .WIN_COL(3),
        .DATA_BIT(16)
    ) u_line_buffer (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (i_IDLE_rst),
        .i_input_valid  (i_input_valid),
        .i_input_data   (i_pixel_data),
        .o_line_data    (w_line_data),
        .o_line_valid   (w_line_valid),
        .o_line_rd_done (w_line_rd_done),
        .o_img_done     (w_img_done)
    );

    wire               w_pe_valid [0:OUT_CH-1];
    wire signed [20:0] w_partial [0:OUT_CH-1];
    wire [OUT_CH-1:0]  w_pe_done;

    genvar j;
    generate
        for (j = 0; j < OUT_CH; j = j + 1) begin : gen_pe_groups
            pe_group #(
                .IN_CN(1) // L2 방식에 매칭
            ) pe_inst (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                // 라인버퍼 data는 out_Ch 8개 PE group 공통
                .i_line_valid   (w_line_valid),
                .i_line_data    (w_line_data),
                .i_weight       (i_weight_bram_data[16*(j%4) +: 16]),
                .i_w_tap_en     ({9{w_weight_group_en[j]}} & w_weight_tap_en),
                .i_line_done    (w_line_rd_done),
                .o_valid        (w_pe_valid[j]),
                .o_partial      (w_partial[j]), // L1은 이게 최종 Conv 합산값임(추가 adder_tree 필요 x)
                .o_pe_done      (w_pe_done[j])
            );
        end
    endgenerate

    // =========================================================================
    // 3. Bias & ReLU
    // =========================================================================
    wire [(OUT_CH*DATA_BIT)-1:0] w_final_concat;

    generate
        for (j = 0; j < OUT_CH; j = j + 1) begin : gen_relu
            wire signed [21:0] w_sum = w_partial[j] + r_bias[j];
            assign w_final_concat[16*j +: 16] =
                (w_sum[21])     ? 16'd0       :
                (|w_sum[20:15]) ? 16'h7FFF    :
                                  w_sum[15:0];
        end
    endgenerate

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            o_pixel_valid <= 0;
            o_uram_data   <= 0;
        end else begin
            o_pixel_valid <= w_pe_valid[0]; // 모든 PE valid 신호 동일
            o_uram_data   <= w_final_concat;
        end
    end

    // =========================================================================
    // 4. img_done propagation (drain-aligned for FSM i_adder_done)
    //    L1 pipeline depth from line_buffer.o_img_done:
    //      pe_group: 2clk + output register: 1clk = 3clk
    // =========================================================================
    delay_shift #(
        .DELAY(2+1)
    ) d_l1_img_done (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(w_img_done),
        .dout(o_img_done)
    );

endmodule
