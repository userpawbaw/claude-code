`timescale 1ns / 1ps

module top(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,
    output wire        o_done,
    output wire        o_output_valid, 
    output wire [63:0] o_output,        
    output wire        o_line_rd_done  
);
    localparam MEM_ADDR = 15;

    wire    w_is_pad;
    wire    w_is_pad_valid;
    wire    w_input_rd_done;   
    wire    w_line_done;
    wire    line_shift_en;

    wire                       w_IDLE_rst;
    wire                       w_intermid_uram_rd_en;
    wire [MEM_ADDR - 3:0]      w_intermid_uram_rd_addr;
    wire                       w_fifo_rd_en;

    wire                        w_rd_en;
    wire [MEM_ADDR-1:0]         w_rd_addr;
    wire                        w_rd_valid;
    wire signed [15:0]          w_rd_dout;

    wire                        i_rd_en;
    wire [MEM_ADDR-1:0]         i_rd_addr;
    wire                        i_rd_valid;
    wire signed [15:0]          i_rd_dout;

    wire [1:0]                  layer_cnt;
    wire [63:0]                 w_intermid_uram_rd_dout;

    wire signed [15:0]          w_fifo_dout;
    wire                        w_fifo_valid;
    wire                        w_fifo_empty;
    wire                        w_fifo_full;

    wire signed [15:0]          w_layer_in_data;
    wire                        w_layer_in_valid;

    wire signed [15:0]          w_lb_data;
    wire                        w_lb_valid;
    wire [16 * 9 - 1:0]         line_data;
    wire                        line_valid;
    wire                        line_rd_done;
    assign o_line_rd_done = line_rd_done;

    wire                        adder_val_final;
    wire signed [20:0]          r_add_total;
    wire                        pe_done;

    wire [63:0]                 w_output_uram;
    wire                        w_uram_we;
    reg  [MEM_ADDR-3:0]         output_uram_addr;
    assign o_output       = w_output_uram;
    assign o_output_valid = w_uram_we;

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
        .i_line_rd_done            (line_rd_done),  
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
        .o_done                    (o_done)   
    );

    // =========================================================================
    // 2. Memory Instances (BRAM & URAM)
    // =========================================================================
    simple_dual_port_bram #(
        .DEPTH(150*150),
        .INIT_FILE("E:\\test_0_hex.txt")
    ) i_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (i_rd_en),
        .wr_addr  (15'h0),
        .rd_addr  (i_rd_addr), 
        .wr_din   (16'h0),
        .rd_valid (i_rd_valid),
        .rd_dout  (i_rd_dout)
    );

    simple_dual_port_bram #(
        .INIT_FILE("C:\\Users\\J1\\fanbox\\Week9_DSD26_Basic_Practice6_Problem_Code\\init_file\\w_L1.txt")
    ) w1_bram (
        .clk      (i_clk),
        .wr_en    (1'b0),
        .rd_en    (w_rd_en),
        .wr_addr  (10'h0),
        .rd_addr  (w_rd_addr[9:0]), 
        .wr_din   (16'h0),
        .rd_valid (w_rd_valid),
        .rd_dout  (w_rd_dout)
    );

    simple_dual_port_uram #(
        .WIDTH      (64),
        .DEPTH      (8192), 
        .INIT_FILE  ("")     
    ) u_uram_block (
        .clk        (i_clk),
        .wr_en      (w_uram_we),
        .wr_addr    (output_uram_addr), 
        .wr_din     (w_output_uram),    
        .rd_en      (w_intermid_uram_rd_en),
        .rd_addr    (w_intermid_uram_rd_addr),
        .rd_valid   (),                 
        .rd_dout    (w_intermid_uram_rd_dout)                  
    );

    // =========================================================================
    // 3. Layer 2+ Data Feeding Path
    // =========================================================================
    fifo_generator_0 u_intermid_fifo (
        .clk            (i_clk),                  
        .srst           (~i_rstn),        
        .din            (w_intermid_uram_rd_dout), 
        .wr_en          (w_intermid_uram_rd_en),   
        .rd_en          (w_fifo_rd_en),            
        .dout           (w_fifo_dout),             
        .full           (w_fifo_full),                      
        .empty          (w_fifo_empty),             
        .wr_rst_busy    (),  
        .rd_rst_busy    ()  
    );

    delay_shift #(
        .DELAY(1)
    ) d1_fifo_en_to_fifo_valid (
        .clk(i_clk),
        .rst(~i_rstn),
        .en (1'b1),
        .din(w_fifo_rd_en),
        .dout(w_fifo_valid)
    );

    // =========================================================================
    // 4. Data Path Selection Mux & Zero Padding Controller
    // =========================================================================
    //assign w_layer_in_data  = (i_rd_en) ? i_rd_dout  : w_fifo_dout;
    //assign w_layer_in_valid = (i_rd_en) ? i_rd_valid : w_fifo_valid;
    //
    //assign w_lb_data   = w_is_pad_valid ? 16'h0000  : w_layer_in_data;
    //assign w_lb_valid  = w_is_pad_valid ? 1'b1      : w_layer_in_valid;
    // 수정됨: i_rd_en 대신 레이어 고정 상태(layer_cnt)를 기반으로 MUX 제어
    assign w_layer_in_data  = (layer_cnt == 2'd0) ? i_rd_dout  : w_fifo_dout;
    assign w_layer_in_valid = (layer_cnt == 2'd0) ? i_rd_valid : w_fifo_valid;

    assign w_lb_data   = w_is_pad_valid ? 16'h0000  : w_layer_in_data;
    assign w_lb_valid  = w_is_pad_valid ? 1'b1      : w_layer_in_valid;
    
    // =========================================================================
    // 5. Line Buffer Instance (정적 윈도우 스트리밍 구조 반영)
    // =========================================================================
    line_buffer_improved #(
        .IMG_WIDTH(152),
        .WIN_ROW(3),
        .WIN_COL(3),
        .DATA_BIT(16)
    ) u_line_buffer (
        .i_clk          (i_clk),
        .i_rstn         (i_rstn),
        .i_IDLE_rst     (w_IDLE_rst), //
        .i_input_valid  (w_lb_valid),
        .i_input_data   (w_lb_data),
        .o_line_data    (line_data),
        .o_line_valid   (line_valid),
        .o_line_rd_done (line_rd_done),
        .o_img_done     ()
    );

    // =========================================================================
    // 6. Weight Address Generation
    // =========================================================================
    reg [5:0] weight_addr;
    reg [8:0] weight_en;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            weight_addr <= 0;
        end else begin
            if (w_rd_valid) begin
                weight_addr <= weight_addr + 1;
            end else begin
                weight_addr <= 0;
            end
        end
    end

    integer k;
    always @(*) begin
        weight_en = 0;
        for (k=0; k<9; k=k+1) begin
            weight_en[k] = w_rd_valid ? (weight_addr == k[5:0]) : 0; 
        end
    end

    // =========================================================================
    // 7. PE Group Instance
    // =========================================================================
    pe_group u_pe_group_0 (
        .i_clk        (i_clk),
        .i_rstn       (i_rstn),
        .i_line_valid (line_valid),
        .i_line_data  (line_data),
        .i_weight     (w_rd_dout),
        .i_wen        (weight_en),
        .i_line_done  (line_rd_done),
        .o_valid      (adder_val_final),
        .o_partial    (r_add_total),
        .o_pe_done    (pe_done)
    );

    // =========================================================================
    // 8. 16비트 Adder 출력을 64비트 URAM Pack으로 조립하는 서브모듈
    // =========================================================================
    fifo_add_to_uram u_fifo_to_uram (
        .i_clk           (i_clk),
        .i_rstn          (i_rstn),
        .i_fifo_en       (adder_val_final),        
        .i_data          (r_add_total[15:0]),      
        .o_output_uram   (w_output_uram),
        .o_uram_we       (w_uram_we)
    );

    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            output_uram_addr <= 13'd0;
        end else begin
            if (w_uram_we) begin
                output_uram_addr <= output_uram_addr + 1'b1;
            end
        end
    end

endmodule