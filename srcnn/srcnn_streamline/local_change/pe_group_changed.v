`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : pe_group.v
// PURPOSE        : 3x3 conv PE ?‡¾? ?“¬ 1åª?? PE 9åª??+ ?¨ë“¦ì»? adder tree ï§¦â‰ª?’“??
//                  ??‚…? ° ï§?ê¾¨ê¼¸ 1åª›ì’•? ï§£ì„?”??„ë¿? ?¨ë“¦ì»? 9-tap ??‘¹ê¶? ?º??ºê¾ªë?(partial sum)???•°?’•? °.
// -----------------------------------------------------------------------------
// NOTE
//   - æ¹²ê³—?? top.v ??"PE generate + adder tree pipeline" æ¿¡ì’–ì­???æ´¹ëªƒ?æ¿??ï§â‘¤ë±???
//     Layer 1 ??š­?åª›Â? æºâ‘¥?ï§Â? ??”…ë£„æ¿¡??®ê¾ªë“ƒ ?ëªƒëœ³????š¯?” ?ê¾¨ì”ª???????ì»???è¹‚ëŒ????’•?–.
//   - weight enable(i_wen)?? ?ëª??(weight_dispatch ?ë¨??’— top??weight_en)?ë¨?ê½? ?¨ë“¦?ˆ’.
//     PE ?ëª…ê½£??„?” ??i_en_w 1?ê¾©ë’ª??weight 1åª????„?Š‚)??è¹‚Â?å¯ƒì?ë¸?ï§Â? ??”…?’—??
//   - i_weight ??PE 9åª›ì’–ë¿? ?¨ë“¯?„» ?ê³Œê»(?‡‰?š®ì¤???’–?‹¦??…½?“ƒ). ????’“ ??‰â??????„?Š‚?ì¢????//     i_wen[i] one-hot ??‡°ì¤? å¯ƒê³—? ™ (æ¹²ê³—?? top.v ?? ??ˆˆ?”ª??è«›â‘¹?–‡).
//
//   Reset Strategy : Asynchronous, active low (i_rstn)
//   Synthesizable  : Y
// -FHDR------------------------------------------------------------------------

module pe_group #(
    parameter IN_CN = 8  // L2 in_ch
    )(
    input wire                 i_clk,
    input wire                 i_rstn,

    // line buffer window
    input wire                 i_line_valid,     // line_buffer o_line_valid
    input wire [16*9-1:0]      i_line_data,      // 144bit 3x3 window (16bit x 9)

    // weight ?¨ë“¦?ˆ’ (æ¹²ê³—?? top.v weight_en/w_rd_dout ?? ??ˆˆ?”ª ??ë¸?)
    input wire signed [15:0]    i_weight,         // ?¨ë“¯?„» weight è¸°ê¾©?’ª (?‡‰?š®ì¤???’–?‹¦??…½?“ƒ)
    // input wire                  i_w_group_en,           // ????–¦ PE_group??weight en 
    input wire [8:0]            i_w_tap_en,             // PE ??‰â?™è¹‚?weight en 

    input  wire                 i_line_done,
    // partial sum ?•°?’•? ° (ï§?ê¾¨ê¼¸ ?ê¾©ìŸ» ?? ?¨ë“¦ì»? 9-tap ??
    output reg                  o_valid,          // æ¹²ê³—?? adder_val_final ?????ì»?
    output reg  signed [31:0]   o_partial,         // æ¹²ê³—?? r_add_total ?????ˆˆ?”ª ?®ê¾ªë“ƒ????„?
    output wire                 o_pe_done
    
);

    // -------------------------------------------------------------------------
    // PE array (9åª?? ??æ¹²ê³—?? gen_PE ?? ??ˆˆ?”ª
    // -------------------------------------------------------------------------
    wire                pe_valid;
    wire signed [31:0] pe_output [0:8];

    genvar i;
    generate
        for (i = 0; i < 9; i = i + 1) begin : gen_PE
            PE pe (
                .i_clk    (i_clk),
                .i_rstn   (i_rstn),
                .i_en_i   (i_line_valid),
                .i_en_w   (i_w_tap_en[i]),
                .i_input  (i_line_data[16*i +: 16]),
                .i_weight (i_weight),
                .o_valid  (pe_valid),
                .o_output (pe_output[i])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Adder Tree Pipeline ??æ¹²ê³—?? top.v section 7 æ´¹ëªƒ?æ¿????Œ?–‡  
    //   stage1 : 3åª›ì’–ëµ? 3æ´¹ëªƒï¼? ??(pe_output[48*j +: ...])
    //   total  : stage1 3åª????    //   valid  : pe_valid -> adder_val1 -> o_valid (2????š¯?” ??
    // no clipping applied.
    // -------------------------------------------------------------------------
    reg                 adder_val1;
    reg signed [31:0]   r_add_stage1 [2:0];

    integer j;
    always @(posedge i_clk or negedge i_rstn) begin
        if (~i_rstn) begin
            r_add_stage1[0] <= 0;
            r_add_stage1[1] <= 0;
            r_add_stage1[2] <= 0;
 
            o_partial       <= 0;
            adder_val1      <= 0;
            o_valid         <= 0;
        end else begin
                        { adder_val1, o_valid } <= { pe_valid, adder_val1 };

            for (j = 0; j < 3; j = j + 1) begin
                r_add_stage1[j] <= $signed(pe_output[3*j]) +
                                   $signed(pe_output[3*j + 1]) +
                                   $signed(pe_output[3*j + 2]);
            end

            o_partial <=  $signed(r_add_stage1[0]) +
                           $signed(r_add_stage1[1]) +
                           $signed(r_add_stage1[2]);

        end
    end

delay_shift #(
.DELAY(3)
)d3_pe_en_to_add_valid (
    .clk(i_clk),
    .rst(~i_rstn),
    .en (1'b1),
    .din(i_line_done),
    .dout(o_pe_done)
    );

endmodule

