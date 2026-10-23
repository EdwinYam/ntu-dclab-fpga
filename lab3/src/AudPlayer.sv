// ============================================================================
// AudPlayer
// ----------------------------------------------------------------------------
// Serializes a 16-bit sample onto AUD_DACDAT in I2S format (codec in master
// mode). The same sample is sent on both channels (mono playback).
//
// The codec samples DACDAT on BCLK rising edges, so this module updates the
// line on BCLK falling edges. DACLRCK changes on a falling edge; this module
// sees the new level on the next falling edge and drives the MSB there, which
// places it on the second rising edge after the LRCK edge as I2S requires.
//
// The sample is latched at the start of the left channel. When i_en is low,
// silence (all zeros) is sent.
// ============================================================================
module AudPlayer (
    input  logic        i_rst_n,
    input  logic        i_bclk,
    input  logic        i_lrc,       // AUD_DACLRCK
    input  logic        i_en,
    input  logic [15:0] i_sample,
    output logic        o_dacdat
);

    logic        lrc_d;
    logic [15:0] hold;       // sample for the current frame (both channels)
    logic [14:0] shreg;      // remaining bits of the word being sent
    logic [3:0]  remain;     // number of bits still to send

    always_ff @(negedge i_bclk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            lrc_d    <= 1'b1;
            hold     <= '0;
            shreg    <= '0;
            remain   <= 4'd0;
            o_dacdat <= 1'b0;
        end else begin
            lrc_d <= i_lrc;
            if (lrc_d && !i_lrc) begin
                // Start of left channel: latch a new sample and send its MSB
                hold     <= i_en ? i_sample : 16'd0;
                o_dacdat <= i_en ? i_sample[15] : 1'b0;
                shreg    <= i_en ? i_sample[14:0] : 15'd0;
                remain   <= 4'd15;
            end else if (!lrc_d && i_lrc) begin
                // Start of right channel: resend the same sample
                o_dacdat <= hold[15];
                shreg    <= hold[14:0];
                remain   <= 4'd15;
            end else if (remain != 4'd0) begin
                o_dacdat <= shreg[14];
                shreg    <= {shreg[13:0], 1'b0};
                remain   <= remain - 1'b1;
            end else begin
                o_dacdat <= 1'b0;
            end
        end
    end

endmodule
