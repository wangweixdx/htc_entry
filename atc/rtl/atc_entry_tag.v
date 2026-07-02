//=============================================================================
// atc_entry_tag.v — Single ATC Entry TAG storage + comparison (Verilog-2001)
// Stores: valid(1b), PV(1b), PASID(20b), FuncID(16b), VA(64b), STU(5b)
// Total TAG = 107 bits
// DATA fields (translated_addr, perm) stored in external SRAM
// NRU managed separately by atc_nru_replacer
//
// 17 parallel address comparators via generate.
//=============================================================================
`include "atc_defines.vh"

module atc_entry_tag (
    input                           clk,
    input                           rst_n,

    // ---- Write port ----
    input                           wr_en,
    input                           wr_valid,
    input                           wr_pv,
    input  [19:0]                   wr_pasid,
    input  [15:0]                   wr_func_id,
    input  [63:0]                   wr_va,
    input  [4:0]                    wr_stu,

    // ---- Comparison port (combinational) ----
    input                           cmp_en,
    input                           cmp_inv_mode,
    input                           cmp_pv,
    input  [19:0]                   cmp_pasid,
    input  [15:0]                   cmp_func_id,
    input  [16:0][63:0]             cmp_addr,  // 17 addresses

    // ---- Comparison results (combinational) ----
    output [16:0]                   hit,  // 1 per address
    output                          out_valid,
    output                          out_pv,
    output [19:0]                   out_pasid,
    output [15:0]                   out_func_id,
    output [63:0]                   out_va,
    output [4:0]                    out_stu
);

    //=========================================================================
    // Tag Storage (register)
    //=========================================================================
    reg                         tag_valid;
    reg                         tag_pv;
    reg [19:0]                  tag_pasid;
    reg [15:0]                  tag_func_id;
    reg [63:0]                  tag_va;
    reg [4:0]                   tag_stu;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_valid   <= 1'b0;
            tag_pv      <= 1'b0;
            tag_pasid   <= 20'd0;
            tag_func_id <= 16'd0;
            tag_va      <= 64'd0;
            tag_stu     <= 5'd0;
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
    wire pv_match;
    wire pv_nonzero;
    wire pasid_match;
    wire funcid_match;
    wire tag_base_match;
    wire inv_pv_valid;

    assign pv_match   = (cmp_pv == tag_pv);
    assign pv_nonzero = |tag_pv;
    assign pasid_match  = (cmp_pasid == tag_pasid);
    assign funcid_match = (cmp_func_id == tag_func_id);
    assign inv_pv_valid = |cmp_pv;

    // Tag base match (PV / PASID / FuncID rules — shared by all 17 addresses)
    reg tag_base_match_reg;
    always @(*) begin
        if (!cmp_en) begin
            tag_base_match_reg = 1'b0;
        end else if (cmp_inv_mode) begin
            if (!inv_pv_valid)
                tag_base_match_reg = tag_valid && funcid_match;
            else
                tag_base_match_reg = tag_valid && pv_match && pasid_match && funcid_match;
        end else begin
            tag_base_match_reg = pv_match && tag_valid && (
                ( pv_nonzero && pasid_match && funcid_match) ||
                (!pv_nonzero &&                  funcid_match)
            );
        end
    end
    assign tag_base_match = tag_base_match_reg;

    // 17 parallel address comparators
    wire [16:0]             addr_match;
    wire [16:0][63:0]       addr_masked_lu;
    wire [63:0]             addr_masked_entry;

    assign addr_masked_entry = apply_stu_mask(tag_va, tag_stu);

    genvar p;
    generate
        for (p = 0; p < 17; p = p + 1) begin : gen_prefetch_cmp
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

endmodule
