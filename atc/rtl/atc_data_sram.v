//=============================================================================
// atc_data_sram.v — ATC Data SRAM Behavioral Model (Verilog-2001)
//
// Storage: 2048 words × 68 bits = ~18 KB
//   - translated_addr: 64 bits
//   - perm:             4 bits
//
// Sync read:  rd_en + rd_addr registered at posedge,
//             data available at next posedge.
// Sync write: data written at posedge clk.
//
// In physical implementation, replace this module with an SRAM macro.
//=============================================================================
`include "atc_defines.vh"

module atc_data_sram (
    input                           clk,
    input                           rst_n,

    // ---- Read port (sync: 1-cycle latency) ----
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
    // Sync Read: latch address at posedge, data available next cycle
    //=========================================================================
    reg         rd_en_r;
    reg [10:0]  rd_addr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en_r   <= 1'b0;
            rd_addr_r <= 11'd0;
        end else begin
            rd_en_r   <= rd_en;
            rd_addr_r <= rd_addr;
        end
    end

    reg [67:0] rd_data;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data <= 68'd0;
        end else if (rd_en_r) begin
            rd_data <= sram_array[rd_addr_r];
        end else begin
            rd_data <= 68'd0;
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
