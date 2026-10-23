// Decoder for a 4-wire stepper driven in two-phase full-step mode, as
// cut_driver.v does it.
//
// Phase order 0011 -> 0110 -> 1100 -> 1001 -> 0011 counts as +1 step
// (cut_driver direction = 1), the reverse order as -1 (direction = 0).
// 4'b0000 means the coils are off. A jump between two non-adjacent phases, or
// any other pattern, is counted in n_illegal.
//
// A stroke runs from the moment the coils are energised to the moment they
// are switched off. For each stroke the decoder records the number of steps in
// the first direction (run1), in the opposite direction after that (run2), and
// the number of direction runs (n_runs, 2 for a normal out-and-back stroke).
// The stroke_end event fires when a stroke finishes.
//
// When the coils are energised again, the rotor snaps to the energised phase.
// If that phase is one step from where the rotor was left, the snap is counted
// in position (n_snaps), as the real motor would move.
module stepper_decoder (
    input       clk,
    input [3:0] coils
);
    reg  [3:0] prev     = 4'b0000;
    integer    rest     = -1;   // phase index the rotor was left at (-1: unknown)
    integer    position = 0;    // steps, including snaps on energise
    integer    n_illegal = 0;
    integer    n_snaps  = 0;
    integer    n_strokes = 0;

    // current stroke
    integer    dir      = 0;
    integer    runs     = 0;
    integer    r1       = 0;
    integer    r2       = 0;
    integer    start_pos = 0;

    // last finished stroke
    integer    run1     = 0;
    integer    run2     = 0;
    integer    n_runs   = 0;
    integer    dir1     = 0;    // direction of the first run (+1 / -1)
    integer    net      = 0;    // position change over the stroke

    event      stroke_end;

    function integer phase(input [3:0] p);
        case (p)
            4'b0011: phase = 0;
            4'b0110: phase = 1;
            4'b1100: phase = 2;
            4'b1001: phase = 3;
            default: phase = -1;
        endcase
    endfunction

    integer d, s;
    always @(posedge clk) begin
        if (coils != prev) begin
            if (coils != 4'b0000 && phase(coils) < 0) begin
                n_illegal = n_illegal + 1;
            end else if (prev == 4'b0000) begin
                // energise: possible snap, then a new stroke starts
                if (rest >= 0) begin
                    d = (phase(coils) - rest + 4) % 4;
                    if (d == 1)      begin position = position + 1; n_snaps = n_snaps + 1; end
                    else if (d == 3) begin position = position - 1; n_snaps = n_snaps + 1; end
                    else if (d == 2) n_illegal = n_illegal + 1;
                end
                start_pos = position;
                dir = 0; runs = 0; r1 = 0; r2 = 0;
            end else if (coils == 4'b0000) begin
                // de-energise: stroke finished
                rest      = phase(prev);
                run1      = r1;
                run2      = r2;
                n_runs    = runs;
                net       = position - start_pos;
                n_strokes = n_strokes + 1;
                -> stroke_end;
            end else begin
                d = (phase(coils) - phase(prev) + 4) % 4;
                if (d == 1)      s = 1;
                else if (d == 3) s = -1;
                else             s = 0;
                if (s == 0) n_illegal = n_illegal + 1;
                else begin
                    position = position + s;
                    if (s != dir) begin
                        runs = runs + 1;
                        dir  = s;
                        if (runs == 1) dir1 = s;
                    end
                    if (runs == 1)      r1 = r1 + 1;
                    else if (runs == 2) r2 = r2 + 1;
                end
            end
            prev = coils;
        end
    end
endmodule
