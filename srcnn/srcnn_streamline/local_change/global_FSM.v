`timescale 1ns / 1ps

// Global FSM (streamline image dispatcher)
//  - 3ê°? ?´ë¯¸ì?ë¥? L1->L2->L3 ?ŒŒ?´?”„?¼?¸?œ¼ë¡? ì²˜ë¦¬.
//  - layerë³? image_cnt ?œ ì§?, done?„ ë³´ê³  cnt++ + ?‹¤?Œ i_start ë°œì‚¬.
//  - URAM ?˜?—­ ì¶©ëŒ ë°©ì?:
//      L1.cnt - L2.cnt <= 1 (?• ? ˆ?´?–´ê°? ?’¤ ? ˆ?´?–´ë³´ë‹¤ ìµœë? 1?¥ ?•?„)
//      L2.cnt - L3.cnt <= 1
//  - image_bit = cnt[0] ?œ¼ë¡? ê³„ì‚° -> ping-pong ?˜?—­ êµì°¨
//
// system_done = (l1_cnt == N_IMG) && (l2_cnt == N_IMG) && (l3_cnt == N_IMG)

module global_FSM #(
    parameter N_IMG = 3
)(
    input  wire        i_clk,
    input  wire        i_rstn,
    input  wire        i_start,

    // done feedback (1clk pulse per image)
    input  wire        i_l1_done,
    input  wire        i_l2_done,
    input  wire        i_l3_done,

    // start dispatch (1clk pulse per image)
    output reg         o_l1_start,
    output reg         o_l2_start,
    output reg         o_l3_start,

    // image_bit ? œê³? (?•´?‹¹ ? ˆ?´?–´ê°? ?˜„?¬ ì²˜ë¦¬ì¤‘ì¸ ?´ë¯¸ì??˜ LSB)
    output wire        o_l1_image_bit,
    output wire        o_l2_image_bit,
    output wire        o_l3_image_bit,

    output wire        o_img_done,
    output wire        o_all_done
);

    // cnt: "?™„ë£Œí•œ ?´ë¯¸ì? ê°œìˆ˜" / "?‹¤?Œ?— ?‹œ?‘?•  ?´ë¯¸ì? ë²ˆí˜¸"
    reg       started;
    reg [2:0] l1_cnt, l2_cnt, l3_cnt;
    reg       l1_running, l2_running, l3_running;


    // ¾Õ ·¹ÀÌ¾î°¡ ¸ÕÀú ´ÙÀ½ ÀÌ¹ÌÁö¸¦ ¿Ï·áÇØ¼­ ÀúÀåÇØ³õÀ½ & µÚ ·¹ÀÌ¾î¿Í ÀÌ¹ÌÁö 2°³ ÀÌ»ó Â÷ÀÌ³ªÁö ¾Ê´Â °æ¿ì (ÇÎÆş URAM -> µ¤¾î¾º¿òÀ¸·Î ÀÎÇÑ ¹®Á¦ ¹æÁö) ´ÙÀ½ ÀÌ¹ÌÁö ·Îµù
    wire l1_can_start = started  && !l1_running && (l1_cnt < N_IMG[1:0]) && (l1_cnt < l2_cnt + 3'd2);
    wire l2_can_start =             !l2_running && (l2_cnt < l1_cnt)     && (l2_cnt < l3_cnt + 3'd2);
    wire l3_can_start =             !l3_running && (l3_cnt < l2_cnt);

    assign o_l1_image_bit = l1_cnt[0];
    assign o_l2_image_bit = l2_cnt[0];
    assign o_l3_image_bit = l3_cnt[0];

    assign o_img_done    = i_l3_done;
    assign o_all_done  = (l3_cnt == N_IMG[1:0]);

    
    
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            started         <= 0;
            l1_cnt          <= 0;
            l2_cnt          <= 0;
            l3_cnt          <= 0;
            l1_running      <= 0;
            l2_running      <= 0;
            l3_running      <= 0;
            o_l1_start      <= 0;
            o_l2_start      <= 0;
            o_l3_start      <= 0;
            
        end else begin
            if (i_start) begin
                started     <= 1'b1;
            end else if (o_all_done) begin
                started     <= 1'b0;
            end
            // pulse defaults
            o_l1_start  <= 0;
            o_l2_start  <= 0;
            o_l3_start  <= 0;

            // system arming

            // L1 dispatch
            if (l1_can_start) begin
                o_l1_start  <= 1'b1;
                l1_running  <= 1'b1;
            end
            if (i_l1_done) begin
                l1_running  <= 1'b0;
                l1_cnt      <= l1_cnt + 1'b1;
            end

            // L2 dispatch
            if (l2_can_start) begin
                o_l2_start  <= 1'b1;
                l2_running  <= 1'b1;
            end
            if (i_l2_done) begin
                l2_running  <= 1'b0;
                l2_cnt      <= l2_cnt + 1'b1;
            end

            // L3 dispatch
            if (l3_can_start) begin
                o_l3_start  <= 1'b1;
                l3_running  <= 1'b1;
            end
            if (i_l3_done) begin
                l3_running  <= 1'b0;
                l3_cnt      <= l3_cnt + 1'b1;
            end
        end
    end

endmodule
