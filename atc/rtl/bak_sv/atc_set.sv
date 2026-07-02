//=============================================================================
// atc_set.sv — 64-way Set: 64 atc_entry_tag instances + NRU replacer + hit encoder
// TAG fields (118b) stored in register-based atc_entry_tag (64 instances).
// DATA fields (68b) stored in external atc_data_sram.
// NRU (2b × 64) managed by atc_nru_replacer.
//
// Generates SRAM read address = {set_idx, hit_way_idx} for data retrieval.
//=============================================================================
module atc_set
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Set index (for SRAM address generation) ----
    input  logic [SET_IDX_W-1:0]         my_set_idx,

    // ---- Tag write port ----
    input  logic                         wr_en,
    input  logic [WAY_IDX_W-1:0]         wr_way,
    input  logic                         wr_valid,
    input  logic [PV_WIDTH-1:0]          wr_pv,
    input  logic [PASID_WIDTH-1:0]       wr_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     wr_func_id,
    input  logic [VA_WIDTH-1:0]          wr_va,
    input  logic [STU_WIDTH-1:0]         wr_stu,

    // ---- Comparison port (all 64 ways in parallel) ----
    input  logic                         cmp_en,
    input  logic                         cmp_inv_mode,
    input  logic [PV_WIDTH-1:0]          cmp_pv,
    input  logic [PASID_WIDTH-1:0]       cmp_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     cmp_func_id,
    input  logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] cmp_addr,

    // ---- Comparison results (17-vector: current + 16 prefetch) ----
    output logic [PREFETCH_COUNT-1:0][HIT_VEC_W-1:0]  hit_vectors,  // [addr_idx][way]
    output logic [WAY_IDX_W-1:0]         hit_way_idx,
    output logic                         any_hit,
    output logic [PV_WIDTH-1:0]          hit_pv,

    // ---- Tag field readout (all ways, for dupcheck) ----
    output logic [N_WAYS-1:0][PV_WIDTH-1:0]     all_pvs,
    output logic [N_WAYS-1:0][PASID_WIDTH-1:0]  all_pasids,
    output logic [N_WAYS-1:0][FUNC_ID_WIDTH-1:0] all_funcids,
    output logic [N_WAYS-1:0][VA_WIDTH-1:0]     all_vas,
    output logic [N_WAYS-1:0][STU_WIDTH-1:0]    all_stus,
    output logic [N_WAYS-1:0]                   all_valids,

    // ---- SRAM read address generation ----
    output logic                         sram_rd_en,
    output logic [SRAM_ADDR_W-1:0]       sram_rd_addr,

    // ---- NRU victim selection ----
    input  logic                         victim_sel_en,
    output logic [WAY_IDX_W-1:0]         victim_way,
    output logic                         victim_valid,

    // ---- NRU update ----
    input  logic                         nru_update_en,
    input  logic [WAY_IDX_W-1:0]         nru_update_way,
    input  logic [NRU_HINT_W-1:0]        nru_update_val,
    input  logic                         nru_clear_all_used,
    input  logic                         nru_decay_tick,
    input  logic [WAY_IDX_W:0]           nru_way_base,
    input  logic [WAY_IDX_W:0]           nru_way_limit,

    // ---- Invalidation ----
    input  logic                         inv_way_en,
    input  logic [WAY_IDX_W-1:0]         inv_way_idx
);

    //=========================================================================
    // Generate 64 atc_entry_tag instances (TAG only, register-based)
    //=========================================================================
    logic [N_WAYS-1:0]                   entry_wr_en;
    // 17-vector per-way hit: [prefetch_idx][way_idx]
    logic [N_WAYS-1:0][PREFETCH_COUNT-1:0] entry_hit;
    logic [N_WAYS-1:0][PV_WIDTH-1:0]     entry_pvs;
    logic [N_WAYS-1:0][PASID_WIDTH-1:0]  entry_pasids;
    logic [N_WAYS-1:0][FUNC_ID_WIDTH-1:0] entry_funcids;
    logic [N_WAYS-1:0][VA_WIDTH-1:0]     entry_vas;
    logic [N_WAYS-1:0][STU_WIDTH-1:0]    entry_stus;
    logic [N_WAYS-1:0]                   entry_valids;

    genvar w;
    generate
        for (w = 0; w < N_WAYS; w++) begin : gen_way
            assign entry_wr_en[w] = (wr_en && (wr_way == WAY_IDX_W'(w)))
                                 || (inv_way_en && (inv_way_idx == WAY_IDX_W'(w)));

            atc_entry_tag u_tag (
                .clk            (clk),
                .rst_n          (rst_n),
                .wr_en          (entry_wr_en[w]),
                .wr_valid       (inv_way_en ? 1'b0  : wr_valid),
                .wr_pv          (inv_way_en ? '0    : wr_pv),
                .wr_pasid       (inv_way_en ? '0    : wr_pasid),
                .wr_func_id     (inv_way_en ? '0    : wr_func_id),
                .wr_va          (inv_way_en ? '0    : wr_va),
                .wr_stu         (inv_way_en ? '0    : wr_stu),
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
    // Transpose: per-way → per-address
    for (genvar aidx = 0; aidx < PREFETCH_COUNT; aidx++) begin : gen_hit_v
        for (genvar widx = 0; widx < N_WAYS; widx++) begin : gen_hit_w
            assign hit_vectors[aidx][widx] = entry_hit[widx][aidx];
        end
    end

    logic [WAY_IDX_W-1:0] enc_hit_way;
    logic                 enc_any_hit;
    always_comb begin
        enc_any_hit  = 1'b0;
        enc_hit_way  = '0;
        // Priority: hit[0] first (current address), then hit[1..16] (prefetch)
        for (int a = 0; a < PREFETCH_COUNT; a++) begin
            if (!enc_any_hit) begin
                for (int w = 0; w < N_WAYS; w++) begin
                    if (!enc_any_hit && hit_vectors[a][w]) begin
                        enc_any_hit = 1'b1;
                        enc_hit_way = WAY_IDX_W'(w);
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
    //   Address = {set_idx, hit_way_idx}
    //   Read enable = comparison active AND hit detected
    //   The SRAM read is asynchronous — data available same cycle
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

endmodule : atc_set
