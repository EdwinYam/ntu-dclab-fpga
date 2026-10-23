// Behavioural model of the HC-SR04 ultrasonic ranging module.
//
// A trigger pulse at least MIN_TRIG_CYCLES clock cycles long (10 us = 500
// cycles at 50 MHz) starts a measurement. When the trigger falls, the model
// waits ECHO_DELAY_CYCLES (the 40 kHz burst on the real part) and then holds
// echo high for distance_mm * ECHO_CYCLES_PER_MM cycles. The real part gives
// 5.8 us of echo per mm, i.e. 290 cycles per mm at 50 MHz. Testbenches pass a
// smaller value so that a run needs fewer cycles; every distance then scales
// by the same factor, so the controller sees the same relative positions.
//
// The distance is sampled when the echo starts. A trigger that is too short,
// or that arrives while a measurement is in progress, is ignored and counted
// in n_short / n_busy.
module hcsr04_model #(
    parameter MIN_TRIG_CYCLES    = 500,
    parameter ECHO_DELAY_CYCLES  = 200,
    parameter ECHO_CYCLES_PER_MM = 290
)(
    input             clk,
    input             trig,
    input      [31:0] distance_mm,
    output reg        echo
);
    localparam IDLE = 2'd0, DELAY = 2'd1, ECHO = 2'd2;

    reg  [1:0] state    = IDLE;
    reg        trig_d   = 1'b0;
    integer    trig_len = 0;   // cycles the trigger has been high
    integer    cnt      = 0;
    integer    echo_len = 0;

    integer    n_meas   = 0;   // measurements started
    integer    n_short  = 0;   // triggers shorter than MIN_TRIG_CYCLES
    integer    n_busy   = 0;   // triggers during a measurement

    initial echo = 1'b0;

    always @(posedge clk) begin
        trig_d   <= trig;
        trig_len <= trig ? trig_len + 1 : 0;

        if (trig_d && !trig) begin                 // trigger falling edge
            if (state != IDLE)                n_busy  <= n_busy + 1;
            else if (trig_len < MIN_TRIG_CYCLES) n_short <= n_short + 1;
            else begin
                state <= DELAY;
                cnt   <= 0;
            end
        end

        case (state)
            DELAY: if (cnt == ECHO_DELAY_CYCLES - 1) begin
                       state    <= ECHO;
                       cnt      <= 0;
                       echo_len <= distance_mm * ECHO_CYCLES_PER_MM;
                       echo     <= 1'b1;
                       n_meas   <= n_meas + 1;
                   end else cnt <= cnt + 1;
            ECHO:  if (cnt == echo_len - 1) begin
                       state <= IDLE;
                       echo  <= 1'b0;
                   end else cnt <= cnt + 1;
            default: ;
        endcase
    end
endmodule
