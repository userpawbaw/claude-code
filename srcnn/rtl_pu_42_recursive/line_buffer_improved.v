module line_buffer_improved #(
    parameter IMG_WIDTH   = 152,
    parameter WIN_ROW     = 3,  
    parameter WIN_COL     = 3,  
    parameter DATA_BIT    = 16,  
   
    // derived
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
    // 1. Pure shift registers (newest sample enters at the LSB end)
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
    // 2. Absolute (row, col) counter for the currently-incoming pixel (0 ~ 151)
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


    // Is the current pixel at least in the 3rd row (row>=2) and 3rd column (col>=2)?
    wire w_valid_in_window = (r_row >= WIN_ROW - 1) && (r_col >= WIN_COL - 1);
    reg r_valid;
    // Is the current pixel the last column of the row? (col==151)
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
            // Data is latched on the clock after i_input_valid, so the valid
            // signal is delayed by 1 cycle to align with the output.
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
    // 4. Fixed window output
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