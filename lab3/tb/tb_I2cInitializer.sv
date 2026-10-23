// ============================================================================
// tb_I2cInitializer
// ----------------------------------------------------------------------------
// Self-checking testbench for I2cInitializer. A behavioral I2C slave models
// the WM8731 control port: it detects START/STOP, shifts in bytes on SCL
// rising edges and pulls SDA low in each ACK slot.
//
// Checks
//   * every transaction is exactly 3 bytes, the first being 0x34
//   * the acknowledged register words match the WM8731 table, in order
//   * a NACK injected on the 4th transaction makes the master retry that word
//     and sets o_nack
//   * SDA only changes while SCL is low, except for START and STOP
// ============================================================================
`timescale 1ns/1ps

module tb_I2cInitializer;

    localparam int CLK_DIV = 4;
    localparam int N_WORDS = 11;

    logic clk = 1'b0;
    logic rst_n;
    logic start;
    logic scl, sda_oe, done, nack;

    always #10 clk = ~clk;   // 50 MHz

    // Open-drain SDA with pull-up
    tri1  sda;
    logic slave_pull;
    assign sda = sda_oe     ? 1'b0 : 1'bz;
    assign sda = slave_pull ? 1'b0 : 1'bz;

    I2cInitializer #(.CLK_DIV(CLK_DIV), .USE_MIC(1'b1)) dut (
        .i_clk    (clk),
        .i_rst_n  (rst_n),
        .i_start  (start),
        .o_scl    (scl),
        .o_sda_oe (sda_oe),
        .i_sda    (sda),
        .o_done   (done),
        .o_nack   (nack)
    );

    // Expected WM8731 register writes (microphone input)
    logic [15:0] expected [N_WORDS];
    initial begin
        expected[0]  = 16'h1E00;  expected[1]  = 16'h0097;  expected[2]  = 16'h0297;
        expected[3]  = 16'h0479;  expected[4]  = 16'h0679;  expected[5]  = 16'h0815;
        expected[6]  = 16'h0A00;  expected[7]  = 16'h0C00;  expected[8]  = 16'h0E42;
        expected[9]  = 16'h1019;  expected[10] = 16'h1201;
    end

    // ------------------------------------------------------------------------
    // Behavioral slave
    // ------------------------------------------------------------------------
    int          bit_cnt;      // 0..7 data bits, 8 = ACK clock
    int          byte_cnt;
    logic [7:0]  shreg;
    logic [7:0]  bytes [3];
    bit          in_frame;
    bit          nack_this;    // NACK the address byte of this transaction
    int          trans_cnt;    // transactions started
    int          acked_cnt;    // register words accepted
    int          errors;

    initial begin
        slave_pull = 1'b0;
        in_frame   = 1'b0;
        trans_cnt  = 0;
        acked_cnt  = 0;
        errors     = 0;
    end

    // START: SDA falls while SCL is high
    always @(negedge sda) if (scl === 1'b1) begin
        in_frame  = 1'b1;
        bit_cnt   = 0;
        byte_cnt  = 0;
        trans_cnt = trans_cnt + 1;
        nack_this = (trans_cnt == 4);
    end

    // STOP: SDA rises while SCL is high
    always @(posedge sda) if (scl === 1'b1 && in_frame) begin
        in_frame = 1'b0;
        if (nack_this) begin
            $display("[%0t] transaction %0d NACKed (injected), expecting a retry", $time, trans_cnt);
        end else if (byte_cnt != 3) begin
            $display("FAIL: transaction %0d has %0d bytes", trans_cnt, byte_cnt);
            errors++;
        end else if (bytes[0] != 8'h34) begin
            $display("FAIL: device address 0x%02h, expected 0x34", bytes[0]);
            errors++;
        end else if (acked_cnt >= N_WORDS) begin
            $display("FAIL: extra register write 0x%04h", {bytes[1], bytes[2]});
            errors++;
        end else if ({bytes[1], bytes[2]} != expected[acked_cnt]) begin
            $display("FAIL: word %0d = 0x%04h, expected 0x%04h",
                     acked_cnt, {bytes[1], bytes[2]}, expected[acked_cnt]);
            errors++;
            acked_cnt++;
        end else begin
            $display("[%0t] R%0d <= 0x%03h  (word 0x%04h) OK", $time,
                     bytes[1][7:1], {bytes[1][0], bytes[2]}, {bytes[1], bytes[2]});
            acked_cnt++;
        end
    end

    // Data bits are sampled on SCL rising edges
    always @(posedge scl) if (in_frame) begin
        if (bit_cnt < 8) begin
            shreg   = {shreg[6:0], sda};
            bit_cnt = bit_cnt + 1;
        end else begin
            bit_cnt = 9;           // ACK clock
        end
    end

    // ACK is driven from the falling edge after the 8th bit to the next one
    always @(negedge scl) if (in_frame) begin
        if (bit_cnt == 8) begin
            if (byte_cnt < 3) bytes[byte_cnt] = shreg;
            byte_cnt   = byte_cnt + 1;
            slave_pull = !(nack_this && byte_cnt == 1);
        end else if (bit_cnt == 9) begin
            slave_pull = 1'b0;
            bit_cnt    = 0;
        end
    end

    // SDA may only change while SCL is low, except for START/STOP
    logic sda_prev;
    always @(posedge clk) begin
        sda_prev <= sda;
        if (rst_n && scl && sda !== sda_prev && in_frame &&
            !(dut.state == 3'd1 || dut.state == 3'd3)) begin   // S_START, S_STOP
            $display("FAIL: SDA changed while SCL high at %0t", $time);
            errors++;
        end
    end

    // ------------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------------
    initial begin
        $timeformat(-6, 2, " us", 10);
        $dumpfile("tb_I2cInitializer.vcd");
        $dumpvars(0, tb_I2cInitializer);

        rst_n = 1'b0;
        start = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        start = 1'b1;

        fork
            wait (done);
            begin
                repeat (200000) @(posedge clk);
                $display("FAIL: timeout waiting for o_done");
                errors++;
            end
        join_any
        disable fork;
        repeat (20) @(posedge clk);

        if (acked_cnt != N_WORDS) begin
            $display("FAIL: %0d words acknowledged, expected %0d", acked_cnt, N_WORDS);
            errors++;
        end
        if (trans_cnt != N_WORDS + 1) begin
            $display("FAIL: %0d transactions, expected %0d (one retry)", trans_cnt, N_WORDS + 1);
            errors++;
        end
        if (!nack) begin
            $display("FAIL: o_nack not set after injected NACK");
            errors++;
        end
        if (scl !== 1'b1 || sda !== 1'b1) begin
            $display("FAIL: bus not idle after configuration");
            errors++;
        end

        if (errors == 0) $display("TB_I2C PASS: %0d register writes, 1 retry", acked_cnt);
        else             $display("TB_I2C FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
