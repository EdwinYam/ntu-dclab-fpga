// ============================================================================
// AudioCore
// ----------------------------------------------------------------------------
// Recorder/player control, clocked by AUD_BCLK from the codec (master mode).
//
// Key-driven state machine (keys arrive as one-cycle pulses):
//
//   S_INIT ── codec configured ──> S_IDLE
//   S_IDLE ── rec ──> S_REC  <── rec ──> S_REC_PAUSE
//   S_IDLE ── play (if anything was recorded) ──> S_PLAY <── play ──> S_PLAY_PAUSE
//   stop, memory full, or end of recording ──> S_IDLE
//
// Recording writes 16-bit left-channel samples to the IS61WV102416 SRAM
// (one word per address, up to MAX_SAMPLES words). Each write takes three
// cycles so the address and data are stable before WE# falls and after it
// rises. Playback reads through AudDsp.
//
// The elapsed time of the current recording or playback, in seconds, is
// counted in audio frames (SAMPLE_RATE frames per second).
// ============================================================================
module AudioCore #(
    parameter int SAMPLE_RATE = 32000,
    parameter int MAX_SAMPLES = 1 << 20      // SRAM depth in 16-bit words
)(
    input  logic        i_rst_n,
    input  logic        i_clk,           // AUD_BCLK
    input  logic        i_init_done,     // codec configured (synchronized to i_clk)

    input  logic        i_key_rec,       // record / pause recording
    input  logic        i_key_play,      // play / pause playback
    input  logic        i_key_stop,      // stop

    input  logic [2:0]  i_speed,         // s = i_speed + 1
    input  logic        i_slow,          // 0: s times faster, 1: s times slower
    input  logic        i_interp,        // slow mode: linear interpolation

    // Codec serial interface
    input  logic        i_adclrck,
    input  logic        i_adcdat,
    input  logic        i_daclrck,
    output logic        o_dacdat,

    // SRAM (active-low controls; CE#, LB#, UB# are tied low at the top level)
    output logic [19:0] o_sram_addr,
    output logic [15:0] o_sram_wdata,
    input  logic [15:0] i_sram_rdata,
    output logic        o_sram_dq_oe,    // drive SRAM_DQ with o_sram_wdata
    output logic        o_sram_we_n,
    output logic        o_sram_oe_n,

    // Status
    output logic [2:0]  o_state,
    output logic [6:0]  o_seconds,       // 0..99
    output logic [20:0] o_rec_len        // number of recorded samples
);

    typedef enum logic [2:0] {
        S_INIT, S_IDLE, S_REC, S_REC_PAUSE, S_PLAY, S_PLAY_PAUSE
    } state_t;
    state_t state;
    assign o_state = state;

    // ------------------------------------------------------------------------
    // Audio frame tick: DACLRCK falling edge (start of the left channel)
    // ------------------------------------------------------------------------
    logic daclrc_d;
    logic frame;
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) daclrc_d <= 1'b1;
        else          daclrc_d <= i_daclrck;
    end
    assign frame = daclrc_d & ~i_daclrck;

    // ------------------------------------------------------------------------
    // Recorder (ADC deserializer)
    // ------------------------------------------------------------------------
    logic [15:0] rec_sample;
    logic        rec_valid;

    AudRecorder u_recorder (
        .i_rst_n  (i_rst_n),
        .i_bclk   (i_clk),
        .i_lrc    (i_adclrck),
        .i_data   (i_adcdat),
        .o_sample (rec_sample),
        .o_valid  (rec_valid)
    );

    // ------------------------------------------------------------------------
    // Playback engine
    // ------------------------------------------------------------------------
    logic        dsp_start, dsp_stop, dsp_busy, dsp_done;
    logic [19:0] dsp_addr;
    logic [15:0] dsp_sample;

    AudDsp #(.ADDR_W(20)) u_dsp (
        .i_clk       (i_clk),
        .i_rst_n     (i_rst_n),
        .i_start     (dsp_start),
        .i_stop      (dsp_stop),
        .i_pause     (state == S_PLAY_PAUSE),
        .i_frame     (frame),
        .i_speed     (i_speed),
        .i_slow      (i_slow),
        .i_interp    (i_interp),
        .i_end_addr  (o_rec_len[19:0] - 20'd1),
        .o_sram_addr (dsp_addr),
        .i_sram_data (i_sram_rdata),
        .o_sample    (dsp_sample),
        .o_busy      (dsp_busy),
        .o_done      (dsp_done)
    );

    // ------------------------------------------------------------------------
    // DAC serializer
    // ------------------------------------------------------------------------
    AudPlayer u_player (
        .i_rst_n  (i_rst_n),
        .i_bclk   (i_clk),
        .i_lrc    (i_daclrck),
        .i_en     (state == S_PLAY),
        .i_sample (dsp_sample),
        .o_dacdat (o_dacdat)
    );

    // ------------------------------------------------------------------------
    // SRAM writer
    // ------------------------------------------------------------------------
    typedef enum logic [1:0] {W_IDLE, W_SETUP, W_PULSE, W_HOLD} wstate_t;
    wstate_t     wstate;
    logic [20:0] waddr;            // next address to write
    logic        wbusy;
    logic        mem_full;

    assign wbusy    = (wstate != W_IDLE);
    assign mem_full = (waddr == 21'(MAX_SAMPLES));

    assign o_sram_addr  = wbusy ? waddr[19:0] : dsp_addr;
    assign o_sram_dq_oe = wbusy;
    assign o_sram_oe_n  = wbusy;    // output enable only while reading

    // ------------------------------------------------------------------------
    // Main state machine
    // ------------------------------------------------------------------------
    logic                          init_done_d;
    logic [$clog2(SAMPLE_RATE):0]  frame_cnt;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state        <= S_INIT;
            wstate       <= W_IDLE;
            waddr        <= '0;
            o_rec_len    <= '0;
            o_sram_wdata <= '0;
            o_sram_we_n  <= 1'b1;
            dsp_start    <= 1'b0;
            dsp_stop     <= 1'b0;
            frame_cnt    <= '0;
            o_seconds    <= '0;
            init_done_d  <= 1'b0;
        end else begin
            dsp_start   <= 1'b0;
            dsp_stop    <= 1'b0;
            init_done_d <= i_init_done;

            // ---------------- control ----------------
            case (state)
                S_INIT: if (init_done_d) state <= S_IDLE;

                S_IDLE: begin
                    if (i_key_rec) begin
                        state     <= S_REC;
                        waddr     <= '0;
                        o_rec_len <= '0;
                        frame_cnt <= '0;
                        o_seconds <= '0;
                    end else if (i_key_play && o_rec_len != 21'd0) begin
                        state     <= S_PLAY;
                        dsp_start <= 1'b1;
                        frame_cnt <= '0;
                        o_seconds <= '0;
                    end
                end

                S_REC: begin
                    if (i_key_stop || (mem_full && !wbusy)) state <= S_IDLE;
                    else if (i_key_rec)                     state <= S_REC_PAUSE;
                end

                S_REC_PAUSE: begin
                    if (i_key_stop)     state <= S_IDLE;
                    else if (i_key_rec) state <= S_REC;
                end

                S_PLAY: begin
                    if (i_key_stop) begin
                        state    <= S_IDLE;
                        dsp_stop <= 1'b1;
                    end else if (dsp_done) begin
                        state    <= S_IDLE;
                    end else if (i_key_play) begin
                        state    <= S_PLAY_PAUSE;
                    end
                end

                S_PLAY_PAUSE: begin
                    if (i_key_stop) begin
                        state    <= S_IDLE;
                        dsp_stop <= 1'b1;
                    end else if (i_key_play) begin
                        state    <= S_PLAY;
                    end
                end

                default: state <= S_IDLE;
            endcase

            // ---------------- SRAM write sequence ----------------
            case (wstate)
                W_IDLE: if (rec_valid && state == S_REC && !mem_full) begin
                    o_sram_wdata <= rec_sample;
                    wstate       <= W_SETUP;       // address/data settle, WE# high
                end
                W_SETUP: begin
                    o_sram_we_n <= 1'b0;
                    wstate      <= W_PULSE;
                end
                W_PULSE: begin
                    o_sram_we_n <= 1'b1;           // write occurs on WE# rising edge
                    wstate      <= W_HOLD;
                end
                W_HOLD: begin
                    waddr     <= waddr + 1'b1;
                    o_rec_len <= waddr + 1'b1;
                    wstate    <= W_IDLE;
                end
            endcase

            // ---------------- elapsed time ----------------
            if (frame && (state == S_REC || state == S_PLAY)) begin
                if (frame_cnt == ($clog2(SAMPLE_RATE)+1)'(SAMPLE_RATE - 1)) begin
                    frame_cnt <= '0;
                    if (o_seconds != 7'd99) o_seconds <= o_seconds + 1'b1;
                end else begin
                    frame_cnt <= frame_cnt + 1'b1;
                end
            end
        end
    end

endmodule
