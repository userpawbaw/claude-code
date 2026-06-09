`timescale 1ns / 1ps
// high_top.v — top.v + out_buf.v 통합 래퍼.
//   top.v   : L1/L2/L3 SRCNN 가속기 (4-way 64-bit/clk L3 raw stream 출력).
//   out_buf : 유효 픽셀 추출·압축 BRAM 버퍼 + 16-bit/clk 직렬화기.
//
// 최종 출력: o_pix_valid / o_pix_data[15:0] — 1 픽셀/clk 직렬 스트림.
//            o_img_done  — 이미지 1장 직렬 출력 완료 pulse.
//            o_all_done  — 모든 이미지 처리 완료 (top.v 에서).

module high_top (
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,

    output wire        o_all_done,      // processing done (top.v)
    output wire        o_pix_valid,     // 16-bit serial pixel valid
    output wire [15:0] o_pix_data,      // 16-bit serial pixel data
    output wire        o_img_done       // 22500 pixels of 1 image output
);
    // -----------------------------------------------------------------------
    // top.v — SRCNN 가속기
    // -----------------------------------------------------------------------
    wire        w_top_img_done;
    wire        w_pix_valid;
    wire [63:0] w_pix_data;
    wire [3:0]  w_lane_valid;

    top u_top (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_start       (i_start),
        .o_img_done    (w_top_img_done),
        .o_all_done    (o_all_done),
        .o_pixel_valid (w_pix_valid),
        .o_pixel_data  (w_pix_data),
        .o_lane_valid  (w_lane_valid)
    );

    // -----------------------------------------------------------------------
    // out_buf — 64→16 직렬화 버퍼
    // -----------------------------------------------------------------------
    out_buf u_out_buf (
        .i_clk         (i_clk),
        .i_rstn        (i_rstn),
        .i_pixel_valid (w_pix_valid),
        .i_pixel_data  (w_pix_data),
        .i_lane_valid  (w_lane_valid),
        .i_img_done    (w_top_img_done),
        .o_pix_valid   (o_pix_valid),
        .o_pix_data    (o_pix_data),
        .o_img_done    (o_img_done)
    );

endmodule
