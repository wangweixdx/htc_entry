//=============================================================================
// atc_entry_array.sv — 2048-entry array: 32 × atc_set + 1 × atc_data_sram
//
// TAG storage:  2048 × 118b in register-based atc_entry_tag (inside atc_set)
// DATA storage: 2048 ×  68b in atc_data_sram (single-port, async read)
// NRU storage:  2048 ×   2b in register-based atc_nru_replacer (inside atc_set)
//
// Total storage: ~48 KB (30 KB reg + 18 KB SRAM)
//=============================================================================
module atc_entry_array
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Set select ----
    input  logic [SET_IDX_W-1:0]         sel_set_idx,
    input  logic                         sel_set_en,

    // ---- Tag write port ----
    input  logic                         wr_en,
    input  logic [SET_IDX_W-1:0]         wr_set_idx,
    input  logic [WAY_IDX_W-1:0]         wr_way_idx,
    input  logic                         wr_valid,
    input  logic [PV_WIDTH-1:0]          wr_pv,
    input  logic [PASID_WIDTH-1:0]       wr_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     wr_func_id,
    input  logic [VA_WIDTH-1:0]          wr_va,
    input  logic [STU_WIDTH-1:0]         wr_stu,

    // ---- SRAM data write port ----
    input  logic                         sram_wr_en,
    input  logic [SRAM_ADDR_W-1:0]       sram_wr_addr,
    input  logic [PA_WIDTH-1:0]          sram_wr_pa,
    input  logic [PERM_WIDTH-1:0]        sram_wr_perm,

    // ---- Comparison port ----
    input  logic                         cmp_en,
    input  logic                         cmp_inv_mode,
    input  logic [PV_WIDTH-1:0]          cmp_pv,
    input  logic [PASID_WIDTH-1:0]       cmp_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     cmp_func_id,
    input  logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] cmp_addr,

    // ---- Comparison results (from selected set) ----
    output logic [PREFETCH_COUNT-1:0][HIT_VEC_W-1:0]  hit_vectors,
    output logic [WAY_IDX_W-1:0]         hit_way_idx,
    output logic                         any_hit,
    output logic [PV_WIDTH-1:0]          hit_pv,

    // ---- SRAM read port (async, from selected set's hit) ----
    output logic [PA_WIDTH-1:0]          sram_rd_pa,
    output logic [PERM_WIDTH-1:0]        sram_rd_perm,

    // ---- NRU victim selection (from selected set) ----
    input  logic                         victim_sel_en,
    output logic [WAY_IDX_W-1:0]         victim_way,
    output logic                         victim_valid,

    // ---- NRU update (to selected set) ----
    input  logic                         nru_update_en,
    input  logic [WAY_IDX_W-1:0]         nru_update_way,
    input  logic [NRU_HINT_W-1:0]        nru_update_val,
    input  logic                         nru_clear_all_used,
    input  logic                         nru_decay_tick,
    input  logic [WAY_IDX_W:0]           nru_way_base,
    input  logic [WAY_IDX_W:0]           nru_way_limit,

    // ---- Invalidation ----
    input  logic                         inv_en,
    input  logic [WAY_IDX_W-1:0]         inv_way_idx,

    // ---- DupCheck: full traversal read (all sets, all ways) ----
    input  logic [2:0]                   dupcheck_subset_id,
    output logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0]                      dupcheck_valids,
    output logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PV_WIDTH-1:0]        dupcheck_pvs,
    output logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PASID_WIDTH-1:0]     dupcheck_pasids,
    output logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][FUNC_ID_WIDTH-1:0]   dupcheck_funcids,
    output logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][VA_WIDTH-1:0]        dupcheck_vas,
    output logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][STU_WIDTH-1:0]       dupcheck_stus,

    // ---- ATS Toggle / FLR: batch invalidation ----
    input  logic                         batch_clr_en,
    input  logic [FUNC_ID_WIDTH-1:0]     batch_clr_func_id,
    input  logic                         batch_clr_all
);

    //=========================================================================
    // Decoded signals per set
    //=========================================================================
    logic [N_SETS-1:0] set_wr_en;
    logic [N_SETS-1:0] set_cmp_en;
    logic [N_SETS-1:0] set_victim_sel_en;
    logic [N_SETS-1:0] set_nru_update_en;
    logic [N_SETS-1:0] set_inv_en;

    // Collected outputs per set
    logic [N_SETS-1:0][PREFETCH_COUNT-1:0][HIT_VEC_W-1:0]  set_hit_vectors;
    logic [N_SETS-1:0][WAY_IDX_W-1:0]        set_hit_way_idxs;
    logic [N_SETS-1:0]                       set_any_hits;
    logic [N_SETS-1:0][PV_WIDTH-1:0]         set_hit_pvs;
    logic [N_SETS-1:0][N_WAYS-1:0][PV_WIDTH-1:0]     set_all_pvs;
    logic [N_SETS-1:0][N_WAYS-1:0][PASID_WIDTH-1:0]  set_all_pasids;
    logic [N_SETS-1:0][N_WAYS-1:0][FUNC_ID_WIDTH-1:0] set_all_funcids;
    logic [N_SETS-1:0][N_WAYS-1:0][VA_WIDTH-1:0]     set_all_vas;
    logic [N_SETS-1:0][N_WAYS-1:0][STU_WIDTH-1:0]    set_all_stus;
    logic [N_SETS-1:0][N_WAYS-1:0]                   set_all_valids;
    logic [N_SETS-1:0][WAY_IDX_W-1:0]        set_victim_ways;
    logic [N_SETS-1:0]                       set_victim_valids;

    // SRAM read from each set
    logic [N_SETS-1:0]                       set_sram_rd_en;
    logic [N_SETS-1:0][SRAM_ADDR_W-1:0]      set_sram_rd_addr;

    // Batch clear
    logic [N_SETS-1:0]                       set_batch_clr;
    logic [N_SETS-1:0][WAY_IDX_W-1:0]        batch_clr_way_idx;
    logic [N_SETS-1:0][N_WAYS-1:0]           batch_clr_func_match;
    logic [WAY_IDX_W-1:0]                    batch_clr_way_counter;  // declared before generate for use inside

    //=========================================================================
    // Generate 32 atc_set instances
    //=========================================================================
    genvar s;
    generate
        for (s = 0; s < N_SETS; s++) begin : gen_set

            assign set_wr_en[s]         = wr_en && (wr_set_idx == SET_IDX_W'(s));
            assign set_cmp_en[s]        = cmp_en && sel_set_en
                                          && (sel_set_idx == SET_IDX_W'(s));
            assign set_victim_sel_en[s] = victim_sel_en && (sel_set_idx == SET_IDX_W'(s));
            assign set_nru_update_en[s] = nru_update_en && (sel_set_idx == SET_IDX_W'(s));
            assign set_inv_en[s]        = inv_en && (sel_set_idx == SET_IDX_W'(s));

            atc_set u_set (
                .clk                (clk),
                .rst_n              (rst_n),
                .my_set_idx         (SET_IDX_W'(s)),
                .wr_en              (set_wr_en[s] || set_batch_clr[s]),
                .wr_way             (batch_clr_en ? batch_clr_way_idx[s] : wr_way_idx),
                .wr_valid           (set_batch_clr[s] ? 1'b0  : wr_valid),
                .wr_pv              (set_batch_clr[s] ? '0    : wr_pv),
                .wr_pasid           (set_batch_clr[s] ? '0    : wr_pasid),
                .wr_func_id         (set_batch_clr[s] ? '0    : wr_func_id),
                .wr_va              (set_batch_clr[s] ? '0    : wr_va),
                .wr_stu             (set_batch_clr[s] ? '0    : wr_stu),
                .cmp_en             (set_cmp_en[s]),
                .cmp_inv_mode       (cmp_inv_mode),
                .cmp_pv             (cmp_pv),
                .cmp_pasid          (cmp_pasid),
                .cmp_func_id        (cmp_func_id),
                .cmp_addr           (cmp_addr),
                .hit_vectors        (set_hit_vectors[s]),
                .hit_way_idx        (set_hit_way_idxs[s]),
                .any_hit            (set_any_hits[s]),
                .hit_pv             (set_hit_pvs[s]),
                .all_pvs            (set_all_pvs[s]),
                .all_pasids         (set_all_pasids[s]),
                .all_funcids        (set_all_funcids[s]),
                .all_vas            (set_all_vas[s]),
                .all_stus           (set_all_stus[s]),
                .all_valids         (set_all_valids[s]),
                .sram_rd_en         (set_sram_rd_en[s]),
                .sram_rd_addr       (set_sram_rd_addr[s]),
                .victim_sel_en      (set_victim_sel_en[s]),
                .victim_way         (set_victim_ways[s]),
                .victim_valid       (set_victim_valids[s]),
                .nru_update_en      (set_nru_update_en[s]),
                .nru_update_way     (nru_update_way),
                .nru_update_val     (nru_update_val),
                .nru_clear_all_used (nru_clear_all_used && (sel_set_idx == SET_IDX_W'(s))),
                .nru_decay_tick     (nru_decay_tick),
                .nru_way_base       (nru_way_base),
                .nru_way_limit      (nru_way_limit),
                .inv_way_en         (set_inv_en[s]),
                .inv_way_idx        (inv_way_idx)
            );

            // Batch clear way counter
            assign batch_clr_way_idx[s] = WAY_IDX_W'(batch_clr_way_counter);

            // FLR func_id matching: compare each way's func_id against batch_clr_func_id
            for (genvar wf = 0; wf < N_WAYS; wf++) begin : gen_flr_match
                assign batch_clr_func_match[s][wf] = batch_clr_en && !batch_clr_all &&
                    (set_all_funcids[s][wf] == batch_clr_func_id);
            end

            assign set_batch_clr[s] = batch_clr_en &&
                (batch_clr_all || batch_clr_func_match[s][batch_clr_way_idx[s]]);
        end
    endgenerate

    //=========================================================================
    // Batch clear way counter FSM
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            batch_clr_way_counter <= '0;
        end else if (batch_clr_en) begin
            batch_clr_way_counter <= batch_clr_way_counter + 1'b1;
        end else begin
            batch_clr_way_counter <= '0;
        end
    end

    //=========================================================================
    // Output Mux: select results from the targeted set
    //=========================================================================
    assign hit_vectors  = set_hit_vectors[sel_set_idx];
    assign hit_way_idx    = set_hit_way_idxs[sel_set_idx];
    assign any_hit        = set_any_hits[sel_set_idx];
    assign hit_pv         = set_hit_pvs[sel_set_idx];
    assign victim_way     = set_victim_ways[sel_set_idx];
    assign victim_valid   = set_victim_valids[sel_set_idx];

    //=========================================================================
    // Data SRAM: 2048 words × 68 bits, async read
    //=========================================================================
    // Mux the SRAM read address from the active set
    logic                         sram_rd_en_muxed;
    logic [SRAM_ADDR_W-1:0]       sram_rd_addr_muxed;
    logic [PA_WIDTH-1:0]          sram_rd_pa_local;
    logic [PERM_WIDTH-1:0]        sram_rd_perm_local;

    assign sram_rd_en_muxed   = set_sram_rd_en[sel_set_idx];
    assign sram_rd_addr_muxed = set_sram_rd_addr[sel_set_idx];

    atc_data_sram u_data_sram (
        .clk                 (clk),
        .rst_n               (rst_n),
        .rd_en               (sram_rd_en_muxed),
        .rd_addr             (sram_rd_addr_muxed),
        .rd_translated_addr  (sram_rd_pa_local),
        .rd_perm             (sram_rd_perm_local),
        .wr_en               (sram_wr_en),
        .wr_addr             (sram_wr_addr),
        .wr_translated_addr  (sram_wr_pa),
        .wr_perm             (sram_wr_perm)
    );

    assign sram_rd_pa   = sram_rd_pa_local;
    assign sram_rd_perm = sram_rd_perm_local;

    //=========================================================================
    // DupCheck Output: route the right 8-set subset
    //=========================================================================
    for (genvar d = 0; d < DUPCHECK_SETS_PER; d++) begin : gen_dc_route
        assign dupcheck_valids[d]   = set_all_valids[d + dupcheck_subset_id * DUPCHECK_SETS_PER];
        assign dupcheck_pvs[d]      = set_all_pvs[d + dupcheck_subset_id * DUPCHECK_SETS_PER];
        assign dupcheck_pasids[d]   = set_all_pasids[d + dupcheck_subset_id * DUPCHECK_SETS_PER];
        assign dupcheck_funcids[d]  = set_all_funcids[d + dupcheck_subset_id * DUPCHECK_SETS_PER];
        assign dupcheck_vas[d]      = set_all_vas[d + dupcheck_subset_id * DUPCHECK_SETS_PER];
        assign dupcheck_stus[d]     = set_all_stus[d + dupcheck_subset_id * DUPCHECK_SETS_PER];
    end

endmodule : atc_entry_array
