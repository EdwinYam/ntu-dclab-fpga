#!/bin/sh
# Compile and run every testbench in the repository.
# Needs Icarus Verilog (iverilog/vvp) and Verilator 5 on PATH, or run it in
# the container described by scripts/Dockerfile.sim:
#
#   docker build -t hdl-sim -f scripts/Dockerfile.sim scripts
#   docker run --rm -v "$PWD":/w -w /w hdl-sim sh scripts/run_sims.sh
#
# Waveforms (*.vcd) are written next to each testbench.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d)
FAILED=0

run() {  # name, directory, command
    printf '\n=== %s\n' "$1"
    if (cd "$2" && sh -c "$3"); then :; else echo "*** $1: command failed"; FAILED=1; fi
}

# Lab 1: roll-call random number generator (waveform only, FAST_SIM timing)
run "lab1 tb_Top" "$ROOT/lab1/src" \
    "iverilog -g2012 -DFAST_SIM -o $BUILD/lab1 tb_Top.sv Top.sv && vvp -n $BUILD/lab1 | tail -2"

# Lab 2: RSA-256 core, self-checking against a^3 mod 33
run "lab2 Rsa256Core_tb" "$ROOT/lab2/tb" \
    "iverilog -g2012 -o $BUILD/lab2 Rsa256Core_tb.sv 2>&1 | grep -v 'sorry: constant selects'; vvp -n $BUILD/lab2 | grep -E 'PASS|FAIL'"

# Lab 3: audio recorder (self-checking)
run "lab3 tb_I2cInitializer" "$ROOT/lab3/tb" \
    "iverilog -g2012 -o $BUILD/i2c tb_I2cInitializer.sv ../src/I2cInitializer.sv && vvp -n $BUILD/i2c | grep -E 'TB_I2C|FAIL'"
run "lab3 tb_AudioCore" "$ROOT/lab3/tb" \
    "verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --top-module tb_AudioCore -Mdir $BUILD/vac tb_AudioCore.sv ../src/AudioCore.sv ../src/AudRecorder.sv ../src/AudPlayer.sv ../src/AudDsp.sv > $BUILD/vac.log 2>&1 && $BUILD/vac/Vtb_AudioCore | grep -E 'PASS|FAIL'"
run "lab3 lint (verilator -Wall)" "$ROOT/lab3/src" \
    "verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-PINCONNECTEMPTY +define+SIMULATION --top-module DE2_115 DE2_115/DE2_115.sv AudioPll.sv I2cInitializer.sv AudRecorder.sv AudPlayer.sv AudDsp.sv AudioCore.sv Debounce.sv SevenSegDecimal.sv && echo 'lint clean'"

# Final project: Kitchen's Helper (waveform testbenches)
for t in supersonic_tb cut_driver_tb controller_tb supersonic_controller_tb Top_tb; do
    extra=""
    [ "$t" = supersonic_tb ] && extra="../src/supersonic.v"
    run "final $t" "$ROOT/final-kitchens-helper/testbench" \
        "iverilog -g2012 -o $BUILD/$t $t.v $extra && vvp -n $BUILD/$t | grep -v '^\$' | tail -3"
done

rm -rf "$BUILD"
exit $FAILED
