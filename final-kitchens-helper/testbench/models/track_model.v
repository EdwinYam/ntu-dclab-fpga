// Behavioural model of the food tray on the track.
//
// track_driver.v drives the track motor through an H-bridge with two fixed
// patterns: 4'b1001 (move_i = 1, back_i = 0: forward, towards the sensor) and
// 4'b0110 (move_i = 1, back_i = 1: back, away from the sensor). 4'b0000 stops
// the motor. These are not a stepping sequence, so the model treats the motor
// as a DC motor running at constant speed: the tray moves 1 mm every
// CYCLES_PER_MM clock cycles that a drive pattern is applied. The position is
// the distance from the sensor in mm, clamped to [MIN_MM, MAX_MM] (the ends of
// the track). Feeding position_mm to hcsr04_model closes the loop.
module track_model #(
    parameter START_MM      = 200,
    parameter MIN_MM        = 20,
    parameter MAX_MM        = 400,
    parameter CYCLES_PER_MM = 1000
)(
    input            clk,
    input      [3:0] drive,
    output reg [31:0] position_mm
);
    localparam [3:0] FWD = 4'b1001, REV = 4'b0110, STOP = 4'b0000;

    integer acc     = 0;   // sub-mm travel, in clock cycles (+ = forward)
    integer n_bad   = 0;   // cycles with an unknown drive pattern
    integer n_clamp = 0;   // cycles spent pushing against an end of the track

    initial position_mm = START_MM;

    always @(posedge clk) begin
        case (drive)
            FWD: if (acc + 1 >= CYCLES_PER_MM) begin
                     acc <= 0;
                     if (position_mm > MIN_MM) position_mm <= position_mm - 1;
                     else                      n_clamp     <= n_clamp + 1;
                 end else acc <= acc + 1;
            REV: if (acc - 1 <= -CYCLES_PER_MM) begin
                     acc <= 0;
                     if (position_mm < MAX_MM) position_mm <= position_mm + 1;
                     else                      n_clamp     <= n_clamp + 1;
                 end else acc <= acc - 1;
            STOP: ;
            default: n_bad <= n_bad + 1;
        endcase
    end
endmodule
