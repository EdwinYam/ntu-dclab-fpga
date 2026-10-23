`timescale 1ns/100ps
`define CYCLE  20.0
`define H_CYCLE (`CYCLE/2)
`include   "../src/controller.v"
`include   "models/track_model.v"
`include   "models/kh_monitor.v"

// Self-checking testbench for controller.v on its own.
//
// The ultrasonic front end (HC-SR04 + supersonic.v) and the cutter are
// replaced by stand-ins: after each trigger the stand-in reports the tray
// position from track_model.v as a distance in cycles (triggerSuc, then valid
// with the distance), and each cut request is answered with cut_end after
// CUT_CYCLES. The tray moves while `move` is high, so the loop is closed.
//
// For slice counts 2, 4, 8 and 16 the testbench checks that the run finishes,
// that the controller cuts slice_num - 1 times (slice_num pieces), that the cuts
// are evenly spaced along the initial length, that the tray returns to its
// starting position, and that the motors are stopped afterwards. The 4-slice
// run is paused and resumed once. kh_monitor.v checks the trigger width and the
// spacing between measurements throughout.
module test_controller;

    localparam SPACING_CYCLES      = 2000;   // 2.5M on the board (50 ms)
    localparam ECHO_DELAY_CYCLES   = 200;
    localparam ECHO_CYCLES_PER_MM  = 10;     // 290 on the board
    localparam TRACK_CYCLES_PER_MM = 2000;
    localparam CUT_CYCLES          = 4000;
    localparam START_MM            = 300;
    localparam MIN_MM              = 10;     // end of the track nearest the sensor
    localparam TOL_MM              = 6;      // tray travel during one measurement cycle
    localparam PAUSE_CYCLES        = 20000;
    localparam RUN_LIMIT           = 6000000;

/*=============== reg/wire declaration =============*/
	reg	        clk;
	reg	        rst_n;
    reg         start = 1'b0;
    reg         pause = 1'b0;
    reg  [4:0]  slice_num = 5'd0;

    // I/O with supersonic
    reg         valid = 1'b0;
    reg  [26:0] distance = 27'd0;
    reg         triggerSuc = 1'b0;
    wire        trigger;

    // I/O with Move Controller
    wire        move;
    wire        back;

    // I/O with Cut controller
    reg         cut_end = 1'b0;
    wire        cut;

    wire        finish;

    reg         echo = 1'b0;    // measurement in progress (for kh_monitor)
    wire [31:0] position;

/*================ module instantiation ================*/
	controller #(
        .SPACING_CYCLES(SPACING_CYCLES)
    ) DUT (
		.clk        (clk),
		.rst_n      (rst_n),
		.start      (start),
		.pause      (pause),
		.slice_num  (slice_num),
		.valid      (valid),
		.fail       (1'b0),
		.distance   (distance),
		.trigger    (trigger),
		.triggerSuc (triggerSuc),
		.move       (move),
		.back       (back),
		.cut_end    (cut_end),
		.cut        (cut),
        .finish     (finish)
	);

    track_model #(
        .START_MM      (START_MM),
        .MIN_MM        (MIN_MM),
        .CYCLES_PER_MM (TRACK_CYCLES_PER_MM)
    ) track (
        .clk         (clk),
        .drive       (move ? (back ? 4'b0110 : 4'b1001) : 4'b0000),
        .position_mm (position)
    );

    kh_monitor #(
        .SPACING_CYCLES(SPACING_CYCLES)
    ) mon (
        .clk      (clk),
        .trigger  (trigger),
        .echo     (echo),
        .cutting  (cut),
        .position (position)
    );

	// Dump waveform file (run with +vcd; the full run is several GB)
	initial if ($test$plusargs("vcd")) begin
		$dumpfile("controller.vcd");
		$dumpvars;
	end

	// clock signal settings
	initial begin
        clk = 1'b0;
        forever #(`H_CYCLE) clk = ~clk;
    end

    // Ultrasonic stand-in: answers every trigger with the current position
    integer echo_len;
    always @(negedge trigger) if (rst_n === 1'b1) begin
        repeat (ECHO_DELAY_CYCLES) @(posedge clk);
        echo_len = position * ECHO_CYCLES_PER_MM;
        echo       <= 1'b1;
        triggerSuc <= 1'b1;
        @(posedge clk) triggerSuc <= 1'b0;
        repeat (echo_len - 1) @(posedge clk);
        echo     <= 1'b0;
        valid    <= 1'b1;
        distance <= echo_len;
        @(posedge clk) valid <= 1'b0;
    end

    // Cutter stand-in: cut_end after CUT_CYCLES of cut
    integer cut_cnt = 0;
    always @(posedge clk) begin
        if (!cut) begin
            cut_cnt <= 0;
            cut_end <= 1'b0;
        end else if (cut_cnt == CUT_CYCLES - 1) begin
            cut_cnt <= 0;
            cut_end <= 1'b1;
        end else begin
            cut_cnt <= cut_cnt + 1;
            cut_end <= 1'b0;
        end
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

    task pulse_pause;
    begin
        @(posedge clk) pause <= 1'b1;
        @(posedge clk) pause <= 1'b0;
    end
    endtask

    // Pause, check that everything stops, then resume
    task pause_test;
        integer p, t, c, bad, i;
    begin
        pulse_pause;
        repeat (2) @(posedge clk);
        p = position; t = mon.n_trig; c = mon.n_cuts; bad = 0;
        for (i = 0; i < PAUSE_CYCLES; i = i + 1) begin
            @(posedge clk);
            if (move || back || cut || trigger) bad = bad + 1;
        end
        check(bad == 0,          "motor or trigger active while paused");
        check(position == p,     "tray moved while paused");
        check(mon.n_trig == t,   "trigger while paused");
        check(mon.n_cuts == c,   "cut while paused");
        pulse_pause;
        $display("  pause: held %0d cycles, tray stopped at %0d mm, resumed", PAUSE_CYCLES, p);
    end
    endtask

    // One full run: select n slices, start, wait for finish, check the result
    task run;
        input integer n;
        input integer pause_at_cut;   // pause after this many cuts (0: never)
        integer p0, cuts0, err0, cyc, k, len, seg, exp_mm, got, paused;
    begin
        err0  = errors + mon.errors;
        p0    = position;
        cuts0 = mon.n_cuts;
        paused = 0;
        slice_num = n;
        @(posedge clk) start <= 1'b1;
        @(posedge clk) start <= 1'b0;
        cyc = 0;
        while (!finish && cyc < RUN_LIMIT) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (pause_at_cut > 0 && !paused && echo &&
                mon.n_cuts - cuts0 == pause_at_cut) begin
                paused = 1;
                pause_test;
            end
        end
        check(finish, "run did not finish");
        check(mon.n_cuts - cuts0 == n - 1, "wrong number of cuts");
        // cut k happens once the measured distance drops below len - k*seg
        len = p0 * ECHO_CYCLES_PER_MM;
        seg = len / n;
        $write("  %0d slices: %0d cuts at", n, mon.n_cuts - cuts0);
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
        check(!move && !back && !cut, "motors still driven after finish");
        if (errors + mon.errors == err0) $display("PASS: %0d slices", n);
        else                             $display("FAIL: %0d slices", n);
    end
    endtask

	initial begin
        rst_n = 0;
		#(`CYCLE*1.2);
		rst_n = 1;
        #(`CYCLE*2);

        run(2, 0);
        run(4, 1);
        run(8, 0);
        run(16, 0);

        if (track.n_bad != 0) begin
            errors = errors + 1;
            $display("FAIL: unknown track drive pattern");
        end
        if (errors + mon.errors == 0)
            $display("TB_CONTROLLER PASS: %0d measurements, min spacing %0d cycles (>= %0d)",
                     mon.n_trig, mon.min_gap, SPACING_CYCLES);
        else begin
            $display("TB_CONTROLLER FAIL: %0d error(s)", errors + mon.errors);
            $fatal(1);
        end
		$finish;
	end

    // abort if the design cannot halt
    initial begin
        #(`CYCLE * 40000000);
        $display("TB_CONTROLLER FAIL: global timeout at %0t", $time);
        $fatal(1);
    end

endmodule
