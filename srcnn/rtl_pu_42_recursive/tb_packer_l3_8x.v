`timescale 1ns/1ps
// tb_packer_l3_8x.v — unit TB for packer_l3_8x.
//
// 시나리오 : 150 row × 150 col = 22500 px 합성 stream 주입 (단일 이미지),
//            stream 종료 후 i_flush 1펄스.
//   row r, col c 의 픽셀 값 = 16'h(rrcc).  (r 0..149, c 0..149).
//   row 마다 19 emit (K=0..18).
//     K=0   : i_lane_valid = 8'b1111_1100, valid lane 2..7 = col 0..5.
//             i_data = {garb0, garb1, px(r,0..5)}  (lane0,1 = MSB = garbage).
//     K>=1  : i_lane_valid = 8'b1111_1111, lane 0..7 = col 8K-2 .. 8K+5.
//
// 기대 출력 :
//   모든 px 를 (row, col) 순으로 한 줄로 늘어놓고 8 개씩 묶어 emit.
//   22500 px → 2812 full word + flush 1 word (마지막 4 px, MSB-align).
//   총 2813 word.

module tb_packer_l3_8x;
    reg          clk  = 0;
    reg          rstn = 0;
    always #5 clk = ~clk;

    reg          en;
    reg          flush;
    reg  [127:0] din;
    reg  [7:0]   lv;

    wire [127:0] dout;
    wire         we;
    wire [3:0]   flush_cnt;

    packer_l3_8x dut (
        .i_clk        (clk),
        .i_rstn       (rstn),
        .i_en         (en),
        .i_flush      (flush),
        .i_data       (din),
        .i_lane_valid (lv),
        .o_data       (dout),
        .o_we         (we),
        .o_flush_cnt  (flush_cnt)
    );

    // ---------- expected stream (flat px array) ----------
    localparam N_ROW  = 150;
    localparam N_COL  = 150;
    localparam N_PX   = N_ROW * N_COL;       // 22500
    localparam N_FULL = N_PX / 8;            // 2812  (마지막 4px 잔여)
    localparam N_REM  = N_PX % 8;            // 4
    localparam N_WORD = N_FULL + (N_REM != 0 ? 1 : 0);  // 2813

    reg [15:0] exp_px [0:N_PX-1];

    integer r, c;
    initial begin
        for (r = 0; r < N_ROW; r = r + 1)
            for (c = 0; c < N_COL; c = c + 1)
                exp_px[r*N_COL + c] = { r[7:0], c[7:0] };
    end

    function [15:0] gen_px;
        input integer rr;
        input integer cc;
        begin
            gen_px = { rr[7:0], cc[7:0] };
        end
    endfunction

    // ---------- driver ----------
    integer K;
    initial begin
        en = 0; flush = 0; din = 0; lv = 0;
        @(negedge clk);
        @(negedge clk);
        rstn = 1;
        @(negedge clk);

        for (r = 0; r < N_ROW; r = r + 1) begin
            for (K = 0; K < 19; K = K + 1) begin
                @(negedge clk);
                en = 1;
                if (K == 0) begin
                    // valid lane 2..7 → col 0..5.  lane0,1 (MSB) = garbage.
                    lv  = 8'b1111_1100;
                    din = { 16'hDEAD, 16'hBEEF,
                            gen_px(r,0), gen_px(r,1), gen_px(r,2),
                            gen_px(r,3), gen_px(r,4), gen_px(r,5) };
                end else begin
                    // lane 0..7 → col 8K-2 .. 8K+5.
                    lv  = 8'b1111_1111;
                    din = { gen_px(r, 8*K-2), gen_px(r, 8*K-1),
                            gen_px(r, 8*K),   gen_px(r, 8*K+1),
                            gen_px(r, 8*K+2), gen_px(r, 8*K+3),
                            gen_px(r, 8*K+4), gen_px(r, 8*K+5) };
                end
            end
        end
        // stream 종료 → en 내리고 flush 1펄스.
        @(negedge clk);
        en = 0; lv = 0; din = 0;
        @(negedge clk);
        flush = 1;
        @(negedge clk);
        flush = 0;

        repeat (10) @(negedge clk);
        $finish;
    end

    // ---------- output collector + checker ----------
    integer wcnt;
    integer err;
    integer i;
    reg [127:0] exp_word;
    initial begin wcnt = 0; err = 0; end

    always @(posedge clk) begin
        if (we) begin
            if (wcnt >= N_WORD) begin
                $display("[%0t] EXTRA word %0d data=%032x", $time, wcnt, dout);
                err = err + 1;
            end else begin
                // build expected word (8 px MSB-first, 잔여는 0 pad).
                exp_word = 128'h0;
                for (i = 0; i < 8; i = i + 1) begin
                    if (wcnt*8 + i < N_PX)
                        exp_word[(7-i)*16 +: 16] = exp_px[wcnt*8 + i];
                    else
                        exp_word[(7-i)*16 +: 16] = 16'h0;
                end
                if (dout !== exp_word) begin
                    if (err < 12)
                        $display("[%0t] MISMATCH word %0d\n   got=%032x\n   exp=%032x",
                            $time, wcnt, dout, exp_word);
                    err = err + 1;
                end else if (wcnt < 4 || wcnt >= N_WORD-2) begin
                    $display("[%0t] word %0d OK = %032x", $time, wcnt, dout);
                end
                // flush word check.
                if (wcnt == N_FULL) begin
                    if (flush_cnt != N_REM)
                        $display("[%0t] FLUSH CNT ERR got=%0d exp=%0d", $time, flush_cnt, N_REM);
                    else
                        $display("[%0t] flush word %0d flush_cnt=%0d OK", $time, wcnt, flush_cnt);
                end
            end
            wcnt = wcnt + 1;
        end
    end

    final begin
        $display("");
        $display("=== RESULT ===");
        $display("emitted words = %0d (expected %0d : %0d full + 1 flush)",
                 wcnt, N_WORD, N_FULL);
        $display("errors        = %0d", err);
        if (err == 0 && wcnt == N_WORD) $display("PASS");
        else                            $display("FAIL");
    end

endmodule
