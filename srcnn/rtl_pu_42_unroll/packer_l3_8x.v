// packer_l3_8x.v
//
// L3 8-px/clk stream → 8-px word packer.
//
// 입력 i_lane_valid 케이스 (line_buffer_wide_l3 8-way 출력) :
//   - 8'b11111100 : 6 px valid (lane 2..7 = col 0..5 of row at K=0).
//   - 8'b11111111 : 8 px valid (lane 0..7 = col 8K-2 .. 8K+5, K>=1).
//
// 내부 상태 :
//   r_cnt  : 0, 2, 4, 6 (짝수만). save 에 들어있는 px 수.
//   r_save : 최대 7 px = 112 bit (편의상 128 bit reg 로 잡고 MSB-align).
//            MSB 가 가장 오래된 col (먼저 emit 될 px).
//
// Cycle 별 동작 (cnt 4 case × in 2 case = 8 case + flush) :
//   (0, 6): save MSB-pack 6 px,  cnt=6, no emit
//   (0, 8): emit input as-is,    cnt=0
//   (2, 6): emit {save[127:96], in[95:0]} = 2+6,         cnt=0
//   (2, 8): emit {save[127:96], in[127:32]} = 2+6,
//                 save[127:96] ← in[31:0]=2px,           cnt=2
//   (4, 6): emit {save[127:64], in[95:32]} = 4+4,
//                 save[127:96] ← in[31:0]=2px,           cnt=2
//   (4, 8): emit {save[127:64], in[127:64]} = 4+4,
//                 save[127:64] ← in[63:0]=4px,           cnt=4
//   (6, 6): emit {save[127:32], in[95:64]} = 6+2,
//                 save[127:64] ← in[63:0]=4px,           cnt=4
//   (6, 8): emit {save[127:32], in[127:96]} = 6+2,
//                 save[127:32] ← in[95:0]=6px,           cnt=6
//
//   i_flush : save 에 남은 px 를 그대로 emit. cnt 0 → no-op.
//             emit data = {save_valid_bits, zero_pad}.
//             cnt 정보를 외부로 알리려면 o_flush_cnt 동반.
//
// 픽셀 비트 배치 (MSB = leftmost col, lane 0) :
//   i_data[127:112] = lane 0 = col 8K-2     (K=0 에서 invalid)
//   i_data[111:96]  = lane 1 = col 8K-1     (K=0 에서 invalid)
//   i_data[95:80]   = lane 2 = col 8K
//   i_data[79:64]   = lane 3 = col 8K+1
//   i_data[63:48]   = lane 4 = col 8K+2
//   i_data[47:32]   = lane 5 = col 8K+3
//   i_data[31:16]   = lane 6 = col 8K+4
//   i_data[15:0]    = lane 7 = col 8K+5
//
// 출력 o_data 도 같은 순서 : o_data[127:112] = 가장 왼쪽(오래된) col.

module packer_l3_8x #(
    parameter DATA_BIT  = 16,
    parameter LANE_NUM  = 8
)(
    input  wire                          i_clk,
    input  wire                          i_rstn,
    input  wire                          i_en,           // i_data valid pulse
    input  wire [LANE_NUM*DATA_BIT-1:0]  i_data,         // 8 px (MSB=leftmost)
    input  wire [LANE_NUM-1:0]           i_lane_valid,   // 8'b11111100 or 8'b11111111
    input  wire                          i_flush,        // end-of-image flush

    output reg  [LANE_NUM*DATA_BIT-1:0]  o_data,
    output reg                           o_we,
    output reg  [3:0]                    o_flush_cnt     // valid px count on flush emit
);
    localparam W   = LANE_NUM * DATA_BIT;   // 128
    localparam W2  = 2  * DATA_BIT;          // 32
    localparam W4  = 4  * DATA_BIT;          // 64
    localparam W6  = 6  * DATA_BIT;          // 96

    reg [2:0]  r_cnt;
    reg [W-1:0] r_save;

    wire w_is_6px = (i_lane_valid == 8'b11111100);
    wire w_is_8px = (i_lane_valid == 8'b11111111);

    // input slice helpers (MSB-first).
    wire [W2-1:0] in_hi2 = i_data[W-1     -: W2];   // bits[127:96] = lane 0,1
    wire [W2-1:0] in_p2  = i_data[W-W2-1 -: W2];    // bits[95:64]  = lane 2,3
    wire [W2-1:0] in_p4  = i_data[W-W4-1 -: W2];    // bits[63:32]  = lane 4,5
    wire [W2-1:0] in_lo2 = i_data[W2-1   -: W2];    // bits[31:0]   = lane 6,7

    wire [W4-1:0] in_hi4 = i_data[W-1     -: W4];   // bits[127:64]
    wire [W4-1:0] in_lo4 = i_data[W4-1    -: W4];   // bits[63:0]

    wire [W6-1:0] in_hi6 = i_data[W-1     -: W6];   // bits[127:32]
    wire [W6-1:0] in_lo6 = i_data[W-W2-1 -: W6];    // bits[95:0]  (K=0 valid 6px)

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            r_cnt        <= 3'd0;
            r_save       <= {W{1'b0}};
            o_data       <= {W{1'b0}};
            o_we         <= 1'b0;
            o_flush_cnt  <= 4'd0;
        end else begin
            o_we        <= 1'b0;
            o_flush_cnt <= 4'd0;

            if (i_en) begin
                case (r_cnt)
                // -------- cnt = 0 --------
                3'd0: begin
                    if (w_is_6px) begin
                        r_save[W-1 -: W6] <= in_lo6;
                        r_cnt             <= 3'd6;
                    end else if (w_is_8px) begin
                        o_data <= i_data;
                        o_we   <= 1'b1;
                    end
                end
                // -------- cnt = 2 --------
                3'd2: begin
                    if (w_is_6px) begin
                        // emit {save 2px, in 6px} = 8 px.
                        o_data <= { r_save[W-1 -: W2], in_lo6 };
                        o_we   <= 1'b1;
                        r_cnt  <= 3'd0;
                    end else if (w_is_8px) begin
                        // emit {save 2px, in_hi6} = 8 px,  save ← in_lo2 (2 px).
                        o_data            <= { r_save[W-1 -: W2], in_hi6 };
                        o_we              <= 1'b1;
                        r_save[W-1 -: W2] <= in_lo2;
                        r_cnt             <= 3'd2;
                    end
                end
                // -------- cnt = 4 --------
                3'd4: begin
                    if (w_is_6px) begin
                        // emit {save 4px, in[95:32] 4px} = 8 px,  save ← in_lo2 (2 px).
                        o_data            <= { r_save[W-1 -: W4], in_p2, in_p4 };
                        o_we              <= 1'b1;
                        r_save[W-1 -: W2] <= in_lo2;
                        r_cnt             <= 3'd2;
                    end else if (w_is_8px) begin
                        // emit {save 4px, in_hi4} = 8 px,  save ← in_lo4 (4 px).
                        o_data            <= { r_save[W-1 -: W4], in_hi4 };
                        o_we              <= 1'b1;
                        r_save[W-1 -: W4] <= in_lo4;
                        r_cnt             <= 3'd4;
                    end
                end
                // -------- cnt = 6 --------
                3'd6: begin
                    if (w_is_6px) begin
                        // emit {save 6px, in[95:64] 2px} = 8 px,  save ← in_p4||in_lo2 (4 px).
                        o_data            <= { r_save[W-1 -: W6], in_p2 };
                        o_we              <= 1'b1;
                        r_save[W-1 -: W4] <= { in_p4, in_lo2 };
                        r_cnt             <= 3'd4;
                    end else if (w_is_8px) begin
                        // emit {save 6px, in_hi2} = 8 px,  save ← in[95:0] = 6 px.
                        o_data            <= { r_save[W-1 -: W6], in_hi2 };
                        o_we              <= 1'b1;
                        r_save[W-1 -: W6] <= in_lo6;
                        r_cnt             <= 3'd6;
                    end
                end
                default: ;
                endcase
            end else if (i_flush) begin
                if (r_cnt != 3'd0) begin
                    // valid px = 상위 cnt 개만. 하위 잔재는 0 으로 마스킹.
                    case (r_cnt)
                        3'd2:    o_data <= { r_save[W-1 -: W2], {(W-W2){1'b0}} };
                        3'd4:    o_data <= { r_save[W-1 -: W4], {(W-W4){1'b0}} };
                        3'd6:    o_data <= { r_save[W-1 -: W6], {(W-W6){1'b0}} };
                        default: o_data <= r_save;
                    endcase
                    o_we        <= 1'b1;
                    o_flush_cnt <= {1'b0, r_cnt};
                    r_cnt       <= 3'd0;
                end
            end
        end
    end

endmodule
