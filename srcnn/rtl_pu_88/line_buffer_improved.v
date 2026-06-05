module line_buffer_improved #(
    parameter IMG_WIDTH   = 152,
    parameter WIN_ROW     = 3,  
    parameter WIN_COL     = 3,  
    parameter DATA_BIT    = 16,  
   
    // 자동 계산
    parameter LINE_SIZE   = IMG_WIDTH * DATA_BIT,
    parameter WIN_SIZE    = WIN_ROW * WIN_COL * DATA_BIT
)(
    input  wire                  i_clk,
    input  wire                  i_rstn,
    input  wire                  i_IDLE_rst,
    input  wire                  i_input_valid,
    input  wire signed [DATA_BIT-1:0] i_input_data,

    output reg signed [WIN_SIZE-1 : 0] o_line_data,
    output reg                         o_line_valid,
    output reg                         o_line_rd_done,
    output reg                         o_img_done
);

    // -------------------------------------------------------------------------
    // 1. 순수 시프트 레지스터 (가장 우측 LSB로 최신 데이터가 들어옴)
    // -------------------------------------------------------------------------
    (* shreg_extract = "yes" *) reg [LINE_SIZE-1:0] r_line0;
    (* shreg_extract = "yes" *) reg [LINE_SIZE-1:0] r_line1;
    (* shreg_extract = "yes" *) reg [LINE_SIZE-1:0] r_line2;
   
    //reg [LINE_SIZE-1:0] r_line0;
    //reg [LINE_SIZE-1:0] r_line1;
    //reg [LINE_SIZE-1:0] r_line2;
    always @(posedge i_clk) begin
        if(~i_rstn) begin
            r_line0 <= 0;
            r_line1 <= 0;
            r_line2 <= 0;
        end else if(i_IDLE_rst) begin
            r_line0 <= 0;
            r_line1 <= 0;
            r_line2 <= 0;
        end else begin
            if (i_input_valid) begin
                r_line0 <= {r_line0[LINE_SIZE-1 - DATA_BIT : 0], i_input_data};
                r_line1 <= {r_line1[LINE_SIZE-1 - DATA_BIT : 0], r_line0[LINE_SIZE-1 -: DATA_BIT]};
                r_line2 <= {r_line2[LINE_SIZE-1 - DATA_BIT : 0], r_line1[LINE_SIZE-1 -: DATA_BIT]};
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. 현재 입력 중인 픽셀의 절대 좌표 카운터 (0 ~ 151)
    // -------------------------------------------------------------------------
    reg [$clog2(IMG_WIDTH)-1:0] r_col;
    reg [15:0]                  r_row;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_col <= 0;
            r_row <= 0;
        end else if (i_IDLE_rst) begin
            r_col <= 0;
            r_row <= 0;
        end else if (i_input_valid) begin
            if (r_col == IMG_WIDTH - 1) begin
                r_col <= 0;
                r_row <= r_row + 1;
            end else begin
                r_col <= r_col + 1;
            end
        end
    end


    // 현재 입력된 픽셀이 최소 3번째 줄(row>=2)이고, 최소 3번째 칸(col>=2)인가?
    wire w_valid_in_window = (r_row >= WIN_ROW - 1) && (r_col >= WIN_COL - 1);
    reg r_valid;
    // 현재 입력된 픽셀이 줄의 마지막 픽셀인가? (col==151)
    wire w_done_in_window  = (r_row >= WIN_ROW - 1) && (r_col == IMG_WIDTH - 1);
    wire w_img_done        = (r_row == IMG_WIDTH);
    reg  r_done;
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_valid        <= 1'b0; 
            r_done         <= 1'b0; 
            o_line_valid   <= 1'b0;
            o_line_rd_done <= 1'b0;
            o_img_done     <= 1'b0;
            //r_valid_in_window   <= 1'b0;
            //r_done_in_window    <= 1'b0;
        end else if (i_IDLE_rst) begin
            r_valid        <= 1'b0; 
            r_done         <= 1'b0; 
            o_line_valid   <= 1'b0;
            o_line_rd_done <= 1'b0;
            o_img_done     <= 1'b0;
            //r_valid_in_window   <= 1'b0;
            //r_done_in_window    <= 1'b0;
        end else begin
            //r_valid_in_window    <= (r_row >= WIN_ROW - 1) && (r_col >= WIN_COL - 1);
            //r_done_in_window     <= (r_row >= WIN_ROW - 1) && (r_col == IMG_WIDTH - 1);
            // i_input_valid가 들어온 다음 클럭에 데이터가 안착하므로,
            // valid 신호도 똑같이 1클럭 지연시켜서 출력
            /*
            // no en need to valid -> r_valid & r_done properly work
            if (i_input_valid) begin
                o_line_valid   <= r_valid_in_window;
                o_line_rd_done <= r_done_in_window;
            end else begin
                o_line_valid   <= 1'b0;
                o_line_rd_done <= 1'b0;
            end
            */ 
            r_valid        <= w_valid_in_window;
            r_done         <= w_done_in_window;
            o_line_valid   <= r_valid;
            o_line_rd_done <= r_done;
            o_img_done     <= w_img_done;
        end
    end

    // -------------------------------------------------------------------------
    // 4. 고정 윈도우 출력
    // -------------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_line_data <= 0;
        end else if (i_IDLE_rst) begin
            o_line_data <= 0;
        end else if (r_valid) begin
            o_line_data <= 
            //{ r_line2[DATA_BIT*1-1 -: 16], r_line2[DATA_BIT*2-1 -:16], r_line2[DATA_BIT*3-1 -: 16],
            //  r_line1[DATA_BIT*1-1 -: 16], r_line1[DATA_BIT*2-1 -:16], r_line1[DATA_BIT*3-1 -: 16],
            //  r_line0[DATA_BIT*1-1 -: 16], r_line0[DATA_BIT*2-1 -:16], r_line0[DATA_BIT*3-1 -: 16] };
            { r_line2[47:0],
              r_line1[47:0],
              r_line0[47:0] };
        end
    end

endmodule