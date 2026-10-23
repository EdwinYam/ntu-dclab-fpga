// ============================================================================
// I2cInitializer
// ----------------------------------------------------------------------------
// Configures the WM8731 audio codec on the DE2-115 over its 2-wire (I2C)
// control port. Each register write is one 3-byte transaction:
//
//   START | 0x34 (7'h1A + W) | ACK | {reg[6:0], data[8]} | ACK | data[7:0] | ACK | STOP
//
// Each I2C bit is split into four phases of CLK_DIV system clocks:
//   phase 0: SCL low,  put the next bit on SDA
//   phase 1: SCL high
//   phase 2: SCL high, sample SDA (ACK slots only)
//   phase 3: SCL low
// With a 50 MHz clock and CLK_DIV = 125, SCL runs at 100 kHz.
//
// SDA is open-drain: o_sda_oe = 1 pulls the line low, 0 releases it (the
// board pull-up makes it high). If the codec does not acknowledge any byte,
// the whole register write is retried and o_nack is set (sticky).
// ============================================================================
module I2cInitializer #(
    parameter int CLK_DIV   = 125,  // system clocks per quarter SCL period
    parameter bit USE_MIC   = 1'b1  // 1: microphone input, 0: line input
)(
    input  logic i_clk,
    input  logic i_rst_n,
    input  logic i_start,     // begin the configuration sequence (level or pulse)
    output logic o_scl,
    output logic o_sda_oe,    // 1 = drive SDA low, 0 = release SDA
    input  logic i_sda,
    output logic o_done,      // all registers written and acknowledged
    output logic o_nack       // sticky: at least one write had to be retried
);

    // ------------------------------------------------------------------------
    // WM8731 register table: {reg_addr[6:0], data[8:0]}
    // ------------------------------------------------------------------------
    localparam int N_WORDS = 11;

    function automatic logic [15:0] cfg_word(input logic [3:0] idx);
        case (idx)
            4'd0:  cfg_word = 16'h1E00;                         // R15 reset
            4'd1:  cfg_word = USE_MIC ? 16'h0097 : 16'h0017;    // R0  left line in: mute when using mic, else 0 dB
            4'd2:  cfg_word = USE_MIC ? 16'h0297 : 16'h0217;    // R1  right line in: same as left
            4'd3:  cfg_word = 16'h0479;                         // R2  left headphone out: 0 dB
            4'd4:  cfg_word = 16'h0679;                         // R3  right headphone out: 0 dB
            4'd5:  cfg_word = USE_MIC ? 16'h0815 : 16'h0812;    // R4  analog path: DAC select; mic + 20 dB boost, or line in with mic muted
            4'd6:  cfg_word = 16'h0A00;                         // R5  digital path: DAC unmuted, no de-emphasis, ADC HPF on
            4'd7:  cfg_word = 16'h0C00;                         // R6  power down control: everything powered on
            4'd8:  cfg_word = 16'h0E42;                         // R7  digital interface: master mode, I2S format, 16-bit words
            4'd9:  cfg_word = 16'h1019;                         // R8  sampling control: USB mode (12 MHz MCLK), 32 kHz ADC/DAC
            4'd10: cfg_word = 16'h1201;                         // R9  active control: activate interface
            default: cfg_word = 16'h0000;
        endcase
    endfunction

    localparam logic [7:0] DEV_ADDR_W = 8'h34;  // 7'h1A (CSB low) + write bit

    // ------------------------------------------------------------------------
    // Quarter-period tick generator
    // ------------------------------------------------------------------------
    localparam int DIV_W = (CLK_DIV > 1) ? $clog2(CLK_DIV) : 1;
    logic [DIV_W-1:0] div_cnt;
    logic             tick;

    assign tick = (div_cnt == DIV_W'(CLK_DIV - 1));

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)  div_cnt <= '0;
        else if (tick) div_cnt <= '0;
        else           div_cnt <= div_cnt + 1'b1;
    end

    // ------------------------------------------------------------------------
    // Transaction state machine
    // ------------------------------------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_START, S_BITS, S_STOP, S_GAP, S_DONE} state_t;
    state_t state;

    logic [1:0]  phase;
    logic [4:0]  bit_idx;     // 0..26: 3 bytes x (8 data bits + 1 ACK slot)
    logic [3:0]  word_idx;
    logic [26:0] frame;       // bits to send, MSB first; ACK slots are 1 (released)
    logic        ack_err;     // NACK seen during the current transaction

    logic [15:0] cur_word;
    assign cur_word = cfg_word(word_idx);

    // ACK slots are the 9th bit of each byte
    logic ack_slot;
    assign ack_slot = (bit_idx == 5'd8) || (bit_idx == 5'd17) || (bit_idx == 5'd26);

    assign o_done = (state == S_DONE);

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state    <= S_IDLE;
            phase    <= 2'd0;
            bit_idx  <= 5'd0;
            word_idx <= 4'd0;
            frame    <= '1;
            ack_err  <= 1'b0;
            o_scl    <= 1'b1;
            o_sda_oe <= 1'b0;
            o_nack   <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    o_scl    <= 1'b1;
                    o_sda_oe <= 1'b0;
                    if (i_start) begin
                        state <= S_START;
                        phase <= 2'd0;
                    end
                end

                // START: SDA falls while SCL is high
                S_START: if (tick) begin
                    phase <= phase + 1'b1;
                    case (phase)
                        2'd0: begin
                            o_scl    <= 1'b1;
                            o_sda_oe <= 1'b0;
                            frame    <= {DEV_ADDR_W, 1'b1, cur_word[15:8], 1'b1, cur_word[7:0], 1'b1};
                            ack_err  <= 1'b0;
                        end
                        2'd1: o_sda_oe <= 1'b1;
                        2'd2: ;
                        2'd3: begin
                            o_scl   <= 1'b0;
                            state   <= S_BITS;
                            bit_idx <= 5'd0;
                        end
                    endcase
                end

                // Data and ACK bits
                S_BITS: if (tick) begin
                    phase <= phase + 1'b1;
                    case (phase)
                        2'd0: begin
                            o_scl    <= 1'b0;
                            o_sda_oe <= ~frame[26];          // ACK slots release SDA
                        end
                        2'd1: o_scl <= 1'b1;
                        2'd2: if (ack_slot && i_sda) ack_err <= 1'b1;  // high = NACK
                        2'd3: begin
                            o_scl <= 1'b0;
                            frame <= {frame[25:0], 1'b1};
                            if (bit_idx == 5'd26) state <= S_STOP;
                            else                  bit_idx <= bit_idx + 1'b1;
                        end
                    endcase
                end

                // STOP: SDA rises while SCL is high
                S_STOP: if (tick) begin
                    phase <= phase + 1'b1;
                    case (phase)
                        2'd0: begin
                            o_scl    <= 1'b0;
                            o_sda_oe <= 1'b1;
                        end
                        2'd1: o_scl    <= 1'b1;
                        2'd2: o_sda_oe <= 1'b0;
                        2'd3: begin
                            if (ack_err) begin
                                o_nack <= 1'b1;               // retry the same word
                                state  <= S_GAP;
                            end else if (word_idx == 4'(N_WORDS - 1)) begin
                                state  <= S_DONE;
                            end else begin
                                word_idx <= word_idx + 1'b1;
                                state    <= S_GAP;
                            end
                        end
                    endcase
                end

                // Bus-free time between transactions (one SCL period)
                S_GAP: if (tick) begin
                    phase <= phase + 1'b1;
                    if (phase == 2'd3) state <= S_START;
                end

                S_DONE: begin
                    o_scl    <= 1'b1;
                    o_sda_oe <= 1'b0;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
