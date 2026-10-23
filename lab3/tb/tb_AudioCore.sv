// ============================================================================
// tb_AudioCore
// ----------------------------------------------------------------------------
// Self-checking testbench for the record / playback path:
// AudioCore = control FSM + AudRecorder + AudDsp + AudPlayer + SRAM writer.
//
// Models
//   * WM8731 in master mode: generates BCLK and LRCK (32 BCLK per channel) and
//     sends a known 16-bit sample stream on ADCDAT in I2S format; captures the
//     left-channel words on DACDAT.
//   * IS61WV102416 SRAM: asynchronous read, write on the rising edge of WE#.
//
// Test sequence
//   1. record, pause, resume, stop: SRAM holds two contiguous runs of the
//      input stream (one gap where recording was paused)
//   2. playback 1x, 3x and 8x fast; 2x slow (repeat); 3x and 8x slow
//      (linear interpolation): DAC output equals a golden model computed from
//      the SRAM contents
//   3. pause and resume during playback: no samples lost or repeated
//   4. stop during playback returns to idle
//   5. recording stops by itself when the memory is full (MAX_SAMPLES)
//   6. elapsed-seconds counter
// ============================================================================
`timescale 1ns/1ps

module tb_AudioCore;

    localparam int SAMPLE_RATE = 8;      // small so the seconds counter moves
    localparam int MAX_SAMPLES = 64;     // small so "memory full" is reachable
    localparam int HALF_BCLK   = 10;     // 50 MHz BCLK in simulation
    localparam int BITS_PER_CH = 32;

    localparam logic [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_REC = 3'd2,
                           S_REC_PAUSE = 3'd3, S_PLAY = 3'd4, S_PLAY_PAUSE = 3'd5;

    // ------------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------------
    logic        bclk = 1'b0;
    logic        rst_n;
    logic        init_done;
    logic        key_rec, key_play, key_stop;
    logic [2:0]  speed;
    logic        slow, interp;
    logic        lrck, adcdat;
    wire         dacdat;
    wire  [19:0] sram_addr;
    wire  [15:0] sram_wdata;
    wire  [15:0] sram_dq;
    wire         sram_dq_oe, sram_we_n, sram_oe_n;
    wire  [2:0]  state;
    wire  [6:0]  seconds;
    wire  [20:0] rec_len;

    AudioCore #(
        .SAMPLE_RATE (SAMPLE_RATE),
        .MAX_SAMPLES (MAX_SAMPLES)
    ) dut (
        .i_rst_n      (rst_n),
        .i_clk        (bclk),
        .i_init_done  (init_done),
        .i_key_rec    (key_rec),
        .i_key_play   (key_play),
        .i_key_stop   (key_stop),
        .i_speed      (speed),
        .i_slow       (slow),
        .i_interp     (interp),
        .i_adclrck    (lrck),
        .i_adcdat     (adcdat),
        .i_daclrck    (lrck),
        .o_dacdat     (dacdat),
        .o_sram_addr  (sram_addr),
        .o_sram_wdata (sram_wdata),
        .i_sram_rdata (sram_dq),
        .o_sram_dq_oe (sram_dq_oe),
        .o_sram_we_n  (sram_we_n),
        .o_sram_oe_n  (sram_oe_n),
        .o_state      (state),
        .o_seconds    (seconds),
        .o_rec_len    (rec_len)
    );

    always #(HALF_BCLK) bclk = ~bclk;

    // ------------------------------------------------------------------------
    // SRAM model
    // ------------------------------------------------------------------------
    logic [15:0] mem [0:(1<<20)-1];

    assign sram_dq = sram_dq_oe ? sram_wdata : 16'bz;
    assign sram_dq = (!sram_oe_n && sram_we_n) ? mem[sram_addr] : 16'bz;

    always @(posedge sram_we_n) begin
        if (rst_n === 1'b1) mem[sram_addr] = sram_dq;
    end

    // ------------------------------------------------------------------------
    // Codec model: I2S master
    // Frame = 2 * BITS_PER_CH BCLKs. LRCK low = left channel. Outputs change
    // shortly after the BCLK falling edge; data is one BCLK behind LRCK.
    // ------------------------------------------------------------------------
    function automatic logic [15:0] stream(input int idx);
        stream = 16'(1000 + (idx * 7919) % 5000);    // unique for idx < 5000, never 0
    endfunction

    int pos;          // bit position inside the frame, 0 .. 2*BITS_PER_CH-1
    int frame_idx;    // index of the current left-channel sample

    initial begin
        pos       = 2 * BITS_PER_CH - 1;
        frame_idx = -1;
        lrck      = 1'b1;
        adcdat    = 1'b0;
    end

    logic [15:0] adc_word;

    always @(negedge bclk) begin
        #1;
        pos = (pos + 1) % (2 * BITS_PER_CH);
        if (pos == 0) frame_idx = frame_idx + 1;
        lrck     = (pos >= BITS_PER_CH);
        adc_word = stream(frame_idx);
        if (pos >= 1 && pos <= 16)
            adcdat = adc_word[16 - pos];
        else if (pos >= BITS_PER_CH + 1 && pos <= BITS_PER_CH + 16)
            adcdat = ~adc_word[BITS_PER_CH + 16 - pos];   // right channel
        else
            adcdat = 1'b0;
    end

    // DAC capture: left-channel bits on rising edges at positions 1..16
    logic [15:0] dac_sh;
    logic [15:0] dac_words [$];
    bit          capture_on;

    always @(posedge bclk) begin
        if (pos >= 1 && pos <= 16) begin
            dac_sh = {dac_sh[14:0], dacdat};
            if (pos == 16 && capture_on) dac_words.push_back(dac_sh);
        end
    end

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    int errors = 0;

    task automatic press(ref logic key);
        @(posedge bclk); #2 key = 1'b1;
        @(posedge bclk); #2 key = 1'b0;
    endtask

    task automatic wait_frames(input int n);
        repeat (n * 2 * BITS_PER_CH) @(posedge bclk);
    endtask

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("FAIL: %s", msg);
            errors++;
        end
    endtask

    // Golden playback sequence from the recorded SRAM contents
    function automatic void golden(input int len, input int s, input bit is_slow,
                                   input bit is_interp, ref int q[$]);
        int p, k, cur, nxt;
        q.delete();
        if (!is_slow) begin
            for (p = 0; p < len; p += s) q.push_back($signed(mem[p]));
        end else begin
            for (p = 0; p < len; p++) begin
                cur = $signed(mem[p]);
                nxt = (p + 1 < len) ? $signed(mem[p + 1]) : cur;
                for (k = 0; k < s; k++)
                    q.push_back(is_interp ? cur + ((nxt - cur) * k) / s : cur);
            end
        end
    endfunction

    // Play the recording once and compare with the golden model.
    // pause_at >= 0 pauses playback for 6 frames after pause_at frames.
    task automatic play_and_check(input int s, input bit is_slow, input bit is_interp,
                                  input int pause_at, input string name);
        int exp_q[$];
        int got_q[$];
        int len, n, i, mism;
        len    = int'(rec_len);
        speed  = 3'(s - 1);
        slow   = is_slow;
        interp = is_interp;
        golden(len, s, is_slow, is_interp, exp_q);

        dac_words.delete();
        capture_on = 1'b1;
        press(key_play);
        if (pause_at >= 0) begin
            wait_frames(pause_at);
            press(key_play);
            wait_frames(1);
            check(state == S_PLAY_PAUSE, {name, ": not paused"});
            wait_frames(6);
            press(key_play);
        end
        fork
            wait (state == S_IDLE);
            begin wait_frames(len * 8 + 40); end
        join_any
        disable fork;
        check(state == S_IDLE, {name, ": playback did not finish"});
        wait_frames(3);
        capture_on = 1'b0;

        // Silence (0) is sent while idle or paused; recorded samples are never 0
        foreach (dac_words[j]) if (dac_words[j] != 16'd0) got_q.push_back($signed(dac_words[j]));

        mism = 0;
        n = (got_q.size() < exp_q.size()) ? got_q.size() : exp_q.size();
        for (i = 0; i < n; i++) if (got_q[i] != exp_q[i]) begin
            if (mism < 5) $display("  %s: sample %0d = %0d, expected %0d", name, i, got_q[i], exp_q[i]);
            mism++;
        end
        if (got_q.size() != exp_q.size() || mism != 0) begin
            $display("FAIL: %s: %0d samples (expected %0d), %0d mismatches",
                     name, got_q.size(), exp_q.size(), mism);
            errors++;
        end else begin
            $display("PASS: %-26s %0d output samples match", name, got_q.size());
        end
    endtask

    // ------------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------------
    int idx_of [int];   // stream value -> stream index
    int prev_idx, gaps, len;

    initial begin
        $dumpfile("tb_AudioCore.vcd");
        $dumpvars(0, tb_AudioCore);
        for (int i = 0; i < 5000; i++) idx_of[int'(stream(i))] = i;

        rst_n      = 1'b0;
        init_done  = 1'b0;
        key_rec    = 1'b0;
        key_play   = 1'b0;
        key_stop   = 1'b0;
        speed      = 3'd0;
        slow       = 1'b0;
        interp     = 1'b0;
        capture_on = 1'b0;

        repeat (10) @(posedge bclk);
        rst_n = 1'b1;
        wait_frames(2);
        check(state == S_INIT, "core must wait for codec configuration");
        init_done = 1'b1;
        wait_frames(1);
        check(state == S_IDLE, "idle after configuration");

        // Play with nothing recorded is ignored
        press(key_play);
        wait_frames(1);
        check(state == S_IDLE, "play ignored with empty memory");

        // ---- 1. record / pause / resume / stop ----
        press(key_rec);
        wait_frames(1);
        check(state == S_REC, "recording");
        wait_frames(11);
        press(key_rec);
        wait_frames(1);
        check(state == S_REC_PAUSE, "recording paused");
        wait_frames(5);
        press(key_rec);
        wait_frames(12);
        press(key_stop);
        wait_frames(1);
        check(state == S_IDLE, "idle after stop");
        len = int'(rec_len);
        check(len >= 20 && len <= 26, $sformatf("recorded length %0d", len));
        check(seconds == 7'(len / SAMPLE_RATE) || seconds == 7'(len / SAMPLE_RATE + 1),
              $sformatf("seconds %0d for %0d samples", seconds, len));

        gaps = 0;
        prev_idx = -1;
        for (int a = 0; a < len; a++) begin
            if (!idx_of.exists(int'(mem[a]))) begin
                check(0, $sformatf("mem[%0d] = %0d is not from the input stream", a, mem[a]));
            end else begin
                if (prev_idx >= 0 && idx_of[int'(mem[a])] != prev_idx + 1) gaps++;
                check(idx_of[int'(mem[a])] > prev_idx, "recorded samples out of order");
                prev_idx = idx_of[int'(mem[a])];
            end
        end
        check(gaps == 1, $sformatf("expected one gap from the pause, found %0d", gaps));
        if (errors == 0) $display("PASS: record/pause/stop: %0d samples, 1 gap", len);

        // ---- 2. playback speeds ----
        play_and_check(1, 1'b0, 1'b0, -1, "1x");
        check(seconds >= 7'(len / SAMPLE_RATE) && seconds <= 7'((len + 2) / SAMPLE_RATE),
              $sformatf("1x playback seconds %0d", seconds));
        play_and_check(3, 1'b0, 1'b0, -1, "3x fast");
        play_and_check(8, 1'b0, 1'b0, -1, "8x fast");
        play_and_check(2, 1'b1, 1'b0, -1, "1/2x slow, repeat");
        play_and_check(3, 1'b1, 1'b1, -1, "1/3x slow, interpolated");
        play_and_check(8, 1'b1, 1'b1, -1, "1/8x slow, interpolated");

        // ---- 3. pause during playback ----
        play_and_check(1, 1'b0, 1'b0, 5, "1x with pause/resume");

        // ---- 4. stop during playback ----
        speed = 3'd0; slow = 1'b1; interp = 1'b0;
        press(key_play);
        wait_frames(4);
        check(state == S_PLAY, "playing before stop");
        press(key_stop);
        wait_frames(1);
        check(state == S_IDLE, "idle after stop during playback");
        if (errors == 0) $display("PASS: stop during playback");

        // ---- 5. memory full ----
        press(key_rec);
        wait_frames(MAX_SAMPLES + 4);
        check(state == S_IDLE, "recording stops when memory is full");
        check(rec_len == 21'(MAX_SAMPLES), $sformatf("rec_len %0d after full", rec_len));
        if (errors == 0) $display("PASS: auto-stop at %0d samples", MAX_SAMPLES);

        if (errors == 0) $display("TB_AUDIOCORE PASS");
        else             $display("TB_AUDIOCORE FAIL: %0d error(s)", errors);
        $finish;
    end

    // Global watchdog
    initial begin
        #20ms;
        $display("TB_AUDIOCORE FAIL: global timeout");
        $finish;
    end

endmodule
