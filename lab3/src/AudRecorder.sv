// ============================================================================
// AudRecorder
// ----------------------------------------------------------------------------
// Deserializes the left channel of the WM8731 ADC stream (I2S format, codec in
// master mode, 16-bit words).
//
// I2S timing: ADCLRCK falls on a BCLK falling edge to start the left channel.
// The MSB appears one BCLK after the LRCK edge, so the first rising edge after
// the edge still carries the previous word's LSB and is skipped. The next 16
// rising edges carry bits 15..0.
//
// o_valid pulses for one BCLK cycle when a full sample is in o_sample.
// ============================================================================
module AudRecorder (
    input  logic        i_rst_n,
    input  logic        i_bclk,
    input  logic        i_lrc,       // AUD_ADCLRCK
    input  logic        i_data,      // AUD_ADCDAT
    output logic [15:0] o_sample,
    output logic        o_valid
);

    logic        lrc_d;
    logic        capturing;
    logic [3:0]  bit_cnt;
    logic [14:0] shreg;

    always_ff @(posedge i_bclk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            lrc_d     <= 1'b1;
            capturing <= 1'b0;
            bit_cnt   <= 4'd0;
            shreg     <= '0;
            o_sample  <= '0;
            o_valid   <= 1'b0;
        end else begin
            lrc_d   <= i_lrc;
            o_valid <= 1'b0;
            if (lrc_d && !i_lrc) begin
                // First rising edge of the left channel: skip the 1-bit delay slot
                capturing <= 1'b1;
                bit_cnt   <= 4'd0;
            end else if (capturing) begin
                shreg   <= {shreg[13:0], i_data};
                bit_cnt <= bit_cnt + 1'b1;
                if (bit_cnt == 4'd15) begin
                    capturing <= 1'b0;
                    o_sample  <= {shreg, i_data};
                    o_valid   <= 1'b1;
                end
            end
        end
    end

endmodule
