module supersonic_controller#(
    parameter DisLen = 26,
    parameter SPACING_CYCLES = 2500000   // 50 ms between measurements
)(
    input       clk,
    input       rst_n,
    input       start_i,
    input       pause_i,
    input [4:0] slice_num_i,
    
    // I/O with move driver
    output      move_o,
    output      back_o,
    
    // I/O with cut controller
    input       cut_end_i,
    output      cut_o,
    
    // I/O with supersonic
    input       echo_i,
    
    output      finish_o
);
    
    wire trigger, triggerSuc;
    wire valid;
    wire [DisLen:0] distance;

    supersonic #(
        .DisLen(DisLen)
    ) supersonic0(
		.clk        (clk),
		.rst_n      (rst_n),
		.trigger    (trigger),
		.echo       (echo_i),
		.valid      (valid),
        .triggerSuc (triggerSuc),
		.distance   (distance)
    );
    
    controller #(
        .DisLen(DisLen),
        .SPACING_CYCLES(SPACING_CYCLES)
    ) controller0(
		.clk        (clk),
		.rst_n      (rst_n),
		.start      (start_i),
		.pause      (pause_i),
		.slice_num  (slice_num_i),
		.valid      (valid),
		.distance   (distance),
		.triggerSuc (triggerSuc),
		.trigger    (trigger),
		.move       (move_o),
        .back       (back_o),
		.cut_end    (cut_end_i),
		.cut        (cut_o),
        .finish     (finish_o)    
    );

endmodule