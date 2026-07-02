//=============================================================================
// atc_top.sv — ATC Top-Level Module with TAG/SRAM split storage
//
// TAG storage:  2048 × 118b register-based (inside atc_entry_array)
// DATA storage: 2048 ×  68b SRAM (inside atc_entry_array → atc_data_sram)
// NRU storage:  2048 ×   2b register-based (inside atc_nru_replacer)
//=============================================================================
module atc_top
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    //=========================================================================
    // DMA Engine Interface (Lookup)
    //=========================================================================
    input  logic                         dma_lu_req_valid,
    input  logic [PV_WIDTH-1:0]          dma_lu_req_pv,
    input  logic [PASID_WIDTH-1:0]       dma_lu_req_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     dma_lu_req_func_id,
    input  logic [VA_WIDTH-1:0]          dma_lu_req_addr,

    output logic                         dma_lu_req_ready,
    output logic                         dma_lu_rsp_valid,
    output logic                         dma_lu_rsp_hit,
    output logic [PA_WIDTH-1:0]          dma_lu_rsp_translated_addr,
    output logic [PERM_WIDTH-1:0]        dma_lu_rsp_perm,

    //=========================================================================
    // DMA Relook Interface (second lookup, no prefetch)
    //=========================================================================
    input  logic                         dma_rl_req_valid,
    input  logic [PV_WIDTH-1:0]          dma_rl_req_pv,
    input  logic [PASID_WIDTH-1:0]       dma_rl_req_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     dma_rl_req_func_id,
    input  logic [VA_WIDTH-1:0]          dma_rl_req_addr,

    output logic                         dma_rl_req_ready,
    output logic                         dma_rl_rsp_valid,
    output logic                         dma_rl_rsp_hit,
    output logic [PA_WIDTH-1:0]          dma_rl_rsp_translated_addr,
    output logic [PERM_WIDTH-1:0]        dma_rl_rsp_perm,

    //=========================================================================
    // ATS Translation Completion Interface (from RC → Insert)
    //=========================================================================
    input  logic                         ats_comp_valid,
    input  logic [PV_WIDTH-1:0]          ats_comp_pv,
    input  logic [PASID_WIDTH-1:0]       ats_comp_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     ats_comp_func_id,
    input  logic [VA_WIDTH-1:0]          ats_comp_untranslated_addr,
    input  logic [PA_WIDTH-1:0]          ats_comp_translated_addr,
    input  logic [STU_WIDTH-1:0]         ats_comp_stu,
    input  logic [PERM_WIDTH-1:0]        ats_comp_perm,

    //=========================================================================
    // ATS Invalidation Request Interface (from RC → Invalidate)
    //=========================================================================
    input  logic                         ats_inv_req_valid,
    input  logic [FUNC_ID_WIDTH-1:0]     ats_inv_mask,
    input  logic                         ats_inv_pv_valid,
    input  logic [PV_WIDTH-1:0]          ats_inv_pv,
    input  logic [PASID_WIDTH-1:0]       ats_inv_pasid,
    input  logic [FUNC_ID_WIDTH-1:0]     ats_inv_func_id,
    input  logic [VA_WIDTH-1:0]          ats_inv_untranslated_addr,

    output logic                         ats_inv_req_ready,
    output logic                         ats_inv_ack_valid,
    output logic                         ats_comp_ready,

    //=========================================================================
    // CSR / Configuration Interface
    //=========================================================================
    input  logic [65:0]                  csr_ats_enable,     // per-function ATS enable
    input  logic                         csr_flr_req,
    input  logic [FUNC_ID_WIDTH-1:0]     csr_flr_func_id,
    input  logic [N_USER_W-1:0]          csr_num_users,      // partition config
    input  logic [65:0]                  csr_prefetch_enable, // per-function prefetch
    output logic                         csr_flr_req_done,    // FLR operation complete

    //=========================================================================
    // Prefetch Outputs (16 entries, valid when prefetch_enable[func_id]=1)
    //=========================================================================
    output logic [15:0]                  prefetch_rsp_valid,
    output logic [15:0]                  prefetch_hit,
    output logic [15:0][PA_WIDTH-1:0]   prefetch_pa,
    output logic [15:0][PERM_WIDTH-1:0] prefetch_perm,

    //=========================================================================
    // Status Outputs
    //=========================================================================
    output logic                         atc_active,
    output logic [ENTRY_IDX_W-1:0]       atc_entry_count
);

    //=========================================================================
    // CSR Interface (edge detect + sync)
    //=========================================================================
    logic [65:0] ats_enable_sync;
    logic [65:0] ats_enable_toggle;
    logic flr_req_sync;
    logic [FUNC_ID_WIDTH-1:0] flr_func_id_sync;
    logic [N_USER_W-1:0]      cfg_num_users;
    logic [WAY_IDX_W:0]        ea_nru_way_base;
    logic [WAY_IDX_W:0]        ea_nru_way_limit;

    atc_csr_if u_csr_if (
        .clk                (clk),
        .rst_n              (rst_n),
        .ats_enable         (csr_ats_enable),
        .flr_req_raw        (csr_flr_req),
        .flr_func_id_raw    (csr_flr_func_id),
        .csr_num_users      (csr_num_users),
        .ats_enable_sync    (ats_enable_sync),
        .ats_enable_toggle  (ats_enable_toggle),
        .flr_req_sync       (flr_req_sync),
        .flr_func_id_sync   (flr_func_id_sync),
        .cfg_num_users      (cfg_num_users)
    );

    //=========================================================================
    // Request / Response Packing
    //=========================================================================
    lu_request_t     dma_lu_req_packed;
    lu_response_t    dma_lu_rsp_packed;
    ats_completion_t ats_comp_packed;
    ats_inv_req_t    ats_inv_packed;

    assign dma_lu_req_packed = '{
        pv:               dma_lu_req_pv,
        pasid:            dma_lu_req_pasid,
        func_id:          dma_lu_req_func_id,
        untranslated_addr: dma_lu_req_addr
    };
    assign dma_lu_rsp_hit             = dma_lu_rsp_packed.hit || dma_lu_rsp_packed.pre_hit;
    assign dma_lu_rsp_translated_addr = dma_lu_rsp_packed.translated_addr;
    assign dma_lu_rsp_perm           = dma_lu_rsp_packed.perm;

    // ---- Relook Request / Response Packing ----
    lu_request_t     dma_rl_req_packed;
    lu_response_t    dma_rl_rsp_packed;

    assign dma_rl_req_packed = '{
        pv:               dma_rl_req_pv,
        pasid:            dma_rl_req_pasid,
        func_id:          dma_rl_req_func_id,
        untranslated_addr: dma_rl_req_addr
    };
    assign dma_rl_rsp_hit             = dma_rl_rsp_packed.hit;  // no pre_hit for relook
    assign dma_rl_rsp_translated_addr = dma_rl_rsp_packed.translated_addr;
    assign dma_rl_rsp_perm           = dma_rl_rsp_packed.perm;

    assign ats_comp_packed = '{
        pv:               ats_comp_pv,
        pasid:            ats_comp_pasid,
        func_id:          ats_comp_func_id,
        untranslated_addr: ats_comp_untranslated_addr,
        translated_addr:  ats_comp_translated_addr,
        stu:              ats_comp_stu,
        perm:             ats_comp_perm
    };

    assign ats_inv_packed = '{
        inv_mask:          ats_inv_mask,
        pv:                ats_inv_pv,
        pv_valid:          ats_inv_pv_valid,
        pasid:             ats_inv_pasid,
        func_id:           ats_inv_func_id,
        untranslated_addr: ats_inv_untranslated_addr
    };

    //=========================================================================
    // Internal wires: atc_ctrl ↔ atc_entry_array
    //=========================================================================

    // ---- TAG Compare ----
    logic [SET_IDX_W-1:0]               ea_set_idx;
    logic                               ea_set_en;
    logic                               ea_cmp_en;
    logic                               ea_cmp_inv_mode;
    logic [PV_WIDTH-1:0]                ea_cmp_pv;
    logic [PASID_WIDTH-1:0]             ea_cmp_pasid;
    logic [FUNC_ID_WIDTH-1:0]           ea_cmp_func_id;
    logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] ea_cmp_addr;

    logic [PREFETCH_COUNT-1:0][HIT_VEC_W-1:0] ea_hit_vectors;
    logic [WAY_IDX_W-1:0]               ea_hit_way_idx;
    logic                               ea_any_hit;
    logic [PV_WIDTH-1:0]                ea_hit_pv;

    // ---- SRAM Read Data ----
    logic [PA_WIDTH-1:0]                ea_sram_rd_pa;
    logic [PERM_WIDTH-1:0]              ea_sram_rd_perm;

    // ---- TAG Write ----
    logic                               ea_wr_en;
    logic [SET_IDX_W-1:0]               ea_wr_set_idx;
    logic [WAY_IDX_W-1:0]               ea_wr_way_idx;
    logic                               ea_wr_valid;
    logic [PV_WIDTH-1:0]                ea_wr_pv;
    logic [PASID_WIDTH-1:0]             ea_wr_pasid;
    logic [FUNC_ID_WIDTH-1:0]           ea_wr_func_id;
    logic [VA_WIDTH-1:0]                ea_wr_va;
    logic [STU_WIDTH-1:0]               ea_wr_stu;

    // ---- SRAM Write ----
    logic                               sram_wr_en;
    logic [SRAM_ADDR_W-1:0]             sram_wr_addr;
    logic [PA_WIDTH-1:0]                sram_wr_pa;
    logic [PERM_WIDTH-1:0]              sram_wr_perm;

    // ---- NRU ----
    logic [WAY_IDX_W-1:0]               ea_victim_way;
    logic                               ea_victim_valid;
    logic                               ea_nru_update_en;
    logic [WAY_IDX_W-1:0]               ea_nru_update_way;
    logic [NRU_HINT_W-1:0]              ea_nru_update_val;
    logic                               ea_nru_clear_all_used;
    logic                               ea_nru_decay_tick;

    // ---- Invalidation ----
    logic                               ea_inv_en;
    logic [SET_IDX_W-1:0]               ea_inv_set_idx;
    logic [WAY_IDX_W-1:0]               ea_inv_way_idx;
    logic                               ea_batch_clr_en;
    logic [FUNC_ID_WIDTH-1:0]           ea_batch_clr_func_id;
    logic                               ea_batch_clr_all;

    // ---- DupCheck ----
    logic [2:0]                         ea_dc_subset_id;
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0]                      ea_dc_valids;
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PV_WIDTH-1:0]        ea_dc_pvs;
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PASID_WIDTH-1:0]     ea_dc_pasids;
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][FUNC_ID_WIDTH-1:0]   ea_dc_funcids;
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][VA_WIDTH-1:0]        ea_dc_vas;
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][STU_WIDTH-1:0]       ea_dc_stus;

    //=========================================================================
    // ATC Controller
    //=========================================================================
    atc_ctrl u_ctrl (
        .clk                (clk),
        .rst_n              (rst_n),
        .dma_lu_req_valid   (dma_lu_req_valid),
        .dma_lu_req         (dma_lu_req_packed),
        .dma_lu_req_ready   (dma_lu_req_ready),
        .dma_lu_rsp_valid   (dma_lu_rsp_valid),
        .dma_lu_rsp         (dma_lu_rsp_packed),
        .dma_rl_req_valid   (dma_rl_req_valid),
        .dma_rl_req         (dma_rl_req_packed),
        .dma_rl_req_ready   (dma_rl_req_ready),
        .dma_rl_rsp_valid   (dma_rl_rsp_valid),
        .dma_rl_rsp         (dma_rl_rsp_packed),
        .ats_inv_req_ready  (ats_inv_req_ready),
        .ats_comp_ready     (ats_comp_ready),
        .flr_done           (csr_flr_req_done),
        .prefetch_rsp_valid (prefetch_rsp_valid),
        .ats_comp_valid     (ats_comp_valid),
        .ats_comp           (ats_comp_packed),
        //.ats_comp_ready     (),
        .ats_inv_req_valid  (ats_inv_req_valid),
        .ats_inv_req        (ats_inv_packed),
        .ats_inv_ack_valid  (ats_inv_ack_valid),
        .ats_enable         (ats_enable_sync),
        .ats_enable_toggle  (ats_enable_toggle),
        .flr_req            (flr_req_sync),
        .flr_func_id        (flr_func_id_sync),

        // TAG Compare
        .ea_set_idx         (ea_set_idx),
        .ea_set_en          (ea_set_en),
        .ea_cmp_en          (ea_cmp_en),
        .ea_cmp_inv_mode    (ea_cmp_inv_mode),
        .ea_cmp_pv          (ea_cmp_pv),
        .ea_cmp_pasid       (ea_cmp_pasid),
        .ea_cmp_func_id     (ea_cmp_func_id),
        .ea_cmp_addr        (ea_cmp_addr),
        .ea_hit_vectors     (ea_hit_vectors),
        .ea_hit_way_idx     (ea_hit_way_idx),
        .ea_any_hit         (ea_any_hit),
        .ea_hit_pv          (ea_hit_pv),
        .ea_sram_rd_pa      (ea_sram_rd_pa),
        .ea_sram_rd_perm    (ea_sram_rd_perm),

        // TAG Write
        .ea_wr_en           (ea_wr_en),
        .ea_wr_set_idx      (ea_wr_set_idx),
        .ea_wr_way_idx      (ea_wr_way_idx),
        .ea_wr_valid        (ea_wr_valid),
        .ea_wr_pv           (ea_wr_pv),
        .ea_wr_pasid        (ea_wr_pasid),
        .ea_wr_func_id      (ea_wr_func_id),
        .ea_wr_va           (ea_wr_va),
        .ea_wr_stu          (ea_wr_stu),

        // SRAM Write
        .sram_wr_en         (sram_wr_en),
        .sram_wr_addr       (sram_wr_addr),
        .sram_wr_pa         (sram_wr_pa),
        .sram_wr_perm       (sram_wr_perm),

        // NRU
        .ea_victim_way      (ea_victim_way),
        .ea_victim_valid    (ea_victim_valid),
        .ea_nru_update_en   (ea_nru_update_en),
        .ea_nru_update_way  (ea_nru_update_way),
        .ea_nru_update_val  (ea_nru_update_val),
        .ea_nru_clear_all_used (ea_nru_clear_all_used),

        // Invalidation
        .ea_inv_en          (ea_inv_en),
        .ea_inv_set_idx     (ea_inv_set_idx),
        .ea_inv_way_idx     (ea_inv_way_idx),
        .ea_batch_clr_en    (ea_batch_clr_en),
        .ea_batch_clr_func_id (ea_batch_clr_func_id),
        .ea_batch_clr_all   (ea_batch_clr_all),

        // DupCheck
        .ea_dupcheck_subset_id (ea_dc_subset_id),
        .ea_dupcheck_valids (ea_dc_valids),
        .ea_dupcheck_pvs    (ea_dc_pvs),
        .ea_dupcheck_pasids (ea_dc_pasids),
        .ea_dupcheck_funcids(ea_dc_funcids),
        .ea_dupcheck_vas    (ea_dc_vas),
        .ea_dupcheck_stus   (ea_dc_stus),

        // NRU Decay
        .ea_nru_decay_tick  (ea_nru_decay_tick),
        .ea_cfg_num_users   (cfg_num_users),
        .ea_nru_way_base    (ea_nru_way_base),
        .ea_nru_way_limit   (ea_nru_way_limit)
    );

    //=========================================================================
    // Entry Array (TAG + SRAM + NRU)
    //=========================================================================
    atc_entry_array u_entry_array (
        .clk                (clk),
        .rst_n              (rst_n),
        .sel_set_idx        (ea_set_idx),
        .sel_set_en         (ea_set_en),

        // TAG Write
        .wr_en              (ea_wr_en),
        .wr_set_idx         (ea_wr_set_idx),
        .wr_way_idx         (ea_wr_way_idx),
        .wr_valid           (ea_wr_valid),
        .wr_pv              (ea_wr_pv),
        .wr_pasid           (ea_wr_pasid),
        .wr_func_id         (ea_wr_func_id),
        .wr_va              (ea_wr_va),
        .wr_stu             (ea_wr_stu),

        // SRAM Write
        .sram_wr_en         (sram_wr_en),
        .sram_wr_addr       (sram_wr_addr),
        .sram_wr_pa         (sram_wr_pa),
        .sram_wr_perm       (sram_wr_perm),

        // TAG Compare
        .cmp_en             (ea_cmp_en),
        .cmp_inv_mode       (ea_cmp_inv_mode),
        .cmp_pv             (ea_cmp_pv),
        .cmp_pasid          (ea_cmp_pasid),
        .cmp_func_id        (ea_cmp_func_id),
        .cmp_addr           (ea_cmp_addr),
        .hit_vectors        (ea_hit_vectors),
        .hit_way_idx        (ea_hit_way_idx),
        .any_hit            (ea_any_hit),
        .hit_pv             (ea_hit_pv),

        // SRAM Read Data
        .sram_rd_pa         (ea_sram_rd_pa),
        .sram_rd_perm       (ea_sram_rd_perm),

        // NRU
        .victim_sel_en      (ea_wr_en),
        .victim_way         (ea_victim_way),
        .victim_valid       (ea_victim_valid),
        .nru_update_en      (ea_nru_update_en),
        .nru_update_way     (ea_nru_update_way),
        .nru_update_val     (ea_nru_update_val),
        .nru_clear_all_used (ea_nru_clear_all_used),
        .nru_decay_tick     (ea_nru_decay_tick),

        // Invalidation
        .inv_en             (ea_inv_en),
        .inv_way_idx        (ea_inv_way_idx),

        // DupCheck
        .dupcheck_subset_id (ea_dc_subset_id),
        .dupcheck_valids    (ea_dc_valids),
        .dupcheck_pvs       (ea_dc_pvs),
        .dupcheck_pasids    (ea_dc_pasids),
        .dupcheck_funcids   (ea_dc_funcids),
        .dupcheck_vas       (ea_dc_vas),
        .dupcheck_stus      (ea_dc_stus),

        // Batch Clear
        .batch_clr_en       (ea_batch_clr_en),
        .batch_clr_func_id  (ea_batch_clr_func_id),
        .batch_clr_all      (ea_batch_clr_all),
        .nru_way_base       (ea_nru_way_base),
        .nru_way_limit      (ea_nru_way_limit)
    );

    //=========================================================================
    // Status Outputs
    //=========================================================================
    //=========================================================================
    // Prefetch outputs (routed from lookup engine via atc_ctrl)
    //=========================================================================
    assign prefetch_hit  = '0;
    assign prefetch_pa   = '0;
    assign prefetch_perm = '0;

    //=========================================================================
    // Status Outputs
    //=========================================================================
    assign atc_active = dma_lu_req_valid || ats_comp_valid
                        || ats_inv_req_valid || flr_req_sync;

    // Simple entry count (currently selected set only)
    // For full count, a global accumulator across all 32 sets is needed.
    logic [5:0] valid_count;
    always_comb begin
        valid_count = 6'd0;
        // Count from dupcheck valids when available, else approximate
        for (int w = 0; w < N_WAYS; w++) begin
            valid_count = valid_count + {5'd0, ea_dc_valids[0][w]};
        end
    end
    assign atc_entry_count = {5'd0, valid_count};

endmodule : atc_top
