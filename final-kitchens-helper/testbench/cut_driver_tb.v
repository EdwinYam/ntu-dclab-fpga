`timescale 1ns/100ps
`define CYCLE  20.0
`define H_CYCLE (`CYCLE/2)
`include   "../src/cut_driver.v"
`include   "models/stepper_decoder.v"

// Testbench for cut_driver.v. The first part is the original stimulus (a short
// cut request, a gap, then a request held until cut_end). The second part
// requests two strokes the way controller.v does (cut held until cut_end) and
// checks each stroke with stepper_decoder.v: 100 steps out, then 101 back (the
// reversal and cut_end each take effect one step late, see Top_tb.v).

module test_cut_controller_driver;

    localparam define_speed = 0.0002; // ms 200ns

/*=============== reg/wire declaration =============*/
	reg         clk;
    reg         rst_n;
    
    // I/O with controller
    reg         cut_i;
    wire        cut_end_o;
    
    // I/O with motor
    wire [3:0]  signal_o;

/*================ module instantiation ================*/

	cut_driver #(
        .define_cut_speed(define_speed)
    )DUT (
		.clk        (clk),
		.rst_n      (rst_n),
		.cut_i      (cut_i),
		.cut_end_o  (cut_end_o),
		.signal_o   (signal_o)
	);

    stepper_decoder dec (
        .clk   (clk),
        .coils (signal_o)
    );

	// Dump waveform file
	initial begin
		$dumpfile("cut_driver.vcd");
		$dumpvars;			
	end
	
	// clock signal settings
	initial begin
        clk = 1'b0;
        forever #(`H_CYCLE) clk = ~clk;
    end

    integer errors = 0;
    integer strokes0;

	// test_cut_controller_driver
	initial begin               
        rst_n = 0;
		#(`CYCLE*1.2);
		rst_n = 1;		
        #(`CYCLE*2); 
        
        // cut_i
        cut_i = 1;        	
        #(`CYCLE*5);
        cut_i = 0;  	
        #(`CYCLE*2); 
        cut_i = 1;         
        
        @(posedge cut_end_o) cut_i = 0;

        // two strokes, cut held until cut_end as controller.v does
        repeat (2) begin
            #(`CYCLE*50);
            strokes0 = dec.n_strokes;
            cut_i = 1;
            @(posedge cut_end_o) cut_i = 0;
            wait (dec.n_strokes == strokes0 + 1);
            $display("  stroke: %0d steps out, %0d back", dec.run1, dec.run2);
            if (dec.n_runs != 2 || dec.run1 != 100 || dec.run2 != 101 || dec.dir1 != -1) begin
                errors = errors + 1;
                $display("FAIL: stroke with %0d runs, %0d steps out, %0d back (expected 100, 101)",
                         dec.n_runs, dec.run1, dec.run2);
            end
        end
        if (dec.n_illegal != 0) begin
            errors = errors + 1;
            $display("FAIL: %0d illegal phase changes", dec.n_illegal);
        end
        if (errors == 0) $display("TB_CUT_DRIVER PASS: 2 strokes of 100 + 101 steps");
        else begin
            $display("TB_CUT_DRIVER FAIL: %0d error(s)", errors);
            $fatal(1);
        end
		$finish;
	end
    
    // abort if the design cannot halt
    initial begin
        #(`CYCLE * 1000000 );
        $display( "\n" );
        $display( "Your design doesn't finish all operations in reasonable interval." );
        $display( "Terminated at: ", $time, " ns" );
        $display( "TB_CUT_DRIVER FAIL: timeout" );
        $fatal(1);
    end
 
endmodule