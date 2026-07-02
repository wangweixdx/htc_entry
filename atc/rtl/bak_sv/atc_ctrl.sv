//=============================================================================
// atc_ctrl.sv — ATC Controller with TAG/SRAM split storage
//
// Coordinates: arbiter, lookup engine, dupcheck, invalidation handler,
//              NRU replacer, TAG write, and SRAM data write.
//
// TAG storage (register-based): 2048 × 118b via atc_entry_array
// DATA storage (SRAM):          2048 ×  68b via atc_data_sram
//=============================================================================
module atc_ctrl
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    //=========================================================================
    // External Request Interfaces
    //=========================================================================

    // ---- DMA Lookup ----
    input  logic                         dma_lu_req_valid,
    input  lu_request_t                  dma_lu_req,
    output logic                         dma_lu_rsp_valid,
    // ---- Flow-control Ready ----
    output logic                         dma_lu_req_ready,
    output logic                         dma_rl_req_ready,
    output logic                         ats_inv_req_ready,

    output lu_response_t                 dma_lu_rsp,

    // ---- DMA Relook (second lookup) ----
    input  logic                         dma_rl_req_valid,
    input  lu_request_t                  dma_rl_req,
    output logic                         dma_rl_rsp_valid,
    output lu_response_t                 dma_rl_rsp,

    // ---- ATS Completion (Insert) ----
    input  logic                         ats_comp_valid,
    input  ats_completion_t              ats_comp,
    output logic                         ats_comp_ready,

    // ---- ATS Invalidation ----
    input  logic                         ats_inv_req_valid,
    input  ats_inv_req_t                 ats_inv_req,
    output logic                         ats_inv_ack_valid,

    // ---- FLR Done ----
    output logic                         flr_done,

    // ---- Prefetch Response Valid ----
    output logic [15:0]                  prefetch_rsp_valid,

    // ---- CSR / Config Signals ----
    input  logic [65:0]                  ats_enable,        // per-function ATS enable
    input  logic [65:0]                  ats_enable_toggle, // per-function toggle (1-cycle pulse)
    input  logic                         flr_req,
    input  logic [FUNC_ID_WIDTH-1:0]     flr_func_id,

    //=========================================================================
    // Entry Array: TAG Compare Interface
    //=========================================================================
    output logic [SET_IDX_W-1:0]         ea_set_idx,
    output logic                         ea_set_en,
    output logic                         ea_cmp_en,
    output logic                         ea_cmp_inv_mode,
    output logic [PV_WIDTH-1:0]          ea_cmp_pv,
    output logic [PASID_WIDTH-1:0]       ea_cmp_pasid,
    output logic [FUNC_ID_WIDTH-1:0]     ea_cmp_func_id,
    output logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] ea_cmp_addr,

    // Compare results (17-vector: current + 16 prefetch)
    input  logic [PREFETCH_COUNT-1:0][HIT_VEC_W-1:0]  ea_hit_vectors,
    input  logic [WAY_IDX_W-1:0]         ea_hit_way_idx,
    input  logic                         ea_any_hit,
    input  logic [PV_WIDTH-1:0]          ea_hit_pv,

    // SRAM read data (async from selected set)
    input  logic [PA_WIDTH-1:0]          ea_sram_rd_pa,
    input  logic [PERM_WIDTH-1:0]        ea_sram_rd_perm,

    //=========================================================================
    // Entry Array: TAG Write Port
    //=========================================================================
    output logic                         ea_wr_en,
    output logic [SET_IDX_W-1:0]         ea_wr_set_idx,
    output logic [WAY_IDX_W-1:0]         ea_wr_way_idx,
    output logic                         ea_wr_valid,
    output logic [PV_WIDTH-1:0]          ea_wr_pv,
    output logic [PASID_WIDTH-1:0]       ea_wr_pasid,
    output logic [FUNC_ID_WIDTH-1:0]     ea_wr_func_id,
    output logic [VA_WIDTH-1:0]          ea_wr_va,
    output logic [STU_WIDTH-1:0]         ea_wr_stu,

    //=========================================================================
    // SRAM: Data Write Port
    //=========================================================================
    output logic                         sram_wr_en,
    output logic [SRAM_ADDR_W-1:0]       sram_wr_addr,
    output logic [PA_WIDTH-1:0]          sram_wr_pa,
    output logic [PERM_WIDTH-1:0]        sram_wr_perm,

    //=========================================================================
    // NRU Control
    //=========================================================================
    input  logic [WAY_IDX_W-1:0]         ea_victim_way,
    input  logic                         ea_victim_valid,
    output logic                         ea_nru_update_en,
    output logic [WAY_IDX_W-1:0]         ea_nru_update_way,
    output logic [NRU_HINT_W-1:0]        ea_nru_update_val,
    output logic                         ea_nru_clear_all_used,

    //=========================================================================
    // Invalidation
    //=========================================================================
    output logic                         ea_inv_en,
    output logic [SET_IDX_W-1:0]         ea_inv_set_idx,
    output logic [WAY_IDX_W-1:0]         ea_inv_way_idx,

    // Batch clear
    output logic                         ea_batch_clr_en,
    output logic [FUNC_ID_WIDTH-1:0]     ea_batch_clr_func_id,
    output logic                         ea_batch_clr_all,

    //=========================================================================
    // DupCheck
    //=========================================================================
    output logic [2:0]                   ea_dupcheck_subset_id,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0]                      ea_dupcheck_valids,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PV_WIDTH-1:0]        ea_dupcheck_pvs,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PASID_WIDTH-1:0]     ea_dupcheck_pasids,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][FUNC_ID_WIDTH-1:0]   ea_dupcheck_funcids,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][VA_WIDTH-1:0]        ea_dupcheck_vas,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][STU_WIDTH-1:0]       ea_dupcheck_stus,

    //=========================================================================
    // NRU Decay
    //=========================================================================
    output logic                         ea_nru_decay_tick,

    //=========================================================================
    // Partition Config
    //=========================================================================
    output logic [WAY_IDX_W:0]           ea_nru_way_base,   // partition way range start
    output logic [WAY_IDX_W:0]           ea_nru_way_limit,  // partition way range end

    //=========================================================================
    // Partition Config
    //=========================================================================
    input  logic [N_USER_W-1:0]          ea_cfg_num_users  // user partition config
);

    //=========================================================================
    // Internal Signals
    //=========================================================================

    // Arbiter
    logic               arb_req_valid;
    req_type_t          arb_req_type;
    lu_request_t        arb_lu_req;
    ats_completion_t    arb_ins_req;
    ats_inv_req_t       arb_inv_req;
    logic [FUNC_ID_WIDTH-1:0] arb_flr_func_id;
    logic               arb_lu_grant, arb_rl_grant, arb_ins_grant, arb_inv_grant;
    logic [65:0]        arb_ats_toggle_grant;
    logic               arb_flr_grant;
    logic               lu_req_ready, rl_req_ready, ins_req_ready, inv_req_ready;

    // Lookup Engine
    lu_response_t       lu_engine_rsp;
    logic               lu_engine_rsp_valid;
    // Relook mux: route lookup or relook request to lookup engine
    logic               lu_engine_req_valid;
    lu_request_t        lu_engine_req;
    assign lu_engine_req_valid = arb_lu_grant || arb_rl_grant;
    assign lu_engine_req       = arb_rl_grant ? dma_rl_req : arb_lu_req;

    // Track request type through 3-stage pipeline: 1=lookup, 0=relook
    logic [2:0] rsp_is_lookup;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rsp_is_lookup <= '0;
        else
            rsp_is_lookup <= {rsp_is_lookup[1:0], arb_lu_grant};
    end
    logic [SET_IDX_W-1:0] lu_ea_set_idx;
    logic                 lu_ea_set_en;
    logic                 lu_ea_cmp_en;
    logic [PV_WIDTH-1:0]  lu_ea_cmp_pv;
    logic [PASID_WIDTH-1:0] lu_ea_cmp_pasid;
    logic [FUNC_ID_WIDTH-1:0] lu_ea_cmp_func_id;
    logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0]  lu_ea_cmp_addr;

    // DupCheck
    dupcheck_payload_t  dc_payload_w;  // intermediate wire for port connection
    logic               dc_rsp_valid, dc_duplicate;
    logic [ENTRY_IDX_W-1:0] dc_dup_entry_idx;

    // Invalidation Handler
    logic               invh_inv_ack, invh_flr_done, invh_busy;
    logic               invh_ea_batch_clr_en;
    logic [FUNC_ID_WIDTH-1:0] invh_ea_batch_clr_func_id;
    logic               invh_ea_batch_clr_all;
    logic               invh_ea_inv_en;
    logic [SET_IDX_W-1:0] invh_ea_inv_set_idx;
    logic [WAY_IDX_W-1:0] invh_ea_inv_way_idx;
    logic               invh_ea_cmp_inv_mode;
    logic               invh_ea_cmp_en;
    logic [SET_IDX_W-1:0] invh_ea_cmp_set_idx;
    logic [PV_WIDTH-1:0]  invh_ea_cmp_pv;
    logic [PASID_WIDTH-1:0] invh_ea_cmp_pasid;
    logic [FUNC_ID_WIDTH-1:0] invh_ea_cmp_func_id;
    logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0]  invh_ea_cmp_addr;

    // NRU decay
    logic [$clog2(NRU_DECAY_INTERVAL)-1:0] nru_decay_counter;

    // Insert path
    logic               insert_pending;
    ats_completion_t    insert_pending_data;
    logic [SET_IDX_W-1:0] insert_set_idx;
    logic [WAY_IDX_W-1:0] insert_way_idx;
    logic               do_insert_write;

    // Hash for insert set
    // Partition-aware hash for insert set
    logic [SET_IDX_W-1:0] ins_set_idx;
    assign ins_set_idx = partition_hash(ea_cfg_num_users,
        int'(arb_ins_req.func_id[5:0]),
        arb_ins_req.func_id,
        arb_ins_req.untranslated_addr);

    //=========================================================================
    // Arbiter
    //=========================================================================
    atc_req_arbiter u_arbiter (
        .clk                (clk),
        .rst_n              (rst_n),
        .lu_req_valid       (dma_lu_req_valid),
        .lu_req             (dma_lu_req),
        .lu_req_grant       (arb_lu_grant),
        .rl_req_valid       (dma_rl_req_valid),
        .rl_req             (dma_rl_req),
        .rl_req_grant       (arb_rl_grant),
        .ins_req_valid      (ats_comp_valid),
        .ins_req            (ats_comp),
        .ins_req_grant      (arb_ins_grant),
        .inv_req_valid      (ats_inv_req_valid),
        .inv_req            (ats_inv_req),
        .inv_req_grant      (arb_inv_grant),
        .ats_toggle_req     (ats_enable_toggle),
        .ats_toggle_grant   (arb_ats_toggle_grant),
        .flr_req            (flr_req),
        .flr_func_id        (flr_func_id),
        .flr_grant          (arb_flr_grant),
        .req_out_valid      (arb_req_valid),
        .req_out_type       (arb_req_type),
        .req_out_lu         (arb_lu_req),
        .req_out_ins        (arb_ins_req),
        .req_out_inv        (arb_inv_req),
        .req_out_flr_func_id(arb_flr_func_id),
        .lu_req_ready       (lu_req_ready),
        .rl_req_ready       (rl_req_ready),
        .ins_req_ready      (ins_req_ready),
        .inv_req_ready      (inv_req_ready),
        .downstream_busy    (invh_busy)
    );

    //=========================================================================
    // Lookup Engine
    //=========================================================================
    atc_lookup_engine u_lookup (
        .clk                (clk),
        .rst_n              (rst_n),
        .lu_req_valid       (lu_engine_req_valid),
        .lu_req             (lu_engine_req),
        .lu_req_ready       (),
        .lu_rsp_valid       (lu_engine_rsp_valid),
        .lu_rsp             (lu_engine_rsp),
        .ea_set_idx         (lu_ea_set_idx),
        .ea_set_en          (lu_ea_set_en),
        .ea_cmp_en          (lu_ea_cmp_en),
        .ea_cmp_pv          (lu_ea_cmp_pv),
        .ea_cmp_pasid       (lu_ea_cmp_pasid),
        .ea_cmp_func_id     (lu_ea_cmp_func_id),
        .ea_cmp_addr        (lu_ea_cmp_addr),
        .ea_hit_vectors     (ea_hit_vectors),
        .ea_hit_way_idx     (ea_hit_way_idx),
        .ea_any_hit         (ea_any_hit),
        .ea_hit_pv          (ea_hit_pv),
        .sram_rd_pa         (ea_sram_rd_pa),
        .sram_rd_perm       (ea_sram_rd_perm),
        .nru_update_en      (ea_nru_update_en),
        .nru_update_way     (ea_nru_update_way),
        .nru_update_val     (ea_nru_update_val),
        .cfg_num_users      (ea_cfg_num_users)
    );

    //=========================================================================
    // Duplicate Check
    //=========================================================================
    // Map ats_completion_t to dupcheck_payload_t (field-by-field for DC compat)
    assign dc_payload_w.pv      = arb_ins_req.pv;
    assign dc_payload_w.pasid   = arb_ins_req.pasid;
    assign dc_payload_w.func_id = arb_ins_req.func_id;
    assign dc_payload_w.untranslated_addr = arb_ins_req.untranslated_addr;
    assign dc_payload_w.stu     = arb_ins_req.stu;

    atc_dupcheck u_dupcheck (
        .clk                (clk),
        .rst_n              (rst_n),
        .dup_req_valid      (arb_ins_grant),
        .dup_req            (dc_payload_w),
        .dup_req_ready      (ats_comp_ready),
        .dup_rsp_valid      (dc_rsp_valid),
        .duplicate          (dc_duplicate),
        .dup_entry_idx      (dc_dup_entry_idx),
        .ea_subset_id       (ea_dupcheck_subset_id),
        .ea_valids          (ea_dupcheck_valids),
        .ea_pvs             (ea_dupcheck_pvs),
        .ea_pasids          (ea_dupcheck_pasids),
        .ea_funcids         (ea_dupcheck_funcids),
        .ea_vas             (ea_dupcheck_vas),
        .ea_stus            (ea_dupcheck_stus)
    );

    //=========================================================================
    // Invalidation Handler
    //=========================================================================
    atc_inv_handler u_inv_handler (
        .clk                (clk),
        .rst_n              (rst_n),
        .inv_req_valid      (arb_inv_grant),
        .inv_req            (arb_inv_req),
        .inv_req_ready      (),
        .inv_ack_valid      (invh_inv_ack),
        .ats_toggle_req     (arb_ats_toggle_grant),
        .flr_req            (arb_flr_grant),
        .flr_func_id        (arb_flr_func_id),
        .flr_done           (invh_flr_done),
        .ea_batch_clr_en    (invh_ea_batch_clr_en),
        .ea_batch_clr_func_id(invh_ea_batch_clr_func_id),
        .ea_batch_clr_all   (invh_ea_batch_clr_all),
        .ea_inv_en          (invh_ea_inv_en),
        .ea_inv_set_idx     (invh_ea_inv_set_idx),
        .ea_inv_way_idx     (invh_ea_inv_way_idx),
        .ea_cmp_inv_mode    (invh_ea_cmp_inv_mode),
        .ea_cmp_en          (invh_ea_cmp_en),
        .ea_cmp_set_idx     (invh_ea_cmp_set_idx),
        .ea_cmp_pv          (invh_ea_cmp_pv),
        .ea_cmp_pasid       (invh_ea_cmp_pasid),
        .ea_cmp_func_id     (invh_ea_cmp_func_id),
        .ea_cmp_addr        (invh_ea_cmp_addr),
        .ea_hit_vectors     (ea_hit_vectors),
        .ea_hit_way_idx     (ea_hit_way_idx),
        .ea_any_hit         (ea_any_hit),
        .inv_busy           (invh_busy),
        .cfg_num_users      (ea_cfg_num_users)
    );

    //=========================================================================
    // Entry Array Access Mux: Invalidation > Insert > Lookup
    //=========================================================================
    always_comb begin
        if (invh_busy) begin
            ea_set_idx      = invh_ea_cmp_set_idx;
            ea_set_en       = 1'b1;
            ea_cmp_inv_mode = invh_ea_cmp_inv_mode;
            ea_cmp_en       = invh_ea_cmp_en;
            ea_cmp_pv       = invh_ea_cmp_pv;
            ea_cmp_pasid    = invh_ea_cmp_pasid;
            ea_cmp_func_id  = invh_ea_cmp_func_id;
            ea_cmp_addr     = invh_ea_cmp_addr;
        end else if (do_insert_write) begin
            ea_set_idx      = insert_set_idx;
            ea_set_en       = 1'b1;
            ea_cmp_inv_mode = 1'b0;
            ea_cmp_en       = 1'b0;
            ea_cmp_pv       = '0;
            ea_cmp_pasid    = '0;
            ea_cmp_func_id  = '0;
            ea_cmp_addr     = lu_ea_cmp_addr;
        end else begin
            ea_set_idx      = lu_ea_set_idx;
            ea_set_en       = lu_ea_set_en;
            ea_cmp_inv_mode = 1'b0;
            ea_cmp_en       = lu_ea_cmp_en;
            ea_cmp_pv       = lu_ea_cmp_pv;
            ea_cmp_pasid    = lu_ea_cmp_pasid;
            ea_cmp_func_id  = lu_ea_cmp_func_id;
            ea_cmp_addr     = lu_ea_cmp_addr;
        end
    end

    //=========================================================================
    // Insert Path: dupcheck → allocate way → write TAG + SRAM
    //=========================================================================
    assign do_insert_write = dc_rsp_valid && insert_pending;

    // TAG write port
    assign ea_wr_en       = do_insert_write;
    assign ea_wr_set_idx  = insert_set_idx;
    assign ea_wr_way_idx  = dc_duplicate ? dc_dup_entry_idx[WAY_IDX_W-1:0] : ea_victim_way;
    assign ea_wr_valid    = 1'b1;
    assign ea_wr_pv       = insert_pending_data.pv;
    assign ea_wr_pasid    = insert_pending_data.pasid;
    assign ea_wr_func_id  = insert_pending_data.func_id;
    assign ea_wr_va       = insert_pending_data.untranslated_addr;
    assign ea_wr_stu      = insert_pending_data.stu;

    // SRAM data write port (same address as TAG)
    assign sram_wr_en     = do_insert_write;
    assign sram_wr_addr   = {ea_wr_set_idx, ea_wr_way_idx};
    assign sram_wr_pa     = insert_pending_data.translated_addr;
    assign sram_wr_perm   = insert_pending_data.perm;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            insert_pending      <= 1'b0;
            insert_pending_data <= '{
                pv: '0, pasid: '0, func_id: '0,
                untranslated_addr: '0, translated_addr: '0,
                stu: '0, perm: '0
            };
            insert_set_idx  <= '0;
            insert_way_idx  <= '0;
        end else begin
            if (arb_ins_grant) begin
                insert_pending      <= 1'b1;
                insert_pending_data <= arb_ins_req;
                insert_set_idx      <= ins_set_idx;
            end

            if (dc_rsp_valid && insert_pending) begin
                if (dc_duplicate) begin
                    insert_way_idx <= dc_dup_entry_idx[WAY_IDX_W-1:0];
                    insert_set_idx <= dc_dup_entry_idx[ENTRY_IDX_W-1:WAY_IDX_W];
                end
            end

            if (ea_wr_en) begin
                insert_pending <= 1'b0;
            end
        end
    end

    //=========================================================================
    // Invalidation control
    //=========================================================================
    assign ea_batch_clr_en      = invh_ea_batch_clr_en;
    assign ea_batch_clr_func_id = invh_ea_batch_clr_func_id;
    assign ea_batch_clr_all     = invh_ea_batch_clr_all;
    assign ea_inv_en            = invh_ea_inv_en;
    assign ea_inv_set_idx       = invh_ea_inv_set_idx;
    assign ea_inv_way_idx       = invh_ea_inv_way_idx;

    //=========================================================================
    // NRU
    //=========================================================================
    // NRU way partition: restrict victim search for >32 user modes
    assign ea_nru_way_base  = get_user_way_base(ea_cfg_num_users,
        int'(arb_ins_req.func_id[5:0]));
    assign ea_nru_way_limit = get_user_way_limit(ea_cfg_num_users,
        int'(arb_ins_req.func_id[5:0]));

    assign ea_nru_clear_all_used = 1'b0;  // decay timer handles periodic reset

    //=========================================================================
    // NRU Decay Timer
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nru_decay_counter <= '0;
            ea_nru_decay_tick <= 1'b0;
        end else begin
            if (nru_decay_counter == NRU_DECAY_INTERVAL - 1) begin
                nru_decay_counter <= '0;
                ea_nru_decay_tick <= 1'b1;
            end else begin
                nru_decay_counter <= nru_decay_counter + 1'b1;
                ea_nru_decay_tick <= 1'b0;
            end
        end
    end

    //=========================================================================
    // Response Output
    //=========================================================================
    // Response with per-function ATS enable gating
    assign dma_lu_rsp_valid  = lu_engine_rsp_valid && rsp_is_lookup[2];
    always_comb begin
        dma_lu_rsp = lu_engine_rsp;
        // Per-function ATS enable: force miss if this function's ATS is disabled
        if (!ats_enable[arb_lu_req.func_id[5:0]]) begin
            dma_lu_rsp.hit     = 1'b0;
            dma_lu_rsp.pre_hit = 1'b0;
        end
    end

    // Relook response: hit only, no pre_hit
    assign dma_rl_rsp_valid  = lu_engine_rsp_valid && !rsp_is_lookup[2];
    assign dma_rl_rsp.valid  = lu_engine_rsp.valid;
    assign dma_rl_rsp.hit    = lu_engine_rsp.hit;
    assign dma_rl_rsp.pre_hit = 1'b0;  // relook: no prefetch
    assign dma_rl_rsp.translated_addr = lu_engine_rsp.translated_addr;
    assign dma_rl_rsp.perm   = lu_engine_rsp.perm;
    assign dma_rl_rsp.hit_pv = lu_engine_rsp.hit_pv;

    // Flow-control ready pass-through from arbiter
    assign dma_lu_req_ready  = lu_req_ready;
    assign dma_rl_req_ready  = rl_req_ready;
    assign ats_inv_req_ready = inv_req_ready;

    // FLR done from invalidation handler
    assign flr_done = invh_flr_done;

    // Prefetch response valid (from lookup engine: hit_vectors[1:16] have results)
    assign prefetch_rsp_valid = {16{lu_engine_rsp_valid}};  // all prefetch results valid together

    assign ats_inv_ack_valid = invh_inv_ack;

endmodule : atc_ctrl
