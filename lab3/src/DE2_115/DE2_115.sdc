# Board oscillators
create_clock -period 20 [get_ports CLOCK_50]
create_clock -period 20 [get_ports CLOCK2_50]
create_clock -period 20 [get_ports CLOCK3_50]

# WM8731 bit clock (codec is the I2S master); constrained at 12 MHz, the
# fastest BCLK the codec produces from a 12 MHz MCLK
create_clock -name AUD_BCLK -period 83.333 [get_ports AUD_BCLK]

derive_pll_clocks
derive_clock_uncertainty

# CLOCK_50 / PLL logic and BCLK logic only exchange synchronized signals
set_clock_groups -asynchronous -group [get_clocks {CLOCK_50 *altpll*}] -group [get_clocks AUD_BCLK]
