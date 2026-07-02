//=============================================================================
// atc_entry_tag.sv — Single ATC Entry TAG storage + comparison (register-based)
// Stores: valid(1b), PV(16b), PASID(16b), FuncID(16b), VA(64b), STU(5b) = 118b
// DATA fields (translated_addr, perm) are stored in external SRAM (atc_data_sram)
// NRU is managed separately by atc_nru_replacer
//
// This module is instantiated 64 times per set, 32 sets = 2048 instances total.
// All comparison is purely combinational from the tag register.
//=============================================================================
module atc_entry_tag
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Write port ----
    input  logic                         wr_en,
    input  logic                         wr_valid,
    input  logic [PV_WIDTH-1:0]          wr_pv,
    input  logic [PASID_WIDTH-1:0]       wr_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     wr_func_id,
    input  logic [VA_WIDTH-1:0]          wr_va,
    input  logic [STU_WIDTH-1:0]         wr_stu,

    // ---- Comparison port (combinational) ----
    input  logic                         cmp_en,
    input  logic                         cmp_inv_mode,
    input  logic [PV_WIDTH-1:0]          cmp_pv,
    input  logic [PASID_WIDTH-1:0]       cmp_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     cmp_func_id,
    input  logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] cmp_addr,  // 17 addresses

    // ---- Comparison results (combinational) ----
    output logic [PREFETCH_COUNT-1:0]    hit,  // 1 per address
    output logic                         out_valid,
    output logic [PV_WIDTH-1:0]          out_pv,
    output logic [PASID_WIDTH-1:0]       out_pasid,
    output logic [FUNC_ID_WIDTH-1:0]     out_func_id,
    output logic [VA_WIDTH-1:0]          out_va,
    output logic [STU_WIDTH-1:0]         out_stu
);

    //=========================================================================
    // Tag Storage (register — 118 bits)
    //=========================================================================
    logic                         tag_valid;
    logic [PV_WIDTH-1:0]          tag_pv;
    logic [PASID_WIDTH-1:0]       tag_pasid;
    logic [FUNC_ID_WIDTH-1:0]     tag_func_id;
    logic [VA_WIDTH-1:0]          tag_va;
    logic [STU_WIDTH-1:0]         tag_stu;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_valid   <= 1'b0;
            tag_pv      <= '0;
            tag_pasid   <= '0;
            tag_func_id <= '0;
            tag_va      <= '0;
            tag_stu     <= '0;
        end else if (wr_en) begin
            tag_valid   <= wr_valid;
            tag_pv      <= wr_pv;
            tag_pasid   <= wr_pasid;
            tag_func_id <= wr_func_id;
            tag_va      <= wr_va;
            tag_stu     <= wr_stu;
        end
    end

    //=========================================================================
    // Tag Comparison Logic (combinational)
    // 17 address comparators via generate: current + 16 prefetch offsets
    //=========================================================================
    logic pv_match;
    logic pv_nonzero;
    logic pasid_match;
    logic funcid_match;
    logic tag_base_match;
    logic inv_pv_valid;

    assign pv_match   = (cmp_pv == tag_pv);
    assign pv_nonzero = |tag_pv;
    assign pasid_match  = (cmp_pasid == tag_pasid);
    assign funcid_match = (cmp_func_id == tag_func_id);
    assign inv_pv_valid = |cmp_pv;

    // Tag base match (PV / PASID / FuncID rules — shared by all 17 addresses)
    always_comb begin
        if (!cmp_en) begin
            tag_base_match = 1'b0;
        end else if (cmp_inv_mode) begin
            if (!inv_pv_valid)
                tag_base_match = tag_valid && funcid_match;
            else
                tag_base_match = tag_valid && pv_match && pasid_match && funcid_match;
        end else begin
            tag_base_match = pv_match && tag_valid && (
                ( pv_nonzero && pasid_match && funcid_match) ||
                (!pv_nonzero &&                  funcid_match)
            );
        end
    end

    // 17 parallel address comparators (one per prefetch offset)
    logic [PREFETCH_COUNT-1:0]              addr_match;
    logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] addr_masked_lu;
    logic [VA_WIDTH-1:0]                      addr_masked_entry;

    assign addr_masked_entry = apply_stu_mask(tag_va, tag_stu);

    genvar p;
    generate
        for (p = 0; p < PREFETCH_COUNT; p++) begin : gen_prefetch_cmp
            assign addr_masked_lu[p] = apply_stu_mask(cmp_addr[p], tag_stu);
            assign addr_match[p]     = (addr_masked_lu[p] == addr_masked_entry);
            assign hit[p] = cmp_en && tag_base_match &&
                (cmp_inv_mode && !inv_pv_valid ? 1'b1 : addr_match[p]);
        end
    endgenerate

    //=========================================================================
    // Tag Field Outputs (for dupcheck readout)
    //=========================================================================
    assign out_valid   = tag_valid;
    assign out_pv      = tag_pv;
    assign out_pasid   = tag_pasid;
    assign out_func_id = tag_func_id;
    assign out_va      = tag_va;
    assign out_stu     = tag_stu;

endmodule : atc_entry_tag
