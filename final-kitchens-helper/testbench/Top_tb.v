`timescale 1ns/100ps
`define CYCLE  20.0
`define H_CYCLE (`CYCLE/2)
`include   "../src/Top.v"
`include   "../src/controller.v"
`include   "../src/supersonic.v"
`include   "../src/cut_driver.v"
`include   "../src/slice_counter.v"
`include   "../src/track_driver.v"
`include   "models/hcsr04_model.v"
`include   "models/track_model.v"
`include   "models/stepper_decoder.v"
`include   "models/kh_monitor.v"

// Self-checking testbench for the whole Kitchen's Helper datapath (Top.v).
//
// The board is replaced by models: hcsr04_model.v answers the trigger with an
// echo whose width follows the tray position, track_model.v moves the tray
// from the track motor drive pattern, and stepper_decoder.v counts the steps
// of the cutting stepper. The slice count is selected with slice_i pulses, as
// with KEY3 on the board.
//
// For slice counts 2, 4, 8 and 16 the testbench checks that the run finishes,
// that there are slice_num - 1 cut strokes at evenly spaced positions, that
// every stroke turns 100 steps one way and then back (see the note below), that
// the tray stands still while cutting, that it returns to its starting
// position and that both motors stop. kh_monitor.v checks the trigger width
// and the spacing between measurements.
//
// cut_driver.v reverses when its step counter reaches 100, but the step taken
// on that clock edge still uses the old direction, and the same happens when
// cut_end is raised. Each stroke is therefore 100 steps out and 101 steps back.
// When the coils are energised for the next stroke the rotor snaps one step to
// the starting phase, so the blade returns to the same position before every
// stroke and ends one step (0.9 degrees) past it after the last one.
module test_Top;

    localparam SPACING_CYCLES      = 2000;    // 2.5M on the board (50 ms)
    localparam CUT_SPEED           = 0.0004;  // ms per half step: 20-cycle steps (5 ms on the board)
    localparam MOTOR_SPEED         = 0.0002;  // ms: 10-cycle track driver clock (1000 ms on the board)
    localparam ECHO_DELAY_CYCLES   = 200;
    localparam ECHO_CYCLES_PER_MM  = 10;      // 290 on the board
    localparam TRACK_CYCLES_PER_MM = 2000;
    localparam START_MM            = 300;
    localparam MIN_MM              = 10;
    localparam TOL_MM              = 6;
    localparam STROKE_OUT          = 100;
    localparam STROKE_BACK         = 101;
    localparam RUN_LIMIT           = 6000000;

/*=============== reg/wire declaration =============*/
    reg         clk;
    reg         rst_n;
    reg         start_i = 1'b0;
    reg         pause_i = 1'b0;
    reg         slice_i = 1'b0;
    wire [4:0]  slice_num_o;
    wire        finish_o;

    // I/O with supersonic
    wire  echo_i;
    wire  trigger_o;

    // I/O with move motor
    wire [3:0]  move_signal_o;

    // I/O with cut motor
    wire [3:0]  cut_signal_o;

    wire [31:0] position;

/*================ module instantiation ================*/

	Top #(
        .define_cut_speed(CUT_SPEED),
        .define_motor_speed(MOTOR_SPEED),
        .SPACING_CYCLES(SPACING_CYCLES)
    )DUT (
		.clk            (clk),
		.rst_n          (rst_n),
		.start_i        (start_i),
		.pause_i        (pause_i),
		.slice_i        (slice_i),
		.slice_num_o    (slice_num_o),
		.finish_o       (finish_o),
		.echo_i         (echo_i),
		.trigger_o      (trigger_o),
		.move_signal_o  (move_signal_o),
		.cut_signal_o   (cut_signal_o)
	);

    hcsr04_model #(
        .ECHO_DELAY_CYCLES  (ECHO_DELAY_CYCLES),
        .ECHO_CYCLES_PER_MM (ECHO_CYCLES_PER_MM)
    ) sensor (
        .clk         (clk),
        .trig        (trigger_o),
        .distance_mm (position),
        .echo        (echo_i)
    );

    track_model #(
        .START_MM      (START_MM),
        .MIN_MM        (MIN_MM),
        .CYCLES_PER_MM (TRACK_CYCLES_PER_MM)
    ) track (
        .clk         (clk),
        .drive       (move_signal_o),
        .position_mm (position)
    );

    stepper_decoder cutter (
        .clk   (clk),
        .coils (cut_signal_o)
    );

    kh_monitor #(
        .SPACING_CYCLES(SPACING_CYCLES)
    ) mon (
        .clk      (clk),
        .trigger  (trigger_o),
        .echo     (echo_i),
        .cutting  (|cut_signal_o),
        .position (position)
    );

	// Dump waveform file (run with +vcd)
	initial if ($test$plusargs("vcd")) begin
		$dumpfile("Top.vcd");
		$dumpvars;
	end

	// clock signal settings
	initial begin
        clk = 1'b0;
        forever #(`H_CYCLE) clk = ~clk;
    end

    integer errors = 0;
    task check;
        input              cond;
        input [8*80-1:0]   msg;
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s at %0t", msg, $time);
        end
    endtask

    // every cut stroke: STROKE_OUT steps one way, STROKE_BACK steps back
    always @(cutter.stroke_end) begin
        if (cutter.n_runs != 2 || cutter.run1 != STROKE_OUT || cutter.run2 != STROKE_BACK) begin
            errors = errors + 1;
            $display("FAIL: cut stroke %0d: %0d runs, %0d steps out, %0d back (expected %0d, %0d) at %0t",
                     cutter.n_strokes, cutter.n_runs, cutter.run1, cutter.run2,
                     STROKE_OUT, STROKE_BACK, $time);
        end
    end

    task select_slices;
        input integer n;
        integer i;
    begin
        for (i = 0; i < 5 && slice_num_o != n; i = i + 1) begin
            @(posedge clk) slice_i <= 1'b1;
            @(posedge clk) slice_i <= 1'b0;
            @(posedge clk);
        end
        check(slice_num_o == n, "slice count not selectable");
    end
    endtask

    task run;
        input integer n;
        integer p0, cuts0, err0, cyc, k, len, seg, exp_mm, got;
    begin
        err0  = errors + mon.errors;
        p0    = position;
        cuts0 = mon.n_cuts;
        select_slices(n);
        @(posedge clk) start_i <= 1'b1;
        @(posedge clk) start_i <= 1'b0;
        cyc = 0;
        while (!finish_o && cyc < RUN_LIMIT) begin
            @(posedge clk);
            cyc = cyc + 1;
        end
        check(finish_o, "run did not finish");
        check(mon.n_cuts - cuts0 == n - 1, "wrong number of cut strokes");
        len = p0 * ECHO_CYCLES_PER_MM;
        seg = len / n;
        $write("  %0d slices: %0d cut strokes at", n, mon.n_cuts - cuts0);
        for (k = 1; k < n && k <= mon.n_cuts - cuts0; k = k + 1) begin
            exp_mm = (len - k * seg) / ECHO_CYCLES_PER_MM;
            got    = mon.cut_pos[cuts0 + k - 1];
            $write(" %0d", got);
            if (got > exp_mm || got < exp_mm - TOL_MM) begin
                errors = errors + 1;
                $display("\nFAIL: cut %0d at %0d mm, expected %0d-%0d mm",
                         k, got, exp_mm - TOL_MM, exp_mm);
            end
        end
        $display(" mm (start %0d mm), back at %0d mm after %0d cycles", p0, position, cyc);
        check(position + 1 >= p0, "tray did not return to its start position");
        repeat (100) @(posedge clk);
        check(move_signal_o == 4'b0000, "track motor still driven after finish");
        check(cut_signal_o  == 4'b0000, "cutting motor still energised after finish");
        if (errors + mon.errors == err0) $display("PASS: %0d slices", n);
        else                             $display("FAIL: %0d slices", n);
    end
    endtask

	initial begin
        rst_n = 0;
		#(`CYCLE*1.2);
		rst_n = 1;
        #(`CYCLE*2);

        run(2);
        run(4);
        run(8);
        run(16);

        if (cutter.n_illegal != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d illegal cutting-motor phase changes", cutter.n_illegal);
        end
        if (sensor.n_short != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d trigger pulses too short for the sensor", sensor.n_short);
        end
        if (track.n_bad != 0) begin
            errors = errors + 1;
            $display("FAIL: unknown track drive pattern");
        end
        $display("  cutter: %0d strokes of %0d+%0d steps, %0d snaps on energise, ends %0d step(s) from start",
                 cutter.n_strokes, STROKE_OUT, STROKE_BACK, cutter.n_snaps, cutter.position);
        if (errors + mon.errors == 0)
            $display("TB_TOP PASS: %0d measurements, min spacing %0d cycles (>= %0d), %0d cut strokes",
                     sensor.n_meas, mon.min_gap, SPACING_CYCLES, cutter.n_strokes);
        else begin
            $display("TB_TOP FAIL: %0d error(s)", errors + mon.errors);
            $fatal(1);
        end
		$finish;
	end

    // abort if the design cannot halt
    initial begin
        #(`CYCLE * 40000000);
        $display("TB_TOP FAIL: global timeout at %0t", $time);
        $fatal(1);
    end

endmodule
