module L2_PU #(
    parameter IN_CH    = 8,
    parameter W_PIXEL_NUM = 4,
    parameter DATA_BIT = 16,
    parameter W_BRAM_WIDTH = W_PIXEL_NUM * DATA_BIT 
)(
    input  wire                     i_clk,
    input  wire                     i_rstn,
    input  wire                     i_IDLE_rst,
    
    
    // 1. Feature Map Input (From L1 -> L2 URAM, 128-bit)
    // L2 -> parallel to in_ch. 
    // matching PE_group(3x3) & line_buffer # to in_ch, for parallel in_ch feature map conv2d.
    // which lead to less complex bias & relu process. 
    // -> no time partition, just pipelining through by gathering 8 in_ch conv2d output(each 16bit) to 8-1 adder tree -> bias & relu.
    // URAM save format == L1 save format  o_KOIN-> 이미지 번호 K, 출력채널O, 입력채널I의 output feature map N번째 pixel 
    //  o0000 o0100 o0200 ... o0700
    // ... (1st img done)
    //  o1000 o1100 o1200 ... o1700
    
    
    input  wire                     i_input_valid,
    input  wire [IN_CH*DATA_BIT-1:0] i_uram_data, 
    
    // 2. Weight & Bias Input (From FSM & Weight BRAM)
    // weight bram 폭은 64bit로, save format은 다음과 같을 것으로 기대.
    // w_OIN->출력채널O, 입력채널I의 커널 가중치 중 N번쨰 tap
        ////L2의 경우////
        //w000 w010 w020 w030
        //w040 w050 w060 w070
        //...
        //w008 w018 w028 w038
        //w048 w058 w068 w078
        //b000 0000 0000 0000 (out_ch0 bias, zero packing) 
        //___________________(다음 출력 채널값)
        //w100 w110 w120 w130
        //...
    // L2: weight kernal per out_ch -> in_ch(8) * 3x3 * 16bit, 
    // bram port width: 4 * 16bit
    // => addr:  out_ch(4) * 2 * 3x3  
        
    //input  wire                         i_w_rd_valid, // FSM의 BRAM rd_en + 1clk delay
    input  wire                         i_w_rd_en, // FSM의 BRAM rd_en (changed for PE group en logic)
    input  wire [W_BRAM_WIDTH-1 : 0]    i_weight_bram_data,  // 64: 36Kb sdp bram 1개 width
    
    input  wire                         i_bias_en, // FSM이 보내주는 bias en(after weight, bram data -> bias 0000 0000 0000)
    
    // 3. Final Output (To L2 Output URAM)
    output reg                          o_pixel_valid,
    output reg  [15:0]                  o_pixel_data,
    
    output wire                          o_img_done
);
    localparam MEM_ADDR = 15;
    



    // --------------------------------------------------------
    // 8-Channel Line Buffers & PE Groups Generate
    // --------------------------------------------------------
    wire [143:0] w_line_data [0:IN_CH-1];
    wire         w_line_valid [0:IN_CH-1];
    wire         w_pe_valid [0:IN_CH-1];
    wire signed [20:0] w_partial [0:IN_CH-1];
    
            // out_ch에 따른 weight mux 
 // =========================================================================
    // 1. FSM Instance
    // =========================================================================
    wire w_img_done; 
    wire w_line_rd_done;
    
    FSM_pad #(
        .I_NUM(152),
        .MEM_ADDR_WIDTH(MEM_ADDR)
    ) fsm_0_pad (
        .i_clk                     (i_clk),  
        .i_rstn                    (i_rstn), 
        .i_start                   (i_start),  
        .i_line_rd_done            (w_line_rd_done),  
        .i_adder_done              (pe_done), 
        .i_uram_we                 (w_uram_we),
    
        .o_layer_cnt               (layer_cnt),
        .o_weight_bram_rd_en       (w_rd_en),  
        .o_weight_bram_rd_addr     (w_rd_addr),  

        .o_input_bram_rd_en        (i_rd_en),  
        .o_input_bram_rd_addr      (i_rd_addr),  
       
        .o_IDLE_rst                (w_IDLE_rst),
        
        .o_intermid_uram_rd_en     (w_intermid_uram_rd_en),
        .o_intermid_uram_rd_addr   (w_intermid_uram_rd_addr),
        .fifo_rd_en                (w_fifo_rd_en),

        .o_input_bram_rd_line_done (w_input_rd_done),  
        .o_is_pad                  (w_is_pad),
        .o_is_pad_valid            (w_is_pad_valid),  
        .o_line_done               (w_line_done),    
        .o_line_shift_en           (line_shift_en),  
        .o_done                    (w_img_done)   
    );
    // =========================================================================
    //  Weight Address Generation
    // =========================================================================
    reg [5:0]       weight_addr;
    reg [IN_CH-1:0] r_weight_group_en;
    reg [8:0]       r_weight_tap_en; // one hot en
 
    integer k;   
    // 2) changed en logic to reg. changed input w_valid to w_bram_en
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr         <= 0;
            r_weight_group_en     <= 0;
            r_weight_tap_en       <= 9'b1;
        end else begin
            if (i_w_rd_en) begin // FSM controlled weight valid, expected to be high 2 * 3x3 (18)clk per out_ch. 
                weight_addr         <= weight_addr + 1;
                r_weight_group_en     <= { {4{weight_addr[0]}} , {4{~weight_addr[0]}} };    // addr pulse++ on 18clk                                     
                                                                                            // addr[0]: 1~4, addr[1]: 5~8, addr[2]: 1~4, addr[3}: 5~8 ...
                r_weight_tap_en       <= weight_addr[0] ? r_weight_tap_en << 1 : r_weight_tap_en;                   // addr[4:1]: 0~8 change for 18clk by 2clk period  
            end else begin                                                                                          // addr[0]: group_en, changed every 1clk 
                weight_addr         <= 0;
                r_weight_group_en     <= 0;
                r_weight_tap_en       <= 9'b1;
            end
        end
    end
    // en select logic
    /*
    // 1) comb logic -> timing issue concern
    always @(*) begin
        weight_group_en = 0;
        weight_tap_en   = 0;        
        
        weight_group_en = { {4{weight_addr[0]}} , {4{~weight_addr[0]}} };   // addr pulse++ on 18clk
                                                                            // addr[0]: 1~4, addr[1]: 5~8, addr[2]: 1~4, addr[3}: 5~8 ...
        for (k=0; k<9; k=k+1) begin
            weight_tap_en[k] = i_w_rd_valid ? (weight_addr[4:1] == k[3:0]) : 0; // addr[4:1]: 0~8, addr[0]: group_en
        end
    end
    */

    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_ch
            line_buffer_improved #(
                .IMG_WIDTH(152),
                .WIN_ROW(3),
                .WIN_COL(3),
                .DATA_BIT(16)
            ) u_line_buffer (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (w_IDLE_rst), //
                .i_input_valid  (w_input_valid),
                .i_input_data   (i_uram_data[16*i +: 16]), // uram data는 MSB first packing... order of pe_group weight should be align
                                                           // uram data ex) in_ch7 in_ch6 in_ch5 in_ch_4 .... in_ch0 (i번째가 i- in_ch PE_group data)
                .o_line_data    (w_line_data[i]),  // line_buff output도 987 654 321 순에 맞춰져 있음.(in PE group.v, aligned with 16*i +: 16 
                .o_line_valid   (w_line_valid[i]),  // expect to be same all
                .o_line_rd_done (w_line_rd_done),     // ''
                .o_img_done     (w_img_done)
            );

            pe_group pe_inst (  // from line_buff delay: +3clk 
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_line_valid   (line_valid),
                .i_line_data    (line_data),
                .i_weight       (i_weight_bram_data[16*(i[1:0]) +: 16]), // 각자에 맞는 16bit weight.  # of PE group align -> i%4에 따라 0~15, 16~32, ... 
                // redundant //  .i_w_group_en   (r_weight_group_en[i]),
                .i_w_tap_en     (r_weight_group_en[i] & r_weight_tap_en[i]),
                .i_line_done    (w_line_rd_done),
                .o_valid        (adder_val_final),
                .o_partial      (r_add_total),
                .o_pe_done      (pe_done)
            );
        end
    endgenerate

    // --------------------------------------------------------
    // [3] Channel Integration Adder Tree (공간 병렬 8채널 합산)
    // --------------------------------------------------------
    // from line_buff delay: +3clk +3clk
    
    reg signed [22:0] r_add_stage1 [0:3];
    reg signed [23:0] r_add_stage2 [0:1];
    reg signed [24:0] r_add_stage3;
    reg               r_valid_stage1, r_valid_stage2, r_valid_stage3;

    always @(posedge i_clk) begin
        // Stage 1
        r_add_stage1[0] <= w_partial[0] + w_partial[1];
        r_add_stage1[1] <= w_partial[2] + w_partial[3];
        r_add_stage1[2] <= w_partial[4] + w_partial[5];
        r_add_stage1[3] <= w_partial[6] + w_partial[7];
        r_valid_stage1  <= w_pe_valid[0]; 

        // Stage 2
        r_add_stage2[0] <= r_add_stage1[0] + r_add_stage1[1];
        r_add_stage2[1] <= r_add_stage1[2] + r_add_stage1[3];
        r_valid_stage2  <= r_valid_stage1;

        // Stage 3
        r_add_stage3    <= r_add_stage2[0] + r_add_stage2[1];
        r_valid_stage3  <= r_valid_stage2;
    end

    // --------------------------------------------------------
    // [4] Bias Latch & ReLU Pipeline
    // --------------------------------------------------------
    // from line_buff delay: +3clk +3clk +2clk
    reg signed [15:0] r_bias;
    reg signed [31:0] r_final_sum;
    reg               r_final_valid;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias        <= 0;
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
        end else begin
            if (i_bias_en) r_bias <= i_weight_bram_data[63 -: DATA_BIT]; 

            r_final_sum   <= r_add_stage3 + r_bias;
            r_final_valid <= r_valid_stage3;

            o_pixel_valid <= r_final_valid;
            
            // ReLU & clipping
            if (r_final_sum[31]) begin
                o_pixel_data <= 16'd0; // 음수면 0
            end else begin  // if positive
                            // (r_final_sum > Q8.8 max value) => clipping. else select 16bit window while keeps sign bit .
                    o_pixel_data <= (r_final_sum[24] == 1'b1) ? 16'h8FFF : {r_final_sum[31], r_final_sum[22:8]};
            end
        end
    end
    
        // --------------------------------------------------------
    // [5] img_done propagation (for FSM)
    // --------------------------------------------------------
    // from line_buff delay: +3clk +3clk +2clk
    delay_shift #(
    .DELAY(3+3+2)
    )d3_line_buff_done_to_PU (
    .clk(i_clk),
    .rst(~i_rstn),
    .en (1'b1),
    .din(w_img_done),
    .dout(o_img_done)
    );

endmodule