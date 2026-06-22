//=============================================================================
// atc_data_sram.v — ATC Data SRAM Behavioral Model (Verilog-2001)
//
// Storage: 2048 words × 68 bits = ~18 KB
//   - translated_addr: 64 bits
//   - perm:             4 bits
//
// Async read (combinational): data available same cycle as address
// Sync write: data written at posedge clk
//
// In physical implementation, replace this module with an SRAM macro.
//=============================================================================
`include "atc_defines.vh"

module atc_data_sram (
    input                           clk,
    input                           rst_n,

    // ---- Read port (async / combinational) ----
    input                           rd_en,
    input  [10:0]                   rd_addr,
    output [63:0]                   rd_translated_addr,
    output [3:0]                    rd_perm,

    // ---- Write port (sync) ----
    input                           wr_en,
    input  [10:0]                   wr_addr,
    input  [63:0]                   wr_translated_addr,
    input  [3:0]                    wr_perm
);

    //=========================================================================
    // SRAM Array (behavioral — replaced by SRAM macro in synthesis)
    //=========================================================================
    reg [67:0] sram_array [0:2047];

    //=========================================================================
    // Async Read (combinational)
    //=========================================================================
    reg [67:0] rd_data;
    always @(*) begin
        if (rd_en) begin
            rd_data = sram_array[rd_addr];
        end else begin
            rd_data = 68'd0;
        end
    end

    assign {rd_translated_addr, rd_perm} = rd_data;

    //=========================================================================
    // Sync Write
    //=========================================================================
    always @(posedge clk) begin
        if (wr_en) begin
            sram_array[wr_addr] <= {wr_translated_addr, wr_perm};
        end
    end

endmodule
