module L2_PU #(
    parameter IN_CH    = 8,
    parameter W_PIXEL_NUM = 4,
    parameter DATA_BIT = 16,
    parameter W_BRAM_WIDTH = W_PIXEL_NUM * DATA_BIT 
)(
    input  wire                     i_clk,
    input  wire                     i_rstn,
    input  wire                     i_IDLE_rst,
    input  wire                     i_start,
    
    
    // 1. Feature Map Input (From L1 -> L2 URAM, 128-bit)
    // L2 -> parallel to in_ch. 
    // matching PE_group(3x3) & line_buffer # to in_ch, for parallel in_ch feature map conv2d.
    // URAM save format == L1 save format  o_KOIN-> 이미지 K, 출력채널 O, 입력채널 I의 feature map N번째 pixel
    //  o0000 o0100 o0200 ... o0700
    //  o1000 o1100 o1200 ... o1700
    input  wire                     i_input_valid,
    input  wire [IN_CH*DATA_BIT-1:0] i_uram_data, 
    
    // 2. Weight & Bias Input (From FSM & Weight BRAM)
    // weight bram port width: 64bit = 4 * 16bit
    // bias_en은 내부 FSM이 r_word_idx 기반으로 생성 (i_bias_en 외부 포트 제거)
    input  wire                         i_w_rd_en,
    input  wire [W_BRAM_WIDTH-1 : 0]    i_weight_bram_data,
    
    // 3. Final Output (To L2 Output URAM)
    output reg                          o_pixel_valid,
    output reg  [15:0]                  o_pixel_data,
    
    output wire                          o_img_done
);
    localparam MEM_ADDR = 15;

    // --------------------------------------------------------
    // Internal wires (FSM <-> sub-modules)
    // --------------------------------------------------------
    wire                       w_IDLE_rst;
    wire                       w_uram_we;
    wire                       w_input_rd_done;
    wire                       w_is_pad;
    wire                       w_is_pad_valid;
    wire                       w_line_done;
    wire                       w_line_shift_en;
    wire                       w_intermid_uram_rd_en;
    wire [MEM_ADDR-3:0]        w_intermid_uram_rd_addr;
    wire                       w_fifo_rd_en;
    wire                       w_rd_en;
    wire [MEM_ADDR-1:0]        w_rd_addr;
    wire                       w_i_rd_en;
    wire [MEM_ADDR-1:0]        w_i_rd_addr;
    wire                       w_bias_en;

    // --------------------------------------------------------
    // 8-Channel Line Buffers & PE Groups arrays
    // --------------------------------------------------------
    wire [143:0]       w_line_data  [0:IN_CH-1];
    wire               w_line_valid [0:IN_CH-1];
    wire signed [35:0] w_partial    [0:IN_CH-1];   // ★ Q16.16 (36-bit)
    wire               w_pe_valid   [0:IN_CH-1];
    wire               w_pe_done    [0:IN_CH-1];
    wire               w_line_rd_done;
    wire               w_img_done;

    // =========================================================================
    // 1. FSM Instance
    // =========================================================================
    FSM_pad #(
        .I_NUM(152),
        .MEM_ADDR_WIDTH(MEM_ADDR)
    ) fsm_0_pad (
        .i_clk                     (i_clk),  
        .i_rstn                    (i_rstn), 
        .i_start                   (i_start),  
        .i_line_rd_done            (w_line_rd_done),  
        .i_adder_done              (w_pe_done[0]),     // any channel's pe_done (all aligned)
        .i_uram_we                 (w_uram_we),
    
        .o_weight_bram_rd_en       (w_rd_en),  
        .o_weight_bram_rd_addr     (w_rd_addr),  
        .o_bias_en                 (w_bias_en),

        .o_input_bram_rd_en        (w_i_rd_en),  
        .o_input_bram_rd_addr      (w_i_rd_addr),  
       
        .o_IDLE_rst                (w_IDLE_rst),
        
        .o_intermid_uram_rd_en     (w_intermid_uram_rd_en),
        .o_intermid_uram_rd_addr   (w_intermid_uram_rd_addr),
        .fifo_rd_en                (w_fifo_rd_en),

        .o_input_bram_rd_line_done (w_input_rd_done),  
        .o_is_pad                  (w_is_pad),
        .o_is_pad_valid            (w_is_pad_valid),  
        .o_line_done               (w_line_done),    
        .o_line_shift_en           (w_line_shift_en),  
        .o_done                    (w_img_done)   
    );

    // =========================================================================
    //  Weight Address Generation
    // =========================================================================
    reg [5:0]       weight_addr;
    reg [IN_CH-1:0] r_weight_group_en;    // PE group en 
    reg [8:0]       r_weight_tap_en; // one hot en for tap (each pe)

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr         <= 0;
            r_weight_group_en   <= 0;
            r_weight_tap_en     <= 9'b1;
        end else begin
            if (i_w_rd_en) begin
                weight_addr         <= weight_addr + 1;
                r_weight_group_en   <= { {4{weight_addr[0]}} , {4{~weight_addr[0]}} };    // clk:weight_data(W_In_Out_Tap) ->  0: w000 w100 w200 w300, 1: w400 w500 w600 w700, 2: w001 w101 w201 w301  
                r_weight_tap_en     <= weight_addr[0] ? (r_weight_tap_en << 1) : r_weight_tap_en;        // i_w_rd_en이 18clk동안 켜질 때 2clk마다 << 1 (one hot)해서 tap 맞춤
            end else begin
                weight_addr         <= 0;
                r_weight_group_en   <= 0;
                r_weight_tap_en     <= 9'b1;
            end
        end
    end

    genvar i;
    generate
        for (i = 0; i < IN_CH; i = i + 1) begin : gen_ch
            // padding mux per ch (1ch top 방식)
            wire signed [15:0] w_lb_data;
            wire               w_lb_valid;
            assign w_lb_data  = w_is_pad_valid ? 16'h0 : i_uram_data[16*i +: 16];
            assign w_lb_valid = w_is_pad_valid ? 1'b1 : i_input_valid;

            line_buffer_improved #(
                .IMG_WIDTH(152),
                .WIN_ROW(3),
                .WIN_COL(3),
                .DATA_BIT(16)
            ) u_line_buffer (
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_IDLE_rst     (w_IDLE_rst),
                .i_input_valid  (w_lb_valid),
                .i_input_data   (w_lb_data),
                .o_line_data    (w_line_data[i]),
                .o_line_valid   (w_line_valid[i]),
                .o_line_rd_done (w_line_rd_done),
                .o_img_done     (w_img_done)
            );

            pe_group pe_inst (  // from line_buff delay: +3clk 
                .i_clk          (i_clk),
                .i_rstn         (i_rstn),
                .i_line_valid   (w_line_valid[i]),
                .i_line_data    (w_line_data[i]),
                .i_weight       (i_weight_bram_data[16*(i[1:0]) +: 16]), // i%4 -> 0~15, 16~31, ...
                .i_w_tap_en     ({9{r_weight_group_en[i]}} & r_weight_tap_en), // gate full 9-bit tap_en with group_en
                .i_line_done    (w_line_rd_done),
                .o_valid        (w_pe_valid[i]),
                .o_partial      (w_partial[i]),
                .o_pe_done      (w_pe_done[i])
            );
        end
    endgenerate

    // --------------------------------------------------------
    // [3] Channel Integration Adder Tree (공간 병렬 8채널 합산, Q16.16)
    //     stage1 : pair sum 4 × 37-bit
    //     stage2 : pair sum 2 × 38-bit
    //     stage3 : sum     1 × 39-bit  ← final Q16.16
    // --------------------------------------------------------
    // from line_buff delay: +3clk +3clk
    reg signed [36:0] r_add_stage1 [0:3];
    reg signed [37:0] r_add_stage2 [0:1];
    reg signed [38:0] r_add_stage3;
    reg               r_valid_stage1, r_valid_stage2, r_valid_stage3;

    always @(posedge i_clk) begin
        // Stage 1 : 36 + 36 → 37
        r_add_stage1[0] <= {w_partial[0][35], w_partial[0]} + {w_partial[1][35], w_partial[1]};
        r_add_stage1[1] <= {w_partial[2][35], w_partial[2]} + {w_partial[3][35], w_partial[3]};
        r_add_stage1[2] <= {w_partial[4][35], w_partial[4]} + {w_partial[5][35], w_partial[5]};
        r_add_stage1[3] <= {w_partial[6][35], w_partial[6]} + {w_partial[7][35], w_partial[7]};
        r_valid_stage1  <= w_pe_valid[0];

        // Stage 2 : 37 + 37 → 38
        r_add_stage2[0] <= {r_add_stage1[0][36], r_add_stage1[0]} + {r_add_stage1[1][36], r_add_stage1[1]};
        r_add_stage2[1] <= {r_add_stage1[2][36], r_add_stage1[2]} + {r_add_stage1[3][36], r_add_stage1[3]};
        r_valid_stage2  <= r_valid_stage1;

        // Stage 3 : 38 + 38 → 39 Q16.16
        r_add_stage3    <= {r_add_stage2[0][37], r_add_stage2[0]} + {r_add_stage2[1][37], r_add_stage2[1]};
        r_valid_stage3  <= r_valid_stage2;
    end

    // --------------------------------------------------------
    // [4] (>>>8) + bias(Q8.8) → ReLU + upper saturate
    //   README spec : (sum_q1616 >>> 8) + sext(bias_q88) → sat_relu
    //   r_add_stage3 (39-bit) >>> 8 = 31-bit Q8.8 → sext to 32-bit → +bias_q88
    // --------------------------------------------------------
    function automatic [15:0] sat_relu(input signed [31:0] v);
        if (v[31])           sat_relu = 16'h0000;
        else if (|v[30:15])  sat_relu = 16'h7FFF;
        else                 sat_relu = v[15:0];
    endfunction

    reg signed [15:0] r_bias;
    reg signed [31:0] r_sum_q88;
    reg               r_final_valid;

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_bias        <= 0;
            o_pixel_valid <= 0;
            o_pixel_data  <= 0;
            r_sum_q88     <= 0;
            r_final_valid <= 0;
        end else begin
            if (w_bias_en) r_bias <= i_weight_bram_data[63 -: DATA_BIT];

            // 39-bit Q16.16 >>>8 → take low 32 bits as Q8.8 with int extended
            r_sum_q88     <= $signed(r_add_stage3[38:8])
                           + {{16{r_bias[15]}}, r_bias};
            r_final_valid <= r_valid_stage3;

            o_pixel_valid <= r_final_valid;
            o_pixel_data  <= sat_relu(r_sum_q88);
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
