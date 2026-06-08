`timescale 1ns/1ps
// tb_packer_l3.v — unit TB for packer_l3_4x.
//
// 시나리오 : 4 row × 150 col = 600 px 합성 stream 주입.
//   row r, col c 의 픽셀 값 = 16'h(rrcc).  (r 0..3, c 0..149).
//   row 마다 38 emit (K=0..37).
//     K=0   : i_lane_valid = 4'b1100, i_data = {garb, garb, px(r,0), px(r,1)}.
//     K>=1  : i_lane_valid = 4'b1111, i_data = {px(r,4K-2), px(r,4K-1), px(r,4K), px(r,4K+1)}.
//
// 기대 출력 :
//   stream 의 모든 px 를 (row, col) 순으로 한 줄로 늘어놓고 4 개씩 묶어 emit.
//   600 px / 4 = 150 word.

module tb_packer_l3;
    reg         clk  = 0;
    reg         rstn = 0;
    always #5 clk = ~clk;

    reg         en;
    reg  [63:0] din;
    reg  [3:0]  lv;

    wire [63:0] dout;
    wire        we;

    packer_l3_4x dut (
        .i_clk        (clk),
        .i_rstn       (rstn),
        .i_en         (en),
        .i_data       (din),
        .i_lane_valid (lv),
        .o_data       (dout),
        .o_we         (we)
    );

    // ---------- expected stream (flat px array) ----------
    localparam N_ROW = 4;
    localparam N_COL = 150;
    localparam N_PX  = N_ROW * N_COL;
    localparam N_WORD = N_PX / 4;       // 150

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

    function [15:0] garb_px;   // marker for invalid lane positions
        input integer rr;
        input integer cc;
        begin
            garb_px = 16'hDEAD;
        end
    endfunction

    // ---------- driver ----------
    integer K;
    initial begin
        en  = 0; din = 0; lv = 0;
        @(negedge clk);
        @(negedge clk);
        rstn = 1;
        @(negedge clk);

        for (r = 0; r < N_ROW; r = r + 1) begin
            for (K = 0; K < 38; K = K + 1) begin
                @(negedge clk);
                en = 1;
                if (K == 0) begin
                    // valid : lanes 2,3 → cols 0, 1.
                    lv  = 4'b1100;
                    din = { garb_px(r, -2), garb_px(r, -1),
                            gen_px (r, 0),  gen_px (r, 1) };
                end else begin
                    lv  = 4'b1111;
                    din = { gen_px(r, 4*K-2), gen_px(r, 4*K-1),
                            gen_px(r, 4*K),   gen_px(r, 4*K+1) };
                end
            end
        end
        // gap
        @(negedge clk);
        en = 0; lv = 0; din = 0;
        repeat (10) @(negedge clk);
        $finish;
    end

    // ---------- output collector + checker ----------
    integer wcnt;
    integer err;
    reg [15:0] g0, g1, g2, g3;
    initial begin wcnt = 0; err = 0; end

    always @(posedge clk) begin
        if (we) begin
            if (wcnt >= N_WORD) begin
                $display("[%0t] EXTRA word %0d data=%016x", $time, wcnt, dout);
                err = err + 1;
            end else begin
                g0 = exp_px[wcnt*4 + 0];
                g1 = exp_px[wcnt*4 + 1];
                g2 = exp_px[wcnt*4 + 2];
                g3 = exp_px[wcnt*4 + 3];
                if (dout !== {g0, g1, g2, g3}) begin
                    $display("[%0t] MISMATCH word %0d got=%04x_%04x_%04x_%04x exp=%04x_%04x_%04x_%04x",
                        $time, wcnt,
                        dout[63:48], dout[47:32], dout[31:16], dout[15:0],
                        g0, g1, g2, g3);
                    err = err + 1;
                end else if (wcnt < 5 || (wcnt >= 36 && wcnt <= 40) || wcnt >= N_WORD-3) begin
                    $display("[%0t] word %0d OK = %04x_%04x_%04x_%04x",
                        $time, wcnt, g0, g1, g2, g3);
                end
            end
            wcnt = wcnt + 1;
        end
    end

    final begin
        $display("");
        $display("=== RESULT ===");
        $display("emitted words = %0d (expected %0d)", wcnt, N_WORD);
        $display("errors        = %0d", err);
        if (err == 0 && wcnt == N_WORD) $display("PASS");
        else                            $display("FAIL");
    end

endmodule
