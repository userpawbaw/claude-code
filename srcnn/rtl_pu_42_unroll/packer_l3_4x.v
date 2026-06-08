// packer_l3_4x.v
//
// L3 4-px/clk stream → 4-px word packer.
//
// 입력 i_lane_valid 케이스 (line_buffer_wide_l3 출력) :
//   - 4'b1100 : 2 px valid (lane 2,3 = col 0,1 of row at K=0).
//   - 4'b1111 : 4 px valid (lane 0..3 = col 4K-2 .. 4K+1, K>=1).
//
// 내부 상태 :
//   r_cnt  : 0 또는 2.  save FIFO 에 들어있는 px 수.
//   r_save : 2 px (32 bit). cnt=2 일 때만 의미. MSB = older col.
//
// 전이 :
//   cnt=0, 2px → save ← input[31:0],  cnt=2,  emit=0
//   cnt=0, 4px → emit=input,          cnt=0
//   cnt=2, 2px → emit={save,input[31:0]}, cnt=0
//   cnt=2, 4px → emit={save,input[63:32]}, save ← input[31:0], cnt=2
//
//   i_flush (e.g. line_done at row end) :
//     cnt=2 → emit={save, 32'h0}, cnt=0      (last word of row, 2 px valid 만 의미)
//     cnt=0 → no-op
//
// 픽셀 비트 배치 (MSB = leftmost col, lane 0) :
//   i_data[63:48] = lane 0 = col 4K-2
//   i_data[47:32] = lane 1 = col 4K-1
//   i_data[31:16] = lane 2 = col 4K
//   i_data[15:0]  = lane 3 = col 4K+1
//
// 출력 word 도 같은 순서 : o_data[63:48] = 가장 왼쪽 col.

module packer_l3_4x #(
    parameter DATA_BIT  = 16,
    parameter LANE_NUM  = 4
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_en,           // i_data valid pulse
    input  wire [LANE_NUM*DATA_BIT-1:0]  i_data,         // 4 px (MSB=leftmost)
    input  wire [LANE_NUM-1:0]           i_lane_valid,   // 4'b1100 or 4'b1111
    input  wire                          i_flush,        // row-end flush

    output reg  [LANE_NUM*DATA_BIT-1:0]  o_data,
    output reg                           o_we
);
    localparam W2 = 2 * DATA_BIT;   // 32

    reg [1:0]    r_cnt;
    reg [W2-1:0] r_save;

    wire w_is_2px = (i_lane_valid == 4'b1100);
    wire w_is_4px = (i_lane_valid == 4'b1111);

    wire [W2-1:0] w_in_hi = i_data[LANE_NUM*DATA_BIT-1 -: W2];   // bits [63:32] (lane 0,1)
    wire [W2-1:0] w_in_lo = i_data[W2-1            -: W2];        // bits [31:0]  (lane 2,3)

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_cnt  <= 2'd0;
            r_save <= {W2{1'b0}};
            o_we   <= 1'b0;
            o_data <= {(LANE_NUM*DATA_BIT){1'b0}};
        end else begin
            o_we   <= 1'b0;
            o_data <= o_data;

            if (i_en) begin
                if (r_cnt == 2'd0) begin
                    if (w_is_2px) begin
                        // cnt=0, 2px → save in.
                        r_save <= w_in_lo;
                        r_cnt  <= 2'd2;
                    end else if (w_is_4px) begin
                        // cnt=0, 4px → pass through.
                        o_data <= i_data;
                        o_we   <= 1'b1;
                        r_cnt  <= 2'd0;
                    end
                end else begin   // r_cnt == 2
                    if (w_is_2px) begin
                        // cnt=2, 2px → save + new 2px = 4px out.
                        o_data <= { r_save, w_in_lo };
                        o_we   <= 1'b1;
                        r_cnt  <= 2'd0;
                    end else if (w_is_4px) begin
                        // cnt=2, 4px → emit save+in_hi, save ← in_lo.
                        o_data <= { r_save, w_in_hi };
                        o_we   <= 1'b1;
                        r_save <= w_in_lo;
                        r_cnt  <= 2'd2;
                    end
                end
            end else if (i_flush) begin
                // Row boundary : flush remaining 2 px as last word.
                if (r_cnt == 2'd2) begin
                    o_data <= { r_save, {W2{1'b0}} };
                    o_we   <= 1'b1;
                    r_cnt  <= 2'd0;
                end
            end
        end
    end

endmodule
