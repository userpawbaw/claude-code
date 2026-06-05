`timescale 1ns / 1ps

// Global FSM (streamline image dispatcher)
//  - 3개 이미지를 L1->L2->L3 파이프라인으로 처리.
//  - layer별 image_cnt 유지, done을 보고 cnt++ + 다음 i_start 발사.
//  - URAM 영역 충돌 방지:
//      L1.cnt - L2.cnt <= 1 (앞 레이어가 뒤 레이어보다 최대 1장 앞석)
//      L2.cnt - L3.cnt <= 1
//  - image_bit = cnt[0] 으로 계산 -> ping-pong 영역 교차
//
// system_done = (l1_cnt == N_IMG) && (l2_cnt == N_IMG) && (l3_cnt == N_IMG)

module global_FSM #(
    parameter N_IMG = 3
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_system_start,

    // done feedback (1clk pulse per image)
    input  wire        i_l1_done,
    input  wire        i_l2_done,
    input  wire        i_l3_done,

    // start dispatch (1clk pulse per image)
    output reg         o_l1_start,
    output reg         o_l2_start,
    output reg         o_l3_start,

    // image_bit 제공 (해당 레이어가 현재 처리중인 이미지의 LSB)
    output wire        o_l1_image_bit,
    output wire        o_l2_image_bit,
    output wire        o_l3_image_bit,

    output wire        o_system_done
);

    // cnt: "완료한 이미지 개수" / "다음에 시작할 이미지 번호"
    reg [1:0] l1_cnt, l2_cnt, l3_cnt;
    reg       l1_running, l2_running, l3_running;
    reg       system_active;

    // 아직 자기 레이어의 cnt가 N_IMG 미달 & 앞 레이어가 먼저 다음 이미지를 완료 & 뒤 레이어도 따라온 경우에만 시작
    wire l1_can_start = system_active && !l1_running && (l1_cnt < N_IMG[1:0]) && ((l1_cnt - l2_cnt) < 2'd2);
    wire l2_can_start = system_active && !l2_running && (l2_cnt < l1_cnt)      && ((l2_cnt - l3_cnt) < 2'd2);
    wire l3_can_start = system_active && !l3_running && (l3_cnt < l2_cnt);

    assign o_l1_image_bit = l1_cnt[0];
    assign o_l2_image_bit = l2_cnt[0];
    assign o_l3_image_bit = l3_cnt[0];

    assign o_system_done  = (l1_cnt == N_IMG[1:0]) && (l2_cnt == N_IMG[1:0]) && (l3_cnt == N_IMG[1:0]);

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            l1_cnt        <= 0;
            l2_cnt        <= 0;
            l3_cnt        <= 0;
            l1_running    <= 0;
            l2_running    <= 0;
            l3_running    <= 0;
            o_l1_start    <= 0;
            o_l2_start    <= 0;
            o_l3_start    <= 0;
            system_active <= 0;
        end else begin
            // pulse defaults
            o_l1_start <= 0;
            o_l2_start <= 0;
            o_l3_start <= 0;

            // system arming
            if (i_system_start) system_active <= 1'b1;
            else if (o_system_done) system_active <= 1'b0;

            // L1 dispatch
            if (l1_can_start) begin
                o_l1_start <= 1'b1;
                l1_running <= 1'b1;
            end
            if (i_l1_done) begin
                l1_running <= 1'b0;
                l1_cnt     <= l1_cnt + 1'b1;
            end

            // L2 dispatch
            if (l2_can_start) begin
                o_l2_start <= 1'b1;
                l2_running <= 1'b1;
            end
            if (i_l2_done) begin
                l2_running <= 1'b0;
                l2_cnt     <= l2_cnt + 1'b1;
            end

            // L3 dispatch
            if (l3_can_start) begin
                o_l3_start <= 1'b1;
                l3_running <= 1'b1;
            end
            if (i_l3_done) begin
                l3_running <= 1'b0;
                l3_cnt     <= l3_cnt + 1'b1;
            end
        end
    end

endmodule
