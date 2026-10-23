`timescale 1ns/100ps
`define CYCLE  20.0
`define H_CYCLE (`CYCLE/2)
`include   "../src/supersonic_controller.v"
`include   "../src/supersonic.v"
`include   "../src/controller.v"
`include   "models/hcsr04_model.v"
`include   "models/track_model.v"
`include   "models/kh_monitor.v"

// Self-checking testbench for supersonic_controller.v (supersonic.v +
// controller.v).
//
// hcsr04_model.v answers the trigger with an echo whose width follows the tray
// position from track_model.v, and the tray moves while move_o is high, so the
// ultrasonic loop is closed through the real supersonic.v. The cutter is a
// stand-in that answers each cut request with cut_end after CUT_CYCLES.
//
// For slice counts 2, 4 and 8 the testbench checks that the run finishes, that
// there are slice_num - 1 cuts at evenly spaced positions, that the tray
// returns to its starting position and that the motors stop. kh_monitor.v
// checks the trigger width and the spacing between measurements.
module test_supersonic_controller;

    localparam SPACING_CYCLES      = 2000;   // 2.5M on the board (50 ms)
    localparam ECHO_DELAY_CYCLES   = 200;
    localparam ECHO_CYCLES_PER_MM  = 10;     // 290 on the board
    localparam TRACK_CYCLES_PER_MM = 2000;
    localparam CUT_CYCLES          = 4000;
    localparam START_MM            = 300;
    localparam MIN_MM              = 10;
    localparam TOL_MM              = 6;
    localparam RUN_LIMIT           = 6000000;

/*=============== reg/wire declaration =============*/
	reg         clk;
    reg         rst_n;
    reg         start_i = 1'b0;
    reg         pause_i = 1'b0;
    reg [4:0]   slice_num_i = 5'd0;

    // I/O with move driver
    wire        move_o;
    wire        back_o;

    // I/O with cut controller
    reg         cut_end_i = 1'b0;
    wire        cut_o;

    // I/O with supersonic
    wire        echo_i;
    wire        trigger = DUT.trigger;

    wire        finish_o;
    wire [31:0] position;

/*================ module instantiation ================*/

	supersonic_controller #(
        .SPACING_CYCLES(SPACING_CYCLES)
    ) DUT (
		.clk        (clk),
		.rst_n      (rst_n),
		.start_i    (start_i),
		.pause_i    (pause_i),
		.slice_num_i(slice_num_i),
		.move_o     (move_o),
		.back_o     (back_o),
		.cut_end_i  (cut_end_i),
		.cut_o      (cut_o),
		.echo_i     (echo_i),
		.finish_o   (finish_o)
	);

    hcsr04_model #(
        .ECHO_DELAY_CYCLES  (ECHO_DELAY_CYCLES),
        .ECHO_CYCLES_PER_MM (ECHO_CYCLES_PER_MM)
    ) sensor (
        .clk         (clk),
        .trig        (trigger),
        .distance_mm (position),
        .echo        (echo_i)
    );

    track_model #(
        .START_MM      (START_MM),
        .MIN_MM        (MIN_MM),
        .CYCLES_PER_MM (TRACK_CYCLES_PER_MM)
    ) track (
        .clk         (clk),
        .drive       (move_o ? (back_o ? 4'b0110 : 4'b1001) : 4'b0000),
        .position_mm (position)
    );

    kh_monitor #(
        .SPACING_CYCLES(SPACING_CYCLES)
    ) mon (
        .clk      (clk),
        .trigger  (trigger),
        .echo     (echo_i),
        .cutting  (cut_o),
        .position (position)
    );

	// Dump waveform file (run with +vcd)
	initial if ($test$plusargs("vcd")) begin
		$dumpfile("supersonic_controller.vcd");
		$dumpvars;
	end

	// clock signal settings
	initial begin
        clk = 1'b0;
        forever #(`H_CYCLE) clk = ~clk;
    end

    // Cutter stand-in: cut_end after CUT_CYCLES of cut
    integer cut_cnt = 0;
    always @(posedge clk) begin
        if (!cut_o) begin
            cut_cnt   <= 0;
            cut_end_i <= 1'b0;
        end else if (cut_cnt == CUT_CYCLES - 1) begin
            cut_cnt   <= 0;
            cut_end_i <= 1'b1;
        end else begin
            cut_cnt   <= cut_cnt + 1;
            cut_end_i <= 1'b0;
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

    task run;
        input integer n;
        integer p0, cuts0, err0, cyc, k, len, seg, exp_mm, got;
    begin
        err0  = errors + mon.errors;
        p0    = position;
        cuts0 = mon.n_cuts;
        slice_num_i = n;
        @(posedge clk) start_i <= 1'b1;
        @(posedge clk) start_i <= 1'b0;
        cyc = 0;
        while (!finish_o && cyc < RUN_LIMIT) begin
            @(posedge clk);
            cyc = cyc + 1;
        end
        check(finish_o, "run did not finish");
        check(mon.n_cuts - cuts0 == n - 1, "wrong number of cuts");
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
        check(!move_o && !back_o && !cut_o, "motors still driven after finish");
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

        if (sensor.n_short != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d trigger pulses too short for the sensor", sensor.n_short);
        end
        if (track.n_bad != 0) begin
            errors = errors + 1;
            $display("FAIL: unknown track drive pattern");
        end
        if (errors + mon.errors == 0)
            $display("TB_SUPERSONIC_CONTROLLER PASS: %0d measurements, min spacing %0d cycles (>= %0d)",
                     sensor.n_meas, mon.min_gap, SPACING_CYCLES);
        else begin
            $display("TB_SUPERSONIC_CONTROLLER FAIL: %0d error(s)", errors + mon.errors);
            $fatal(1);
        end
		$finish;
	end

    // abort if the design cannot halt
    initial begin
        #(`CYCLE * 30000000);
        $display("TB_SUPERSONIC_CONTROLLER FAIL: global timeout at %0t", $time);
        $fatal(1);
    end

endmodule
