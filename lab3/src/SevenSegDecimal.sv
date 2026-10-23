// ============================================================================
// SevenSegDecimal
// ----------------------------------------------------------------------------
// Shows a value 0..99 as two decimal digits on active-low seven-segment
// displays (DE2-115 HEX outputs). Values above 99 show "--".
//
// Segment layout (bit index, 0 = lit):
//      0
//    5   1
//      6
//    4   2
//      3
// ============================================================================
module SevenSegDecimal (
    input  logic [6:0] i_value,
    output logic [6:0] o_tens,
    output logic [6:0] o_ones
);

    function automatic logic [6:0] digit(input logic [3:0] d);
        case (d)
            4'd0: digit = 7'b1000000;
            4'd1: digit = 7'b1111001;
            4'd2: digit = 7'b0100100;
            4'd3: digit = 7'b0110000;
            4'd4: digit = 7'b0011001;
            4'd5: digit = 7'b0010010;
            4'd6: digit = 7'b0000010;
            4'd7: digit = 7'b1111000;
            4'd8: digit = 7'b0000000;
            4'd9: digit = 7'b0010000;
            default: digit = 7'b0111111;   // dash
        endcase
    endfunction

    logic [3:0] tens, ones;

    always_comb begin
        if (i_value > 7'd99) begin
            tens = 4'hF;
            ones = 4'hF;
        end else begin
            tens = 4'(i_value / 7'd10);
            ones = 4'(i_value % 7'd10);
        end
        o_tens = digit(tens);
        o_ones = digit(ones);
    end

endmodule
