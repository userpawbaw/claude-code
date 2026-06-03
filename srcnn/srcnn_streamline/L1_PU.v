`timescale 1ns / 1ps

module PU_L1 #(
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
    output reg  [(OUT_CH*DATA_BIT)-1:0] o_uram_data
);

    // =========================================================================
    // 1. Weight & Bias Enable Control Logic (L2와 동일한 초경량 디코더)
    // =========================================================================
    reg [4:0]       weight_addr; // 0~17: Weight, 18~19: Bias
    reg [OUT_CH-1:0] r_weight_group_en;
    reg [8:0]       r_weight_tap_en;
    
    reg signed [15:0] r_bias [0:OUT_CH-1]; // 8개의 Bias 레지스터
    integer i;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr       <= 0;
            r_weight_group_en <= 0;
            r_weight_tap_en   <= 0;
            for(i = 0; i<OUT_CH; i=i+1) begin
                r_bias[i] = 0;
            end
        end else begin
            if (i_w_rd_en) begin 
                if (weight_addr < WEIGHT_DEPTH) begin
                    // Weight 로딩 구간 
                    r_weight_group_en <= { {4{weight_addr[0]}} , {4{~weight_addr[0]}} };
                    r_weight_tap_en   <= 9'b1 << weight_addr[4:1]; 
                end else if (weight_addr >= WEIGHT_DEPTH) begin
                    // 19번째 클럭: Bias 0~3 로딩
                    r_weight_group_en <= 0; r_weight_tap_en <= 0;
                    for(i=0; i<4; i=i+1) begin
                        // 18: 0~3, 19: 4~7
                        r_bias[ {weight_addr[0], i[1:0]} ] = i_weight_bram_data[DATA_BIT*i +:DATA_BIT];
                    end
                end
                weight_addr <= weight_addr + 1;
            end else if(weight_addr == W_BRAM_DEPTH-1)  begin // 꺼지면 초기화
                weight_addr       <= 0;
                r_weight_group_en <= 0;
                r_weight_tap_en   <= 0;
            end
        end
    end

    // =========================================================================
    // 2. 1 Line Buffer & 8 PE Groups Generate (Broadcast 구조)
    // =========================================================================
    wire [143:0]       w_line_data;
    wire               w_line_valid;
    wire               w_line_rd_done;
    
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
        .o_img_done     ()
    );

    wire               w_pe_valid [0:OUT_CH-1];
    wire signed [20:0] w_partial [0:OUT_CH-1];
    wire [OUT_CH-1:0]  w_pe_done;

    genvar j;
    generate
        for (j = 0; j < OUT_CH; j = j + 1) begin : gen_pe_groups
            pe_group_changed #(
                .IN_CN(1) // L2 방식에 매칭
            ) pe_inst (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                // 라인버퍼 data는 out_Ch 8개 PE group 공통
                .i_line_valid   (w_line_valid),
                .i_line_data    (w_line_data), 
                
                // 0-LUT 가중치 정적 인덱싱
                .i_weight       (i_weight_bram_data[16*(j%4) +: 16]), 
                
                .i_w_group_en   (r_weight_group_en[j]),
                .i_w_tap_en     (r_weight_tap_en),
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
            
            //ReLU or clipping 
            assign w_final_concat[16*j +: 16] = (w_sum[21]) ? 16'd0 : w_sum[15:0]; // 128bit(URAM port width*2) 에 대해 동일 위치의 out_CH 픽셀 packing. (LSB부터 16개씩)
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

endmodule
