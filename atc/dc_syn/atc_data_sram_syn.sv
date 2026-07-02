//=============================================================================
// atc_data_sram_syn.sv — Synthesis Stub for DC (black-box SRAM placeholder)
// Physical implementation: replace with SF4X SRAM macro (2048 × 68b)
//=============================================================================
module atc_data_sram
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    output logic [PA_WIDTH-1:0]          rd_translated_addr,
    output logic [PERM_WIDTH-1:0]        rd_perm,
    input  logic                         rd_en,
    input  logic [SRAM_ADDR_W-1:0]       rd_addr,

    input  logic                         wr_en,
    input  logic [SRAM_ADDR_W-1:0]       wr_addr,
    input  logic [PA_WIDTH-1:0]          wr_translated_addr,
    input  logic [PERM_WIDTH-1:0]        wr_perm
);

    // Black-box placeholder: to be replaced by physical SRAM macro
    // Outputs are driven to '0 by default (actual SRAM macro will drive real values)
    // synopsys attribute dont_touch true

    always_comb begin
        rd_translated_addr = '0;
        rd_perm            = '0;
    end

endmodule : atc_data_sram
