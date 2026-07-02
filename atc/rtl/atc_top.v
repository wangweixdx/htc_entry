//=============================================================================
// atc_top.v — ATC Top-Level Module with TAG/SRAM split storage (Verilog-2001)
//
// TAG storage:  2048 × 107b register-based (inside atc_entry_array)
// DATA storage: 2048 ×  68b SRAM (inside atc_entry_array → atc_data_sram)
// NRU storage:  2048 ×   2b register-based (inside atc_nru_replacer)
//=============================================================================
`include "atc_defines.vh"

module atc_top (
    input                           clk,
    input                           rst_n,

    //=========================================================================
    // DMA Engine Interface (Lookup)
    //=========================================================================
    input                           dma_lu_req_valid,
    input                           dma_lu_req_pv,
    input  [19:0]                   dma_lu_req_pasid,
    input  [15:0]                   dma_lu_req_func_id,
    input  [63:0]                   dma_lu_req_addr,

    output                          dma_lu_req_ready,
    output                          dma_lu_rsp_valid,
    output                          dma_lu_rsp_hit,
    output [63:0]                   dma_lu_rsp_translated_addr,
    output [3:0]                    dma_lu_rsp_perm,

    //=========================================================================
    // DMA Relook Interface (second lookup, no prefetch)
    //=========================================================================
    input                           dma_rl_req_valid,
    input                           dma_rl_req_pv,
    input  [19:0]                   dma_rl_req_pasid,
    input  [15:0]                   dma_rl_req_func_id,
    input  [63:0]                   dma_rl_req_addr,

    output                          dma_rl_req_ready,
    output                          dma_rl_rsp_valid,
    output                          dma_rl_rsp_hit,
    output [63:0]                   dma_rl_rsp_translated_addr,
    output [3:0]                    dma_rl_rsp_perm,

    //=========================================================================
    // ATS Translation Completion Interface (from RC → Insert)
    //=========================================================================
    input                           ats_comp_valid,
    input                           ats_comp_pv,
    input  [19:0]                   ats_comp_pasid,
    input  [15:0]                   ats_comp_func_id,
    input  [63:0]                   ats_comp_untranslated_addr,
    input  [63:0]                   ats_comp_translated_addr,
    input  [4:0]                    ats_comp_stu,
    input  [3:0]                    ats_comp_perm,

    //=========================================================================
    // ATS Invalidation Request Interface (from RC → Invalidate)
    //=========================================================================
    input                           ats_inv_req_valid,
    input  [15:0]                   ats_inv_mask,
    input                           ats_inv_pv_valid,
    input                           ats_inv_pv,
    input  [19:0]                   ats_inv_pasid,
    input  [15:0]                   ats_inv_func_id,
    input  [63:0]                   ats_inv_untranslated_addr,

    output                          ats_inv_req_ready,
    output                          ats_inv_ack_valid,
    output                          ats_comp_ready,
    output                          ats_comp_update_done,

    //=========================================================================
    // CSR / Configuration Interface
    //=========================================================================
    input  [65:0]                   csr_ats_enable,
    input                           csr_flr_req,
    input  [15:0]                   csr_flr_func_id,
    input  [2:0]                    csr_num_users,
    input  [65:0]                   csr_prefetch_enable,
    output                          csr_flr_req_done,

    //=========================================================================
    // Prefetch Outputs
    //=========================================================================
    output [15:0]                   prefetch_rsp_valid,
    output [15:0]                   prefetch_hit,
    output [15:0][63:0]             prefetch_pa,
    output [15:0][3:0]              prefetch_perm,

    //=========================================================================
    // Status Outputs
    //=========================================================================
    output                          atc_active,
    output [10:0]                   atc_entry_count
);

    //=========================================================================
    // CSR Interface (edge detect + sync)
    //=========================================================================
    wire [65:0] ats_enable_sync;
    wire [65:0] ats_enable_toggle;
    wire flr_req_sync;
    wire [15:0] flr_func_id_sync;
    wire [2:0]  cfg_num_users;
    wire [6:0]  ea_nru_way_base;
    wire [6:0]  ea_nru_way_limit;

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
    // Internal wires: atc_ctrl ↔ atc_entry_array
    //=========================================================================

    // ---- TAG Compare ----
    wire [4:0]                      ea_set_idx;
    wire                            ea_set_en;
    wire                            ea_cmp_en;
    wire                            ea_cmp_inv_mode;
    wire                            ea_cmp_pv;
    wire [19:0]                     ea_cmp_pasid;
    wire [15:0]                     ea_cmp_func_id;
    wire [16:0][63:0]               ea_cmp_addr;

    wire [16:0][63:0]               ea_hit_vectors;
    wire [5:0]                      ea_hit_way_idx;
    wire                            ea_any_hit;
    wire                            ea_hit_pv;

    // ---- SRAM Read Data ----
    wire [63:0]                     ea_sram_rd_pa;
    wire [3:0]                      ea_sram_rd_perm;

    // ---- TAG Write ----
    wire                            ea_wr_en;
    wire [4:0]                      ea_wr_set_idx;
    wire [5:0]                      ea_wr_way_idx;
    wire                            ea_wr_valid;
    wire                            ea_wr_pv;
    wire [19:0]                     ea_wr_pasid;
    wire [15:0]                     ea_wr_func_id;
    wire [63:0]                     ea_wr_va;
    wire [4:0]                      ea_wr_stu;

    // ---- SRAM Write ----
    wire                            sram_wr_en;
    wire [10:0]                     sram_wr_addr;
    wire [63:0]                     sram_wr_pa;
    wire [3:0]                      sram_wr_perm;

    // ---- NRU ----
    wire [5:0]                      ea_victim_way;
    wire                            ea_victim_valid;
    wire                            ea_nru_update_en;
    wire [5:0]                      ea_nru_update_way;
    wire [1:0]                      ea_nru_update_val;
    wire                            ea_nru_clear_all_used;
    wire                            ea_nru_decay_tick;

    // ---- Invalidation ----
    wire                            ea_inv_en;
    wire [4:0]                      ea_inv_set_idx;
    wire [5:0]                      ea_inv_way_idx;
    wire                            ea_batch_clr_en;
    wire [15:0]                     ea_batch_clr_func_id;
    wire                            ea_batch_clr_all;

    // ---- DupCheck ----
    wire [2:0]                      ea_dc_subset_id;
    wire [7:0][63:0]                ea_dc_valids;
    wire [7:0][63:0]                ea_dc_pvs;
    wire [7:0][63:0][19:0]          ea_dc_pasids;
    wire [7:0][63:0][15:0]          ea_dc_funcids;
    wire [7:0][63:0][63:0]          ea_dc_vas;
    wire [7:0][63:0][4:0]           ea_dc_stus;

    // ---- Intermediate signals for ctrl → top output ----
    wire                            dma_lu_rsp_pre_hit;
    wire                            dma_lu_rsp_hit_pv;
    wire                            dma_rl_rsp_hit;
    wire [63:0]                     dma_rl_rsp_pa;
    wire [3:0]                      dma_rl_rsp_perm;

    //=========================================================================
    // ATC Controller
    //=========================================================================
    atc_ctrl u_ctrl (
        .clk                (clk),
        .rst_n              (rst_n),
        .dma_lu_req_valid   (dma_lu_req_valid),
        .dma_lu_req_pv      (dma_lu_req_pv),
        .dma_lu_req_pasid   (dma_lu_req_pasid),
        .dma_lu_req_func_id (dma_lu_req_func_id),
        .dma_lu_req_va      (dma_lu_req_addr),
        .dma_lu_req_ready   (dma_lu_req_ready),
        .dma_lu_rsp_valid   (dma_lu_rsp_valid),
        .dma_lu_rsp_hit     (dma_lu_rsp_hit),
        .dma_lu_rsp_translated_addr (dma_lu_rsp_translated_addr),
        .dma_lu_rsp_perm    (dma_lu_rsp_perm),
        .dma_lu_rsp_pre_hit (dma_lu_rsp_pre_hit),
        .dma_lu_rsp_hit_pv  (dma_lu_rsp_hit_pv),
        .dma_rl_req_valid   (dma_rl_req_valid),
        .dma_rl_req_pv      (dma_rl_req_pv),
        .dma_rl_req_pasid   (dma_rl_req_pasid),
        .dma_rl_req_func_id (dma_rl_req_func_id),
        .dma_rl_req_va      (dma_rl_req_addr),
        .dma_rl_req_ready   (dma_rl_req_ready),
        .dma_rl_rsp_valid   (dma_rl_rsp_valid),
        .dma_rl_rsp_hit     (dma_rl_rsp_hit),
        .dma_rl_rsp_translated_addr (dma_rl_rsp_translated_addr),
        .dma_rl_rsp_perm    (dma_rl_rsp_perm),
        .ats_inv_req_valid  (ats_inv_req_valid),
        .ats_inv_req_mask   (ats_inv_mask),
        .ats_inv_req_pv_valid(ats_inv_pv_valid),
        .ats_inv_req_pv     (ats_inv_pv),
        .ats_inv_req_pasid  (ats_inv_pasid),
        .ats_inv_req_func_id(ats_inv_func_id),
        .ats_inv_req_va     (ats_inv_untranslated_addr),
        .ats_inv_req_ready  (ats_inv_req_ready),
        .ats_inv_ack_valid  (ats_inv_ack_valid),
        .ats_comp_valid     (ats_comp_valid),
        .ats_comp_pv        (ats_comp_pv),
        .ats_comp_pasid     (ats_comp_pasid),
        .ats_comp_func_id   (ats_comp_func_id),
        .ats_comp_va        (ats_comp_untranslated_addr),
        .ats_comp_pa        (ats_comp_translated_addr),
        .ats_comp_stu       (ats_comp_stu),
        .ats_comp_perm      (ats_comp_perm),
        .ats_comp_ready     (ats_comp_ready),
        .ats_comp_update_done(ats_comp_update_done),
        .flr_done           (csr_flr_req_done),
        .prefetch_rsp_valid (prefetch_rsp_valid),
        .prefetch_hit       (prefetch_hit),
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
        .ea_hit_way_idx      (ea_hit_way_idx),
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

        // NRU Decay / Partition
        .ea_nru_decay_tick  (ea_nru_decay_tick),
        .ea_nru_way_base    (ea_nru_way_base),
        .ea_nru_way_limit   (ea_nru_way_limit),
        .ea_cfg_num_users   (cfg_num_users),
        .prefetch_enable    (csr_prefetch_enable)
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
    // Prefetch outputs (from lookup engine via atc_ctrl)
    //=========================================================================
    assign prefetch_pa   = {16{64'd0}};
    assign prefetch_perm = {16{4'd0}};

    //=========================================================================
    // Status Outputs
    //=========================================================================
    assign atc_active = dma_lu_req_valid || ats_comp_valid
                        || ats_inv_req_valid || flr_req_sync;

    wire [5:0] valid_count;
    integer cnt_w;
    assign valid_count = 6'd0;  // approximate
    assign atc_entry_count = {5'd0, valid_count};

endmodule
