`timescale 1ns/100ps
`define CYCLE  20.0
`define H_CYCLE (`CYCLE/2)

module test_supersonic;


/*=============== reg/wire declaration =============*/
	reg	        clk;
	reg	        rst_n;
    reg         trigger;
    reg         echo;
    wire        valid;
    wire        triggerSuc;
    wire [26:0] distance;

/*================ module instantiation ================*/
	supersonic DUT(
		.clk        (clk),
		.rst_n      (rst_n),
		.trigger    (trigger),
		.echo       (echo),
		.valid      (valid),
        .triggerSuc (triggerSuc),
		.distance   (distance)
	);

	// Dump waveform file
	initial begin
		$dumpfile("supersonic.vcd");
		$dumpvars;
	end

	// clock signal settings
	initial begin
        clk = 1'b0;
        forever #(`H_CYCLE) clk = ~clk;
    end

	// test_supersonic
	initial begin          
        rst_n = 0;
		#(`CYCLE*1.2);
		rst_n = 1;
		
        trigger = 1;
        #(`CYCLE * 500 );
        trigger = 0;

        echo = 1;
        #(`CYCLE * 33'hFFFF );
        echo = 0;

        @(posedge valid) begin
            $display("%d",distance);
        end
        // the echo was high for 16'hFFFF cycles
        if (distance == 27'hFFFF) $display("TB_SUPERSONIC PASS: distance %0d cycles", distance);
        else begin
            $display("TB_SUPERSONIC FAIL: distance %0d cycles, expected %0d", distance, 16'hFFFF);
            $fatal(1);
        end
		#(`CYCLE * 5);
		$finish;
	end

endmodule
