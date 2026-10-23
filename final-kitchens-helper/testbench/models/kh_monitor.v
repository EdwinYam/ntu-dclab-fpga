// Protocol checker shared by the Kitchen's Helper testbenches.
//
//   trigger   ultrasonic trigger from the controller
//   echo      high while a measurement is in progress (the HC-SR04 echo, or
//             the stand-in measurement window in controller_tb.v)
//   cutting   high while a cut stroke is in progress
//   position  tray position in mm (track_model)
//
// The first trigger pulse after an echo starts a measurement. controller.v
// keeps repeating the 500-cycle pulse until the echo starts, so a sensor that
// is slow to answer sees further pulses; these are counted in n_retrig (the
// HC-SR04 ignores them while it is ranging) and the last one is cut short when
// the echo begins.
//
// Checks, reported as FAIL lines and counted in `errors`:
//   - the first trigger pulse of each measurement is at least
//     MIN_TRIG_CYCLES long (10 us);
//   - that pulse never rises less than SPACING_CYCLES after the previous echo
//     ended (the controller's 50 ms spacing between measurements);
//   - the tray does not move (more than POS_TOL_MM) during a cut stroke.
// It also counts triggers and cut strokes and records the tray position at the
// start of each stroke in cut_pos[].
module kh_monitor #(
    parameter SPACING_CYCLES  = 2500000,
    parameter MIN_TRIG_CYCLES = 500,
    parameter POS_TOL_MM      = 1
)(
    input        clk,
    input        trigger,
    input        echo,
    input        cutting,
    input [31:0] position
);
    integer errors   = 0;
    integer n_trig   = 0;      // measurements triggered
    integer n_retrig = 0;      // repeated pulses before the echo started
    integer n_cuts   = 0;
    integer min_gap  = -1;     // shortest echo-end to trigger gap seen
    integer trig_len = 0;
    integer gap      = 0;
    reg     seen_echo = 1'b0;
    reg     armed = 1'b1;      // next trigger pulse starts a measurement
    reg     first = 1'b0;      // current pulse is the first of its measurement
    reg     trig_d = 1'b0, echo_d = 1'b0, cut_d = 1'b0;
    reg [31:0] cut_start_pos = 0;
    reg [31:0] cut_pos [0:63];

    always @(posedge clk) begin
        trig_d <= trigger;
        echo_d <= echo;
        cut_d  <= cutting;

        trig_len <= trigger ? trig_len + 1 : 0;
        gap      <= (echo_d && !echo) ? 1 : gap + 1;
        if (echo_d && !echo) begin
            seen_echo <= 1'b1;
            armed     <= 1'b1;
        end

        if (trigger && !trig_d && !armed) n_retrig <= n_retrig + 1;
        if (trigger && !trig_d && armed) begin
            n_trig <= n_trig + 1;
            armed  <= 1'b0;
            first  <= 1'b1;
            if (seen_echo) begin
                if (min_gap < 0 || gap < min_gap) min_gap <= gap;
                if (gap < SPACING_CYCLES) begin
                    errors <= errors + 1;
                    $display("FAIL: trigger %0d cycles after the last echo (minimum %0d) at %0t",
                             gap, SPACING_CYCLES, $time);
                end
            end
        end
        if (trig_d && !trigger) first <= 1'b0;
        if (trig_d && !trigger && first && trig_len < MIN_TRIG_CYCLES) begin
            errors <= errors + 1;
            $display("FAIL: trigger pulse %0d cycles long (minimum %0d) at %0t",
                     trig_len, MIN_TRIG_CYCLES, $time);
        end

        if (cutting && !cut_d) begin
            if (n_cuts < 64) cut_pos[n_cuts] <= position;
            cut_start_pos <= position;
            n_cuts <= n_cuts + 1;
        end
        if (cut_d && !cutting &&
            (position > cut_start_pos + POS_TOL_MM || position + POS_TOL_MM < cut_start_pos)) begin
            errors <= errors + 1;
            $display("FAIL: tray moved from %0d mm to %0d mm during a cut stroke at %0t",
                     cut_start_pos, position, $time);
        end
    end
endmodule
