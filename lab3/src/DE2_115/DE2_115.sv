// ============================================================================
// DE2_115 (Lab 3 top level): audio recorder
// ----------------------------------------------------------------------------
// Controls
//   KEY[0]  record / pause recording
//   KEY[1]  play / pause playback
//   KEY[2]  stop
//   KEY[3]  reset (active low)
//   SW[2:0] speed factor s = SW[2:0] + 1 (1..8)
//   SW[3]   0: play s times faster, 1: play s times slower
//   SW[4]   slow mode: 0 = repeat samples, 1 = linear interpolation
//
// Display
//   HEX1..HEX0  elapsed seconds of the current recording / playback
//   HEX4        speed factor s
//   LEDR[0]     recording       LEDR[1] playing      LEDR[2] paused
//   LEDG[0]     codec configured LEDG[1] I2C retry occurred
//
// Clock domains
//   CLOCK_50  : PLL, I2C initializer
//   AUD_BCLK  : everything else (codec is the I2S master)
// ============================================================================
module DE2_115(
	input CLOCK_50,
	input CLOCK2_50,
	input CLOCK3_50,
	input ENETCLK_25,
	input SMA_CLKIN,
	output SMA_CLKOUT,
	output [8:0] LEDG,
	output [17:0] LEDR,
	input [3:0] KEY,
	input [17:0] SW,
	output [6:0] HEX0,
	output [6:0] HEX1,
	output [6:0] HEX2,
	output [6:0] HEX3,
	output [6:0] HEX4,
	output [6:0] HEX5,
	output [6:0] HEX6,
	output [6:0] HEX7,
	output LCD_BLON,
	inout [7:0] LCD_DATA,
	output LCD_EN,
	output LCD_ON,
	output LCD_RS,
	output LCD_RW,
	output UART_CTS,
	input UART_RTS,
	input UART_RXD,
	output UART_TXD,
	inout PS2_CLK,
	inout PS2_DAT,
	inout PS2_CLK2,
	inout PS2_DAT2,
	output SD_CLK,
	inout SD_CMD,
	inout [3:0] SD_DAT,
	input SD_WP_N,
	output [7:0] VGA_B,
	output VGA_BLANK_N,
	output VGA_CLK,
	output [7:0] VGA_G,
	output VGA_HS,
	output [7:0] VGA_R,
	output VGA_SYNC_N,
	output VGA_VS,
	input AUD_ADCDAT,
	inout AUD_ADCLRCK,
	inout AUD_BCLK,
	output AUD_DACDAT,
	inout AUD_DACLRCK,
	output AUD_XCK,
	output EEP_I2C_SCLK,
	inout EEP_I2C_SDAT,
	output I2C_SCLK,
	inout I2C_SDAT,
	output ENET0_GTX_CLK,
	input ENET0_INT_N,
	output ENET0_MDC,
	input ENET0_MDIO,
	output ENET0_RST_N,
	input ENET0_RX_CLK,
	input ENET0_RX_COL,
	input ENET0_RX_CRS,
	input [3:0] ENET0_RX_DATA,
	input ENET0_RX_DV,
	input ENET0_RX_ER,
	input ENET0_TX_CLK,
	output [3:0] ENET0_TX_DATA,
	output ENET0_TX_EN,
	output ENET0_TX_ER,
	input ENET0_LINK100,
	output ENET1_GTX_CLK,
	input ENET1_INT_N,
	output ENET1_MDC,
	input ENET1_MDIO,
	output ENET1_RST_N,
	input ENET1_RX_CLK,
	input ENET1_RX_COL,
	input ENET1_RX_CRS,
	input [3:0] ENET1_RX_DATA,
	input ENET1_RX_DV,
	input ENET1_RX_ER,
	input ENET1_TX_CLK,
	output [3:0] ENET1_TX_DATA,
	output ENET1_TX_EN,
	output ENET1_TX_ER,
	input ENET1_LINK100,
	input TD_CLK27,
	input [7:0] TD_DATA,
	input TD_HS,
	output TD_RESET_N,
	input TD_VS,
	inout [15:0] OTG_DATA,
	output [1:0] OTG_ADDR,
	output OTG_CS_N,
	output OTG_WR_N,
	output OTG_RD_N,
	input OTG_INT,
	output OTG_RST_N,
	input IRDA_RXD,
	output [12:0] DRAM_ADDR,
	output [1:0] DRAM_BA,
	output DRAM_CAS_N,
	output DRAM_CKE,
	output DRAM_CLK,
	output DRAM_CS_N,
	inout [31:0] DRAM_DQ,
	output [3:0] DRAM_DQM,
	output DRAM_RAS_N,
	output DRAM_WE_N,
	output [19:0] SRAM_ADDR,
	output SRAM_CE_N,
	inout [15:0] SRAM_DQ,
	output SRAM_LB_N,
	output SRAM_OE_N,
	output SRAM_UB_N,
	output SRAM_WE_N,
	output [22:0] FL_ADDR,
	output FL_CE_N,
	inout [7:0] FL_DQ,
	output FL_OE_N,
	output FL_RST_N,
	input FL_RY,
	output FL_WE_N,
	output FL_WP_N,
	inout [35:0] GPIO,
	input HSMC_CLKIN_P1,
	input HSMC_CLKIN_P2,
	input HSMC_CLKIN0,
	output HSMC_CLKOUT_P1,
	output HSMC_CLKOUT_P2,
	output HSMC_CLKOUT0,
	inout [3:0] HSMC_D,
	input [16:0] HSMC_RX_D_P,
	output [16:0] HSMC_TX_D_P,
	inout [6:0] EX_IO
);

    // ------------------------------------------------------------------------
    // Reset and codec master clock
    // ------------------------------------------------------------------------
    logic rst_n;
    logic clk_12m, pll_locked;

    assign rst_n = KEY[3];

    AudioPll u_pll (
        .i_clk_50  (CLOCK_50),
        .i_rst_n   (rst_n),
        .o_clk_12m (clk_12m),
        .o_locked  (pll_locked)
    );

    assign AUD_XCK = clk_12m;

    // ------------------------------------------------------------------------
    // Codec configuration over I2C (100 kHz SCL from 50 MHz)
    // ------------------------------------------------------------------------
    logic sda_oe, i2c_done, i2c_nack;

    I2cInitializer #(
        .CLK_DIV (125),
        .USE_MIC (1'b1)
    ) u_i2c (
        .i_clk    (CLOCK_50),
        .i_rst_n  (rst_n),
        .i_start  (pll_locked),
        .o_scl    (I2C_SCLK),
        .o_sda_oe (sda_oe),
        .i_sda    (I2C_SDAT),
        .o_done   (i2c_done),
        .o_nack   (i2c_nack)
    );

    assign I2C_SDAT = sda_oe ? 1'b0 : 1'bz;

    // The codec drives BCLK and both LRCKs in master mode
    assign AUD_BCLK    = 1'bz;
    assign AUD_ADCLRCK = 1'bz;
    assign AUD_DACLRCK = 1'bz;

    // ------------------------------------------------------------------------
    // Key debouncing in the BCLK domain (about 10 ms at 3 MHz BCLK)
    // ------------------------------------------------------------------------
    logic key_rec, key_play, key_stop;

    Debounce #(.CNT_N(30000)) u_deb_rec  (.i_in(KEY[0]), .i_clk(AUD_BCLK), .i_rst(rst_n),
                                          .o_debounced(), .o_neg(key_rec),  .o_pos());
    Debounce #(.CNT_N(30000)) u_deb_play (.i_in(KEY[1]), .i_clk(AUD_BCLK), .i_rst(rst_n),
                                          .o_debounced(), .o_neg(key_play), .o_pos());
    Debounce #(.CNT_N(30000)) u_deb_stop (.i_in(KEY[2]), .i_clk(AUD_BCLK), .i_rst(rst_n),
                                          .o_debounced(), .o_neg(key_stop), .o_pos());

    // i2c_done crosses from CLOCK_50 into the BCLK domain (level, two flops)
    logic [1:0] init_sync;
    always_ff @(posedge AUD_BCLK or negedge rst_n) begin
        if (!rst_n) init_sync <= 2'b00;
        else        init_sync <= {init_sync[0], i2c_done};
    end

    // ------------------------------------------------------------------------
    // Recorder / player core
    // ------------------------------------------------------------------------
    logic [15:0] sram_wdata;
    logic        sram_dq_oe;
    logic [2:0]  core_state;
    logic [6:0]  seconds;
    logic [20:0] rec_len;

    AudioCore #(
        .SAMPLE_RATE (32000),
        .MAX_SAMPLES (1 << 20)
    ) u_core (
        .i_rst_n      (rst_n),
        .i_clk        (AUD_BCLK),
        .i_init_done  (init_sync[1]),
        .i_key_rec    (key_rec),
        .i_key_play   (key_play),
        .i_key_stop   (key_stop),
        .i_speed      (SW[2:0]),
        .i_slow       (SW[3]),
        .i_interp     (SW[4]),
        .i_adclrck    (AUD_ADCLRCK),
        .i_adcdat     (AUD_ADCDAT),
        .i_daclrck    (AUD_DACLRCK),
        .o_dacdat     (AUD_DACDAT),
        .o_sram_addr  (SRAM_ADDR),
        .o_sram_wdata (sram_wdata),
        .i_sram_rdata (SRAM_DQ),
        .o_sram_dq_oe (sram_dq_oe),
        .o_sram_we_n  (SRAM_WE_N),
        .o_sram_oe_n  (SRAM_OE_N),
        .o_state      (core_state),
        .o_seconds    (seconds),
        .o_rec_len    (rec_len)
    );

    assign SRAM_DQ   = sram_dq_oe ? sram_wdata : 16'bz;
    assign SRAM_CE_N = 1'b0;
    assign SRAM_LB_N = 1'b0;
    assign SRAM_UB_N = 1'b0;

    // ------------------------------------------------------------------------
    // Displays
    // ------------------------------------------------------------------------
    localparam logic [2:0] ST_REC = 3'd2, ST_REC_PAUSE = 3'd3,
                           ST_PLAY = 3'd4, ST_PLAY_PAUSE = 3'd5;

    SevenSegDecimal u_seg_time (
        .i_value (seconds),
        .o_tens  (HEX1),
        .o_ones  (HEX0)
    );

    logic [6:0] speed_tens_unused;
    SevenSegDecimal u_seg_speed (
        .i_value ({3'b000, 4'(SW[2:0]) + 4'd1}),
        .o_tens  (speed_tens_unused),
        .o_ones  (HEX4)
    );

    assign HEX2 = 7'h7F;
    assign HEX3 = 7'h7F;
    assign HEX5 = 7'h7F;
    assign HEX6 = 7'h7F;
    assign HEX7 = 7'h7F;

    assign LEDR[0]    = (core_state == ST_REC);
    assign LEDR[1]    = (core_state == ST_PLAY);
    assign LEDR[2]    = (core_state == ST_REC_PAUSE) || (core_state == ST_PLAY_PAUSE);
    assign LEDR[17:3] = '0;
    assign LEDG[0]    = i2c_done;
    assign LEDG[1]    = i2c_nack;
    assign LEDG[8:2]  = '0;

endmodule
