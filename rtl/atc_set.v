//=============================================================================
// atc_set.v — 64-way Set: 64 atc_entry_tag + NRU replacer + hit encoder (Verilog-2001)
// TAG fields (107b) stored in register-based atc_entry_tag (64 instances).
// DATA fields (68b) stored in external atc_data_sram.
// NRU (2b × 64) managed by atc_nru_replacer.
//=============================================================================
`include "atc_defines.vh"

module atc_set (
    input                           clk,
    input                           rst_n,

    // ---- Set index (for SRAM address generation) ----
    input  [4:0]                    my_set_idx,

    // ---- Tag write port ----
    input                           wr_en,
    input  [5:0]                    wr_way,
    input                           wr_valid,
    input                           wr_pv,
    input  [19:0]                   wr_pasid,
    input  [15:0]                   wr_func_id,
    input  [63:0]                   wr_va,
    input  [4:0]                    wr_stu,

    // ---- Comparison port (all 64 ways in parallel) ----
    input                           cmp_en,
    input                           cmp_inv_mode,
    input                           cmp_pv,
    input  [19:0]                   cmp_pasid,
    input  [15:0]                   cmp_func_id,
    input  [16:0][63:0]             cmp_addr,

    // ---- Comparison results (17-vector) ----
    output [16:0][63:0]             hit_vectors,
    output [5:0]                    hit_way_idx,
    output                          any_hit,
    output                          hit_pv,

    // ---- Tag field readout (all ways, for dupcheck) ----
    output [63:0]                   all_pvs,
    output [63:0][19:0]             all_pasids,
    output [63:0][15:0]             all_funcids,
    output [63:0][63:0]             all_vas,
    output [63:0][4:0]              all_stus,
    output [63:0]                   all_valids,

    // ---- SRAM read address generation ----
    output                          sram_rd_en,
    output [10:0]                   sram_rd_addr,

    // ---- NRU victim selection ----
    input                           victim_sel_en,
    output [5:0]                    victim_way,
    output                          victim_valid,

    // ---- NRU update ----
    input                           nru_update_en,
    input  [5:0]                    nru_update_way,
    input  [1:0]                    nru_update_val,
    input                           nru_clear_all_used,
    input                           nru_decay_tick,
    input  [6:0]                    nru_way_base,
    input  [6:0]                    nru_way_limit,

    // ---- Invalidation ----
    input                           inv_way_en,
    input  [5:0]                    inv_way_idx
);

    //=========================================================================
    // Generate 64 atc_entry_tag instances
    //=========================================================================
    wire [63:0]                     entry_wr_en;
    wire [63:0][16:0]               entry_hit;
    wire [63:0]                     entry_pvs;
    wire [63:0][19:0]               entry_pasids;
    wire [63:0][15:0]               entry_funcids;
    wire [63:0][63:0]               entry_vas;
    wire [63:0][4:0]                entry_stus;
    wire [63:0]                     entry_valids;

    genvar w;
    generate
        for (w = 0; w < 64; w = w + 1) begin : gen_way
            assign entry_wr_en[w] = (wr_en && (wr_way == w[5:0]))
                                 || (inv_way_en && (inv_way_idx == w[5:0]));

            atc_entry_tag u_tag (
                .clk            (clk),
                .rst_n          (rst_n),
                .wr_en          (entry_wr_en[w]),
                .wr_valid       (inv_way_en ? 1'b0  : wr_valid),
                .wr_pv          (inv_way_en ? 1'b0  : wr_pv),
                .wr_pasid       (inv_way_en ? 20'd0 : wr_pasid),
                .wr_func_id     (inv_way_en ? 16'd0 : wr_func_id),
                .wr_va          (inv_way_en ? 64'd0 : wr_va),
                .wr_stu         (inv_way_en ? 5'd0  : wr_stu),
                .cmp_en         (cmp_en),
                .cmp_inv_mode   (cmp_inv_mode),
                .cmp_pv         (cmp_pv),
                .cmp_pasid      (cmp_pasid),
                .cmp_func_id    (cmp_func_id),
                .cmp_addr       (cmp_addr),
                .hit            (entry_hit[w]),
                .out_valid      (entry_valids[w]),
                .out_pv         (entry_pvs[w]),
                .out_pasid      (entry_pasids[w]),
                .out_func_id    (entry_funcids[w]),
                .out_va         (entry_vas[w]),
                .out_stu        (entry_stus[w])
            );
        end
    endgenerate

    //=========================================================================
    // Hit Vector Assembly & Encoder (17-vector: current + 16 prefetch)
    //=========================================================================
    genvar aidx, widx;
    generate
        for (aidx = 0; aidx < 17; aidx = aidx + 1) begin : gen_hit_v
            for (widx = 0; widx < 64; widx = widx + 1) begin : gen_hit_w
                assign hit_vectors[aidx][widx] = entry_hit[widx][aidx];
            end
        end
    endgenerate

    reg [5:0] enc_hit_way;
    reg       enc_any_hit;
    integer a, k;
    always @(*) begin
        enc_any_hit  = 1'b0;
        enc_hit_way  = 6'd0;
        for (a = 0; a < 17; a = a + 1) begin
            if (!enc_any_hit) begin
                for (k = 0; k < 64; k = k + 1) begin
                    if (!enc_any_hit && hit_vectors[a][k]) begin
                        enc_any_hit = 1'b1;
                        enc_hit_way = k[5:0];
                    end
                end
            end
        end
    end

    assign any_hit    = enc_any_hit && cmp_en;
    assign hit_way_idx = enc_hit_way;
    assign hit_pv     = entry_pvs[enc_hit_way];

    //=========================================================================
    // Tag Field Outputs (for dupcheck)
    //=========================================================================
    assign all_pvs      = entry_pvs;
    assign all_pasids   = entry_pasids;
    assign all_funcids  = entry_funcids;
    assign all_vas      = entry_vas;
    assign all_stus     = entry_stus;
    assign all_valids   = entry_valids;

    //=========================================================================
    // SRAM Read Address Generation
    //=========================================================================
    assign sram_rd_en   = any_hit;
    assign sram_rd_addr = {my_set_idx, enc_hit_way};

    //=========================================================================
    // NRU Replacer
    //=========================================================================
    atc_nru_replacer u_nru (
        .clk                (clk),
        .rst_n              (rst_n),
        .victim_sel_en      (victim_sel_en),
        .victim_way         (victim_way),
        .victim_valid       (victim_valid),
        .nru_update_en      (nru_update_en),
        .nru_update_way     (nru_update_way),
        .nru_update_val     (nru_update_val),
        .nru_state_out      (),
        .nru_clear_all_used (nru_clear_all_used),
        .nru_decay_tick     (nru_decay_tick),
        .way_base           (nru_way_base),
        .way_limit          (nru_way_limit)
    );

endmodule
