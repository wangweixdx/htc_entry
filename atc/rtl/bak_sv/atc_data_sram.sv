//=============================================================================
// atc_data_sram.sv — ATC Data SRAM (Behavioral Model)
//
// Storage: 2048 words × 68 bits = ~18 KB
//   - translated_addr: 64 bits
//   - perm:             4 bits
//
// Single-port: 1 read OR 1 write per cycle
// Async read (combinational): data available same cycle as address
// Sync write: data written at posedge clk
//
// In physical implementation, replace this module with an SRAM macro.
// The async read is critical for 3-stage pipeline at 1GHz:
//   TAG compare → hit_way → SRAM addr → SRAM data out (all in one cycle)
//=============================================================================
module atc_data_sram
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Read port (async / combinational) ----
    input  logic                         rd_en,
    input  logic [SRAM_ADDR_W-1:0]       rd_addr,
    output logic [PA_WIDTH-1:0]          rd_translated_addr,
    output logic [PERM_WIDTH-1:0]        rd_perm,

    // ---- Write port (sync) ----
    input  logic                         wr_en,
    input  logic [SRAM_ADDR_W-1:0]       wr_addr,
    input  logic [PA_WIDTH-1:0]          wr_translated_addr,
    input  logic [PERM_WIDTH-1:0]        wr_perm
);

    //=========================================================================
    // SRAM Array (behavioral — replaced by SRAM macro in synthesis)
    //=========================================================================
    // Synthesis tool: use synopsys translate_off / translate_on or
    // equivalent pragmas to replace with target SRAM macro.
    // Example: "sram_2048x68 u_sram (.CLK(clk), .CEN(~rd_en & ~wr_en), ...)"

    logic [DATA_WIDTH-1:0] sram_array [0:SRAM_DEPTH-1];
    /* synopsys infer_sram */

    //=========================================================================
    // Async Read (combinational)
    //=========================================================================
    always_comb begin
        if (rd_en) begin
            {rd_translated_addr, rd_perm} = sram_array[rd_addr];
        end else begin
            rd_translated_addr = '0;
            rd_perm            = '0;
        end
    end

    //=========================================================================
    // Sync Write
    //=========================================================================
    always_ff @(posedge clk) begin
        if (wr_en) begin
            sram_array[wr_addr] <= {wr_translated_addr, wr_perm};
        end
    end

    //=========================================================================
    // Reset: clear all entries (for simulation only — SRAM macro may differ)
    //=========================================================================
    // In physical SRAM, reset is not typically supported natively.
    // The ATC controller invalidates entries by writing valid=0 to the TAG,
    // and clearing SRAM entries lazily (overwritten on next insert).
    // For simulation, we initialize to X to catch uninitialized reads.
    /* verilator lint_off INITIALDLY */
    /*
    initial begin
        for (int i = 0; i < SRAM_DEPTH; i++) begin
            sram_array[i] = '0;
        end
    end
    */

endmodule : atc_data_sram
