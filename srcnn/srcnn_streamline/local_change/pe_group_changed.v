`timescale 1ns / 1ps
// +FHDR------------------------------------------------------------------------
// FILE NAME      : pe_group.v
// PURPOSE        : 3x3 conv PE ?��?��?�� 1�?? PE 9�??+ ?�듦�? adder tree 罹≪?��??
//                  ??��?�� �?꾨꼸 1媛쒕? 泥섎?��??���? ?�듦�? 9-tap ??���? ?��??��꾪�?(partial sum)???��?��?��.
// -----------------------------------------------------------------------------
// NOTE
//   - 湲곗?? top.v ??"PE generate + adder tree pipeline" 濡쒖�???洹몃?�??紐⑤�???
//     Layer 1 ??��?媛�? 源⑥?吏�? ??��룄濡??��꾪듃 ?몃뜳????��?��?꾨씪???????�???蹂댁????��?��.
//   - weight enable(i_wen)?? ?�??(weight_dispatch ?�??�� top??weight_en)?�?�? ?�듦?��.
//     PE ?명꽣??��?��??i_en_w 1?꾩뒪??weight 1�????��?��)??蹂�?寃�?�?吏�? ??��?��??
//   - i_weight ??PE 9媛쒖�? ?�듯?�� ?곌껐(?��?���???��?��??��?��). ????�� ??��??????��?��?�????//     i_wen[i] one-hot ??���? 寃곗?�� (湲곗?? top.v ?? ??��?��??諛⑹?��).
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

    // weight ?�듦?�� (湲곗?? top.v weight_en/w_rd_dout ?? ??��?�� ??�?)
    input wire signed [15:0]    i_weight,         // ?�듯?�� weight 踰꾩?�� (?��?���???��?��??��?��)
    // input wire                  i_w_group_en,           // ????�� PE_group??weight en 
    input wire [8:0]            i_w_tap_en,             // PE ??��?�蹂?weight en 

    input  wire                 i_line_done,
    // partial sum ?��?��?�� (�?꾨꼸 ?꾩쟻 ?? ?�듦�? 9-tap ??
    output reg                  o_valid,          // 湲곗?? adder_val_final ?????�?
    output reg  signed [31:0]   o_partial,         // 湲곗?? r_add_total ?????��?�� ?��꾪듃????��?
    output wire                 o_pe_done
    
);

    // -------------------------------------------------------------------------
    // PE array (9�?? ??湲곗?? gen_PE ?? ??��?��
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
    // Adder Tree Pipeline ??湲곗?? top.v section 7 洹몃?�????��?��  
    //   stage1 : 3媛쒖�? 3洹몃�? ??(pe_output[48*j +: ...])
    //   total  : stage1 3�????    //   valid  : pe_valid -> adder_val1 -> o_valid (2????��?��??
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

