// ============================================================================
// icache.v  --  Direct-mapped, read-only instruction cache (Phase 1)
//
// Author : Sm Hasanuzzaman
// Style  : Verilog-2005, synthesizable, lint-clean target: verilator -Wall
//
// Organisation (defaults: 1 KiB cache, 16-byte lines, 32-bit addresses)
//   LINES  = CACHE_BYTES / LINE_BYTES          = 64 lines
//   WORDS  = LINE_BYTES / 4                     = 4 words per line
//
//   cpu_addr  [31 ........ 10][9 ...... 4][3 ... 2][1 0]
//              \__ TAG (22) __/\_INDEX(6)_/\_WORD_/\BYTE/
//                                          (2)     (2, ignored: word fetches)
//
// Timing
//   Hit  : 2 cycles  (IDLE -> LOOKUP)          -- synchronous (SRAM-style) read
//   Miss : 2 + WORDS x (memory latency) + 1     (IDLE -> LOOKUP -> REFILL -> RESP)
//
// Handshake (CPU side)
//   The CPU raises cpu_req with a word-aligned cpu_addr and HOLDS both until it
//   sees cpu_ready = 1 for one cycle. cpu_rdata is valid in that same cycle.
//
// Handshake (memory side)
//   During a refill the cache holds mem_req = 1 and mem_addr = address of the
//   word it needs. Memory answers with mem_valid = 1 for one cycle together
//   with mem_rdata. The cache then moves to the next word of the line.
//
// Constraints: LINE_BYTES >= 16, CACHE_BYTES >= 2*LINE_BYTES, both powers of 2.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module icache #(
    parameter integer ADDR_W      = 32,
    parameter integer CACHE_BYTES = 1024,
    parameter integer LINE_BYTES  = 16
) (
    input  wire              clk,
    input  wire              rst_n,        // asynchronous, active-low reset

    // ---------------- CPU instruction-fetch port ----------------
    input  wire              cpu_req,      // fetch request (held until ready)
    input  wire [ADDR_W-1:0] cpu_addr,     // word-aligned fetch address
    output wire              cpu_ready,    // 1 for one cycle: data valid
    output wire [31:0]       cpu_rdata,    // fetched instruction word

    // ---------------- Memory (refill) port ----------------------
    output wire              mem_req,      // cache needs a word from memory
    output wire [ADDR_W-1:0] mem_addr,     // address of that word
    input  wire              mem_valid,    // memory returns the word this cycle
    input  wire [31:0]       mem_rdata,    // the returned word

    // ---------------- Performance counters ----------------------
    output reg  [31:0]       hit_cnt,
    output reg  [31:0]       miss_cnt
);

    // ------------------------------------------------------------------------
    // 1. Derived geometry
    // ------------------------------------------------------------------------
    localparam integer LINES  = CACHE_BYTES / LINE_BYTES;   // number of lines
    localparam integer WORDS  = LINE_BYTES / 4;             // words per line
    localparam integer WORD_W = $clog2(WORDS);              // word-select bits
    localparam integer OFF_W  = WORD_W + 2;                 // + 2 byte bits
    localparam integer IDX_W  = $clog2(LINES);              // index bits
    localparam integer TAG_W  = ADDR_W - IDX_W - OFF_W;     // tag bits

    localparam [WORD_W-1:0] BEAT_ONE = {{(WORD_W-1){1'b0}}, 1'b1};

    // FSM state encoding
    localparam [1:0] S_IDLE   = 2'd0,   // wait for a request, start array read
                     S_LOOKUP = 2'd1,   // compare tag -> hit or miss
                     S_REFILL = 2'd2,   // fetch the line word by word
                     S_RESP   = 2'd3;   // return the requested word after refill

    // ------------------------------------------------------------------------
    // 2. Storage arrays
    //    valid : one bit per line, cleared at reset (cache starts empty)
    //    tag   : one TAG_W entry per line
    //    data  : LINES x WORDS words, addressed by {index, word}
    // ------------------------------------------------------------------------
    reg [LINES-1:0]  valid;
    reg [TAG_W-1:0]  tag_ram  [0:LINES-1];
    reg [31:0]       data_ram [0:LINES*WORDS-1];

    // ------------------------------------------------------------------------
    // 3. Registers
    // ------------------------------------------------------------------------
    reg [1:0]        state;
    reg [ADDR_W-1:0] req_addr;   // latched request address
    reg [WORD_W-1:0] beat;       // which word of the line is being refilled
    reg              valid_q;    // registered array outputs (sync read)
    reg [TAG_W-1:0]  tag_q;
    reg [31:0]       data_q;
    reg [31:0]       crit_q;     // requested ("critical") word seen during refill

    // ------------------------------------------------------------------------
    // 4. Address field extraction
    // ------------------------------------------------------------------------
    // From the incoming CPU address (used to start the array read in IDLE)
    wire [IDX_W-1:0]  cpu_idx  = cpu_addr[OFF_W +: IDX_W];
    wire [WORD_W-1:0] cpu_word = cpu_addr[2 +: WORD_W];

    // From the latched request (used for compare and refill)
    wire [TAG_W-1:0]  req_tag  = req_addr[ADDR_W-1 -: TAG_W];
    wire [IDX_W-1:0]  req_idx  = req_addr[OFF_W +: IDX_W];
    wire [WORD_W-1:0] req_word = req_addr[2 +: WORD_W];

    // Byte-offset bits are not needed for word fetches; tell the linter.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_byte_off = &{1'b0, req_addr[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------------
    // 5. Hit detection and outputs (combinational)
    // ------------------------------------------------------------------------
    wire hit       = valid_q && (tag_q == req_tag);
    wire last_beat = &beat;                       // beat == WORDS-1

    assign cpu_ready = ((state == S_LOOKUP) && hit) || (state == S_RESP);
    assign cpu_rdata = (state == S_RESP) ? crit_q : data_q;

    assign mem_req   = (state == S_REFILL);
    assign mem_addr  = {req_tag, req_idx, beat, 2'b00};

    // ------------------------------------------------------------------------
    // 6. Control path: FSM, valid bits, counters (with reset)
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            req_addr <= {ADDR_W{1'b0}};
            beat     <= {WORD_W{1'b0}};
            valid    <= {LINES{1'b0}};
            valid_q  <= 1'b0;
            hit_cnt  <= 32'd0;
            miss_cnt <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cpu_req) begin
                        req_addr <= cpu_addr;
                        valid_q  <= valid[cpu_idx];
                        state    <= S_LOOKUP;
                    end
                end

                S_LOOKUP: begin
                    if (hit) begin
                        hit_cnt <= hit_cnt + 32'd1;
                        state   <= S_IDLE;
                    end else begin
                        miss_cnt <= miss_cnt + 32'd1;
                        beat     <= {WORD_W{1'b0}};
                        state    <= S_REFILL;
                    end
                end

                S_REFILL: begin
                    if (mem_valid) begin
                        beat <= beat + BEAT_ONE;
                        if (last_beat) begin
                            valid[req_idx] <= 1'b1;   // line is now complete
                            state          <= S_RESP;
                        end
                    end
                end

                S_RESP: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // 7. Data path: tag/data arrays (no reset, like real SRAM macros)
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        // Synchronous read, started when a request is accepted
        if ((state == S_IDLE) && cpu_req) begin
            tag_q  <= tag_ram[cpu_idx];
            data_q <= data_ram[{cpu_idx, cpu_word}];
        end

        // Write during refill
        if ((state == S_REFILL) && mem_valid) begin
            data_ram[{req_idx, beat}] <= mem_rdata;
            if (beat == req_word)
                crit_q <= mem_rdata;
            if (last_beat)
                tag_ram[req_idx] <= req_tag;
        end
    end

    // ------------------------------------------------------------------------
    // 8. Parameter sanity check (simulation only)
    // ------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        if ((LINE_BYTES < 16) || (CACHE_BYTES < 2*LINE_BYTES) ||
            ((1 << $clog2(LINE_BYTES))  != LINE_BYTES) ||
            ((1 << $clog2(CACHE_BYTES)) != CACHE_BYTES)) begin
            $display("icache: illegal parameters (LINE_BYTES=%0d, CACHE_BYTES=%0d)",
                     LINE_BYTES, CACHE_BYTES);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
