// ============================================================================
// tb_icache.v  --  Smoke test for icache.v (Phase 1)
//
// What it checks
//   1. Every word returned to the CPU equals what memory holds at that address
//      (self-checking: any mismatch is an error).
//   2. The hit/miss counters match the values predicted by hand:
//        pass 1 over 256 bytes (64 words, 16 lines) : 16 misses, 48 hits
//        pass 2 over the same 256 bytes             :  0 misses, 64 hits
//        0x400 then 0x000 (same index, other tag)   :  2 conflict misses
//      => expected hits = 112, misses = 18
//
// Memory model: word at address A contains (A ^ 32'hA5A5_0000), returned
// after MEM_LAT clock cycles per word. No array is needed.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_icache;

    localparam integer CACHE_BYTES = 1024;
    localparam integer LINE_BYTES  = 16;
    localparam integer MEM_LAT     = 4;
    localparam [31:0]  PATTERN     = 32'hA5A5_0000;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    reg         cpu_req  = 1'b0;
    reg  [31:0] cpu_addr = 32'd0;
    wire        cpu_ready;
    wire [31:0] cpu_rdata;

    wire        mem_req;
    wire [31:0] mem_addr;
    reg         mem_valid = 1'b0;
    reg  [31:0] mem_rdata = 32'd0;

    wire [31:0] hit_cnt, miss_cnt;

    integer errors  = 0;
    integer lat_cnt = 0;
    integer i;

    icache #(
        .ADDR_W      (32),
        .CACHE_BYTES (CACHE_BYTES),
        .LINE_BYTES  (LINE_BYTES)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .cpu_req   (cpu_req),
        .cpu_addr  (cpu_addr),
        .cpu_ready (cpu_ready),
        .cpu_rdata (cpu_rdata),
        .mem_req   (mem_req),
        .mem_addr  (mem_addr),
        .mem_valid (mem_valid),
        .mem_rdata (mem_rdata),
        .hit_cnt   (hit_cnt),
        .miss_cnt  (miss_cnt)
    );

    // ---------------- Memory model with fixed latency ----------------------
    always @(posedge clk) begin
        mem_valid <= 1'b0;
        if (mem_req && !mem_valid) begin
            if (lat_cnt == MEM_LAT-1) begin
                mem_valid <= 1'b1;
                mem_rdata <= mem_addr ^ PATTERN;
                lat_cnt   <= 0;
            end else begin
                lat_cnt   <= lat_cnt + 1;
            end
        end
    end

    // ---------------- One CPU fetch, self-checked --------------------------
    task fetch(input [31:0] addr);
        begin
            @(negedge clk);
            cpu_req  = 1'b1;
            cpu_addr = addr;
            @(negedge clk);
            while (!cpu_ready) @(negedge clk);
            if (cpu_rdata !== (addr ^ PATTERN)) begin
                $display("ERROR @%0t: addr=0x%08h got=0x%08h exp=0x%08h",
                         $time, addr, cpu_rdata, addr ^ PATTERN);
                errors = errors + 1;
            end
            cpu_req = 1'b0;
        end
    endtask

    // ---------------- Stimulus ---------------------------------------------
    initial begin
`ifdef VCD
        // Only for Icarus/GTKWave (make sim). Vivado has its own wave viewer.
        $dumpfile("build/tb_icache.vcd");
        $dumpvars(0, tb_icache);
`endif

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        for (i = 0; i < 64; i = i + 1) fetch(i * 4);   // pass 1: cold
        for (i = 0; i < 64; i = i + 1) fetch(i * 4);   // pass 2: warm
        fetch(32'h0000_0400);                          // conflict: evicts line 0
        fetch(32'h0000_0000);                          // conflict: miss again

        repeat (5) @(posedge clk);

        $display("hits=%0d misses=%0d hit_rate=%0d%%",
                 hit_cnt, miss_cnt, (hit_cnt * 100) / (hit_cnt + miss_cnt));

        if (hit_cnt !== 32'd112) begin
            $display("ERROR: expected 112 hits");   errors = errors + 1;
        end
        if (miss_cnt !== 32'd18) begin
            $display("ERROR: expected 18 misses");  errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Safety net: stop if the design hangs
    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
