// ============================================================================
// AudioPll
// ----------------------------------------------------------------------------
// 12 MHz master clock for the WM8731 (AUD_XCK) from the 50 MHz board clock:
// 50 MHz * 6 / 25 = 12 MHz. With the codec in USB mode this gives exactly
// 32 kHz sampling (register R8 = 0x019).
//
// Synthesis uses the Cyclone IV altpll primitive. For simulation (define
// SIMULATION) a behavioral 12 MHz clock is generated instead.
// ============================================================================
module AudioPll (
    input  logic i_clk_50,
    input  logic i_rst_n,
    output logic o_clk_12m,
    output logic o_locked
);

`ifdef SIMULATION
    // 12 MHz: period 83.333 ns
    initial o_clk_12m = 1'b0;
    always #41.667 o_clk_12m <= ~o_clk_12m;
    assign o_locked = i_rst_n;
`else
    logic [4:0] clk_bus;

    altpll #(
        .bandwidth_type          ("AUTO"),
        .clk0_divide_by          (25),
        .clk0_duty_cycle         (50),
        .clk0_multiply_by        (6),
        .clk0_phase_shift        ("0"),
        .compensate_clock        ("CLK0"),
        .inclk0_input_frequency  (20000),          // ps
        .intended_device_family  ("Cyclone IV E"),
        .lpm_type                ("altpll"),
        .operation_mode          ("NORMAL"),
        .pll_type                ("AUTO"),
        .port_areset             ("PORT_USED"),
        .port_inclk0             ("PORT_USED"),
        .port_locked             ("PORT_USED"),
        .port_clk0               ("PORT_USED"),
        .port_clk1               ("PORT_UNUSED"),
        .port_clk2               ("PORT_UNUSED"),
        .port_clk3               ("PORT_UNUSED"),
        .port_clk4               ("PORT_UNUSED"),
        .width_clock             (5)
    ) u_altpll (
        .inclk  ({1'b0, i_clk_50}),
        .areset (~i_rst_n),
        .clk    (clk_bus),
        .locked (o_locked)
    );

    assign o_clk_12m = clk_bus[0];
`endif

endmodule
