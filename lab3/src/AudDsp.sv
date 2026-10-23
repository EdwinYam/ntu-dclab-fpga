// ============================================================================
// AudDsp
// ----------------------------------------------------------------------------
// Playback engine. Reads recorded samples from SRAM and produces one output
// sample per audio frame (i_frame) at a selectable speed:
//
//   fast mode (i_slow = 0): play every s-th sample           (1x .. 8x)
//   slow mode (i_slow = 1): stretch every sample over s frames (1/1x .. 1/8x)
//       i_interp = 0: zero-order hold (repeat the sample)
//       i_interp = 1: linear interpolation towards the next sample
//                     out = cur + (nxt - cur) * k / s,  k = 0 .. s-1
//
// where s = i_speed + 1. Signed division truncates toward zero.
//
// SRAM reads take two cycles: the address register is set, and the data is
// captured at the end of the following cycle. After every position change the
// engine fetches cur = mem[pos] and nxt = mem[pos + 1]; this finishes well
// within one audio frame (BCLK cycles per frame >= 32).
// ============================================================================
module AudDsp #(
    parameter int ADDR_W = 20
)(
    input  logic              i_clk,
    input  logic              i_rst_n,
    input  logic              i_start,     // pulse: start playback from address 0
    input  logic              i_stop,      // pulse: abort playback
    input  logic              i_pause,     // level: hold position, output silence
    input  logic              i_frame,     // pulse: one per audio sample period
    input  logic [2:0]        i_speed,     // s = i_speed + 1
    input  logic              i_slow,
    input  logic              i_interp,
    input  logic [ADDR_W-1:0] i_end_addr,  // address of the last recorded sample
    output logic [ADDR_W-1:0] o_sram_addr,
    input  logic [15:0]       i_sram_data,
    output logic [15:0]       o_sample,
    output logic              o_busy,
    output logic              o_done       // pulse: reached the end of the recording
);

    typedef enum logic [1:0] {F_CUR, F_NXT, F_READY} fetch_t;
    fetch_t fstate;

    logic              running;
    logic [ADDR_W:0]   pos;          // one extra bit so pos + s cannot wrap
    logic [2:0]        k;            // sub-step inside a stretched sample
    logic signed [15:0] cur, nxt;

    logic [3:0] s;
    assign s = {1'b0, i_speed} + 4'd1;

    assign o_busy = running;

    // ------------------------------------------------------------------------
    // Linear interpolation: cur + (nxt - cur) * k / s
    // ------------------------------------------------------------------------
    logic signed [16:0] diff;
    logic signed [20:0] prod;
    logic signed [20:0] quot;
    logic signed [16:0] interp_sum;
    logic signed [15:0] out_value;

    assign diff = {nxt[15], nxt} - {cur[15], cur};
    assign prod = diff * $signed({1'b0, k});

    always_comb begin
        // Division by small constants; synthesizes to fixed logic per case
        case (s)
            4'd1:    quot = prod;
            4'd2:    quot = prod / 21'sd2;
            4'd3:    quot = prod / 21'sd3;
            4'd4:    quot = prod / 21'sd4;
            4'd5:    quot = prod / 21'sd5;
            4'd6:    quot = prod / 21'sd6;
            4'd7:    quot = prod / 21'sd7;
            default: quot = prod / 21'sd8;
        endcase
        interp_sum = {cur[15], cur} + quot[16:0];
        out_value  = (i_slow && i_interp) ? interp_sum[15:0] : cur;
    end

    // ------------------------------------------------------------------------
    // Position update for the frame being emitted
    // ------------------------------------------------------------------------
    logic [ADDR_W:0] next_pos;
    logic [2:0]      next_k;

    always_comb begin
        next_pos = pos;
        next_k   = k;
        if (!i_slow) begin
            next_pos = pos + {{(ADDR_W-3){1'b0}}, s};
            next_k   = 3'd0;
        end else if ({1'b0, k} >= s - 4'd1) begin
            next_pos = pos + 1'b1;
            next_k   = 3'd0;
        end else begin
            next_k   = k + 1'b1;
        end
    end

    logic [ADDR_W:0] end_ext;
    assign end_ext = {1'b0, i_end_addr};

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            running     <= 1'b0;
            fstate      <= F_READY;
            pos         <= '0;
            k           <= 3'd0;
            cur         <= '0;
            nxt         <= '0;
            o_sram_addr <= '0;
            o_sample    <= '0;
            o_done      <= 1'b0;
        end else begin
            o_done <= 1'b0;

            if (i_stop) begin
                running  <= 1'b0;
                o_sample <= '0;
            end else if (i_start) begin
                running     <= 1'b1;
                pos         <= '0;
                k           <= 3'd0;
                o_sram_addr <= '0;
                fstate      <= F_CUR;
                o_sample    <= '0;
            end else begin
                // SRAM fetch sequence
                case (fstate)
                    F_CUR: begin
                        cur         <= i_sram_data;
                        o_sram_addr <= pos[ADDR_W-1:0] + 1'b1;
                        fstate      <= F_NXT;
                    end
                    F_NXT: begin
                        // Past the end there is no next sample: hold the current one
                        nxt    <= (pos + 1'b1 <= end_ext) ? i_sram_data : cur;
                        fstate <= F_READY;
                    end
                    default: ;
                endcase

                // One output sample per audio frame
                if (i_frame) begin
                    if (!running || i_pause || fstate != F_READY) begin
                        o_sample <= '0;
                    end else begin
                        o_sample <= out_value;
                        k        <= next_k;
                        if (next_pos > end_ext) begin
                            running <= 1'b0;
                            o_done  <= 1'b1;
                        end else if (next_pos != pos) begin
                            pos         <= next_pos;
                            o_sram_addr <= next_pos[ADDR_W-1:0];
                            fstate      <= F_CUR;
                        end
                    end
                end
            end
        end
    end

endmodule
