//=============================================================================
// atc_ctrl.v — ATC Controller with TAG/SRAM split storage (Verilog-2001)
//
// Coordinates: arbiter, lookup engine, dupcheck, invalidation handler,
//              NRU replacer, TAG write, and SRAM data write.
//=============================================================================
`include "atc_defines.vh"

module atc_ctrl (
    input                           clk,
    input                           rst_n,

    //=========================================================================
    // External Request Interfaces
    //=========================================================================

    // ---- DMA Lookup ----
    input                           dma_lu_req_valid,
    input                           dma_lu_req_pv,
    input  [19:0]                   dma_lu_req_pasid,
    input  [15:0]                   dma_lu_req_func_id,
    input  [63:0]                   dma_lu_req_va,
    output                          dma_lu_req_ready,
    output                          dma_lu_rsp_valid,
    output                          dma_lu_rsp_hit,
    output [63:0]                   dma_lu_rsp_translated_addr,
    output [3:0]                    dma_lu_rsp_perm,
    output                          dma_lu_rsp_pre_hit,
    output                          dma_lu_rsp_hit_pv,

    // ---- DMA Relook ----
    input                           dma_rl_req_valid,
    input                           dma_rl_req_pv,
    input  [19:0]                   dma_rl_req_pasid,
    input  [15:0]                   dma_rl_req_func_id,
    input  [63:0]                   dma_rl_req_va,
    output                          dma_rl_req_ready,
    output                          dma_rl_rsp_valid,
    output                          dma_rl_rsp_hit,
    output [63:0]                   dma_rl_rsp_translated_addr,
    output [3:0]                    dma_rl_rsp_perm,

    // ---- ATS Completion (Insert) ----
    input                           ats_comp_valid,
    input                           ats_comp_pv,
    input  [19:0]                   ats_comp_pasid,
    input  [15:0]                   ats_comp_func_id,
    input  [63:0]                   ats_comp_va,
    input  [63:0]                   ats_comp_pa,
    input  [4:0]                    ats_comp_stu,
    input  [3:0]                    ats_comp_perm,
    output                          ats_comp_ready,

    // ---- ATS Invalidation ----
    input                           ats_inv_req_valid,
    input  [15:0]                   ats_inv_req_mask,
    input                           ats_inv_req_pv_valid,
    input                           ats_inv_req_pv,
    input  [19:0]                   ats_inv_req_pasid,
    input  [15:0]                   ats_inv_req_func_id,
    input  [63:0]                   ats_inv_req_va,
    output                          ats_inv_req_ready,
    output                          ats_inv_ack_valid,

    // ---- FLR Done ----
    output                          flr_done,

    // ---- Prefetch Response Valid ----
    output [15:0]                   prefetch_rsp_valid,

    // ---- CSR / Config Signals ----
    input  [65:0]                   ats_enable,
    input  [65:0]                   ats_enable_toggle,
    input                           flr_req,
    input  [15:0]                   flr_func_id,

    //=========================================================================
    // Entry Array: TAG Compare Interface
    //=========================================================================
    output reg [4:0]                ea_set_idx,
    output reg                      ea_set_en,
    output reg                      ea_cmp_en,
    output reg                      ea_cmp_inv_mode,
    output reg                      ea_cmp_pv,
    output reg [19:0]               ea_cmp_pasid,
    output reg [15:0]               ea_cmp_func_id,
    output reg [16:0][63:0]         ea_cmp_addr,

    input  [16:0][63:0]             ea_hit_vectors,
    input  [5:0]                    ea_hit_way_idx,
    input                           ea_any_hit,
    input                           ea_hit_pv,

    input  [63:0]                   ea_sram_rd_pa,
    input  [3:0]                    ea_sram_rd_perm,

    //=========================================================================
    // Entry Array: TAG Write Port
    //=========================================================================
    output                          ea_wr_en,
    output [4:0]                    ea_wr_set_idx,
    output [5:0]                    ea_wr_way_idx,
    output                          ea_wr_valid,
    output                          ea_wr_pv,
    output [19:0]                   ea_wr_pasid,
    output [15:0]                   ea_wr_func_id,
    output [63:0]                   ea_wr_va,
    output [4:0]                    ea_wr_stu,

    //=========================================================================
    // SRAM: Data Write Port
    //=========================================================================
    output                          sram_wr_en,
    output [10:0]                   sram_wr_addr,
    output [63:0]                   sram_wr_pa,
    output [3:0]                    sram_wr_perm,

    //=========================================================================
    // NRU Control
    //=========================================================================
    input  [5:0]                    ea_victim_way,
    input                           ea_victim_valid,
    output                          ea_nru_update_en,
    output [5:0]                    ea_nru_update_way,
    output [1:0]                    ea_nru_update_val,
    output                          ea_nru_clear_all_used,

    //=========================================================================
    // Invalidation
    //=========================================================================
    output                          ea_inv_en,
    output [4:0]                    ea_inv_set_idx,
    output [5:0]                    ea_inv_way_idx,

    output                          ea_batch_clr_en,
    output [15:0]                   ea_batch_clr_func_id,
    output                          ea_batch_clr_all,

    //=========================================================================
    // DupCheck
    //=========================================================================
    output [2:0]                    ea_dupcheck_subset_id,
    input  [7:0][63:0]              ea_dupcheck_valids,
    input  [7:0][63:0]              ea_dupcheck_pvs,
    input  [7:0][63:0][19:0]        ea_dupcheck_pasids,
    input  [7:0][63:0][15:0]        ea_dupcheck_funcids,
    input  [7:0][63:0][63:0]        ea_dupcheck_vas,
    input  [7:0][63:0][4:0]         ea_dupcheck_stus,

    //=========================================================================
    // NRU Decay
    //=========================================================================
    output reg                      ea_nru_decay_tick,

    //=========================================================================
    // Partition Config
    //=========================================================================
    output [6:0]                    ea_nru_way_base,
    output [6:0]                    ea_nru_way_limit,

    input  [2:0]                    ea_cfg_num_users
);

    //=========================================================================
    // Internal Signals — Arbiter
    //=========================================================================
    wire               arb_req_valid;
    wire [2:0]         arb_req_type;
    wire               arb_lu_pv, arb_ins_pv, arb_inv_pv, arb_inv_pv_valid;
    wire [19:0]        arb_lu_pasid, arb_ins_pasid, arb_inv_pasid;
    wire [15:0]        arb_lu_func_id, arb_ins_func_id, arb_inv_func_id;
    wire [63:0]        arb_lu_va, arb_ins_va, arb_inv_va;
    wire [63:0]        arb_ins_pa;
    wire [4:0]         arb_ins_stu;
    wire [3:0]         arb_ins_perm;
    wire [15:0]        arb_inv_mask;
    wire [15:0]        arb_flr_func_id;
    wire               arb_lu_grant, arb_rl_grant, arb_ins_grant, arb_inv_grant;
    wire [65:0]        arb_ats_toggle_grant;
    wire               arb_flr_grant;
    wire               lu_req_ready, rl_req_ready, ins_req_ready, inv_req_ready;

    //=========================================================================
    // Arbiter
    //=========================================================================
    atc_req_arbiter u_arbiter (
        .clk                (clk),
        .rst_n              (rst_n),
        .lu_req_valid       (dma_lu_req_valid),
        .lu_req_pv          (dma_lu_req_pv),
        .lu_req_pasid       (dma_lu_req_pasid),
        .lu_req_func_id     (dma_lu_req_func_id),
        .lu_req_va          (dma_lu_req_va),
        .lu_req_grant       (arb_lu_grant),
        .rl_req_valid       (dma_rl_req_valid),
        .rl_req_pv          (dma_rl_req_pv),
        .rl_req_pasid       (dma_rl_req_pasid),
        .rl_req_func_id     (dma_rl_req_func_id),
        .rl_req_va          (dma_rl_req_va),
        .rl_req_grant       (arb_rl_grant),
        .ins_req_valid      (ats_comp_valid),
        .ins_req_pv         (ats_comp_pv),
        .ins_req_pasid      (ats_comp_pasid),
        .ins_req_func_id    (ats_comp_func_id),
        .ins_req_va         (ats_comp_va),
        .ins_req_pa         (ats_comp_pa),
        .ins_req_stu        (ats_comp_stu),
        .ins_req_perm       (ats_comp_perm),
        .ins_req_grant      (arb_ins_grant),
        .inv_req_valid      (ats_inv_req_valid),
        .inv_req_mask       (ats_inv_req_mask),
        .inv_req_pv_valid   (ats_inv_req_pv_valid),
        .inv_req_pv         (ats_inv_req_pv),
        .inv_req_pasid      (ats_inv_req_pasid),
        .inv_req_func_id    (ats_inv_req_func_id),
        .inv_req_va         (ats_inv_req_va),
        .inv_req_grant      (arb_inv_grant),
        .ats_toggle_req     (ats_enable_toggle),
        .ats_toggle_grant   (arb_ats_toggle_grant),
        .flr_req            (flr_req),
        .flr_func_id        (flr_func_id),
        .flr_grant          (arb_flr_grant),
        .req_out_valid      (arb_req_valid),
        .req_out_type       (arb_req_type),
        .req_out_lu_pv      (arb_lu_pv),
        .req_out_lu_pasid   (arb_lu_pasid),
        .req_out_lu_func_id (arb_lu_func_id),
        .req_out_lu_va      (arb_lu_va),
        .req_out_ins_pv     (arb_ins_pv),
        .req_out_ins_pasid  (arb_ins_pasid),
        .req_out_ins_func_id(arb_ins_func_id),
        .req_out_ins_va     (arb_ins_va),
        .req_out_ins_pa     (arb_ins_pa),
        .req_out_ins_stu    (arb_ins_stu),
        .req_out_ins_perm   (arb_ins_perm),
        .req_out_inv_mask   (arb_inv_mask),
        .req_out_inv_pv_valid(arb_inv_pv_valid),
        .req_out_inv_pv     (arb_inv_pv),
        .req_out_inv_pasid  (arb_inv_pasid),
        .req_out_inv_func_id(arb_inv_func_id),
        .req_out_inv_va     (arb_inv_va),
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
    wire               lu_engine_req_valid;
    wire               lu_engine_req_pv, lu_engine_req_pasid, lu_engine_req_func_id;
    wire [19:0]        lu_engine_pasid_sig;
    wire [15:0]        lu_engine_func_id_sig;
    wire [63:0]        lu_engine_va_sig;
    wire               lu_engine_rsp_valid;
    wire               lu_engine_rsp_hit;
    wire [63:0]        lu_engine_rsp_pa;
    wire [3:0]         lu_engine_rsp_perm;
    wire               lu_engine_rsp_hit_pv;
    wire               lu_engine_rsp_pre_hit;
    wire [4:0]         lu_ea_set_idx;
    wire               lu_ea_set_en;
    wire               lu_ea_cmp_en;
    wire               lu_ea_cmp_pv;
    wire [19:0]        lu_ea_cmp_pasid;
    wire [15:0]        lu_ea_cmp_func_id;
    wire [16:0][63:0]  lu_ea_cmp_addr;

    // Relook mux: route lookup or relook request to lookup engine
    assign lu_engine_req_valid = arb_lu_grant || arb_rl_grant;
    assign lu_engine_req_pv       = arb_rl_grant ? dma_rl_req_pv       : arb_lu_pv;
    assign lu_engine_pasid_sig    = arb_rl_grant ? dma_rl_req_pasid    : arb_lu_pasid;
    assign lu_engine_func_id_sig  = arb_rl_grant ? dma_rl_req_func_id  : arb_lu_func_id;

    // Track request type through 3-stage pipeline: 1=lookup, 0=relook
    reg [2:0] rsp_is_lookup;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rsp_is_lookup <= 3'd0;
        else
            rsp_is_lookup <= {rsp_is_lookup[1:0], arb_lu_grant};
    end
    assign lu_engine_va_sig       = arb_rl_grant ? dma_rl_req_va       : arb_lu_va;

    atc_lookup_engine u_lookup (
        .clk                (clk),
        .rst_n              (rst_n),
        .lu_req_valid       (lu_engine_req_valid),
        .lu_req_pv          (lu_engine_req_pv),
        .lu_req_pasid       (lu_engine_pasid_sig),
        .lu_req_func_id     (lu_engine_func_id_sig),
        .lu_req_va          (lu_engine_va_sig),
        .lu_req_ready       (),
        .lu_rsp_valid       (lu_engine_rsp_valid),
        .lu_rsp_hit         (lu_engine_rsp_hit),
        .lu_rsp_translated_addr (lu_engine_rsp_pa),
        .lu_rsp_perm        (lu_engine_rsp_perm),
        .lu_rsp_hit_pv      (lu_engine_rsp_hit_pv),
        .lu_rsp_pre_hit     (lu_engine_rsp_pre_hit),
        .ea_set_idx         (lu_ea_set_idx),
        .ea_set_en          (lu_ea_set_en),
        .ea_cmp_en          (lu_ea_cmp_en),
        .ea_cmp_pv          (lu_ea_cmp_pv),
        .ea_cmp_pasid       (lu_ea_cmp_pasid),
        .ea_cmp_func_id     (lu_ea_cmp_func_id),
        .ea_cmp_addr        (lu_ea_cmp_addr),
        .ea_hit_vectors     (ea_hit_vectors),
        .ea_hit_way_idx      (ea_hit_way_idx),
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
    wire               dc_rsp_valid, dc_duplicate;
    wire [10:0]        dc_dup_entry_idx;

    atc_dupcheck u_dupcheck (
        .clk                (clk),
        .rst_n              (rst_n),
        .dup_req_valid      (arb_ins_grant),
        .dup_req_pv         (arb_ins_pv),
        .dup_req_pasid      (arb_ins_pasid),
        .dup_req_func_id    (arb_ins_func_id),
        .dup_req_va         (arb_ins_va),
        .dup_req_stu        (arb_ins_stu),
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
    wire               invh_inv_ack, invh_flr_done, invh_busy;
    wire               invh_ea_batch_clr_en;
    wire [15:0]        invh_ea_batch_clr_func_id;
    wire               invh_ea_batch_clr_all;
    wire               invh_ea_inv_en;
    wire [4:0]         invh_ea_inv_set_idx;
    wire [5:0]         invh_ea_inv_way_idx;
    wire               invh_ea_cmp_inv_mode;
    wire               invh_ea_cmp_en;
    wire [4:0]         invh_ea_cmp_set_idx;
    wire               invh_ea_cmp_pv;
    wire [19:0]        invh_ea_cmp_pasid;
    wire [15:0]        invh_ea_cmp_func_id;
    wire [16:0][63:0]  invh_ea_cmp_addr;

    atc_inv_handler u_inv_handler (
        .clk                (clk),
        .rst_n              (rst_n),
        .inv_req_valid      (arb_inv_grant),
        .inv_req_mask       (arb_inv_mask),
        .inv_req_pv_valid   (arb_inv_pv_valid),
        .inv_req_pv         (arb_inv_pv),
        .inv_req_pasid      (arb_inv_pasid),
        .inv_req_func_id    (arb_inv_func_id),
        .inv_req_va         (arb_inv_va),
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
        .ea_hit_way_idx      (ea_hit_way_idx),
        .ea_any_hit         (ea_any_hit),
        .inv_busy           (invh_busy),
        .cfg_num_users      (ea_cfg_num_users)
    );

    //=========================================================================
    // Entry Array Access Mux
    //=========================================================================
    wire               do_insert_write;
    reg [4:0]          insert_set_idx;
    reg [5:0]          insert_way_idx;

    always @(*) begin
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
            ea_cmp_pv       = 1'b0;
            ea_cmp_pasid    = 20'd0;
            ea_cmp_func_id  = 16'd0;
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
    reg               insert_pending;
    reg               insert_data_pv;
    reg [19:0]        insert_data_pasid;
    reg [15:0]        insert_data_func_id;
    reg [63:0]        insert_data_va;
    reg [63:0]        insert_data_pa;
    reg [4:0]         insert_data_stu;
    reg [3:0]         insert_data_perm;

    // Partition hash for insert set
    wire [4:0] ins_set_idx;
    assign ins_set_idx = partition_hash(ea_cfg_num_users,
        arb_ins_func_id[5:0], arb_ins_func_id, arb_ins_va);

    assign do_insert_write = dc_rsp_valid && insert_pending;

    // TAG write port
    assign ea_wr_en       = do_insert_write;
    assign ea_wr_set_idx  = insert_set_idx;
    assign ea_wr_way_idx  = dc_duplicate ? dc_dup_entry_idx[5:0] : ea_victim_way;
    assign ea_wr_valid    = 1'b1;
    assign ea_wr_pv       = insert_data_pv;
    assign ea_wr_pasid    = insert_data_pasid;
    assign ea_wr_func_id  = insert_data_func_id;
    assign ea_wr_va       = insert_data_va;
    assign ea_wr_stu      = insert_data_stu;

    // SRAM data write port
    assign sram_wr_en     = do_insert_write;
    assign sram_wr_addr   = {ea_wr_set_idx, ea_wr_way_idx};
    assign sram_wr_pa     = insert_data_pa;
    assign sram_wr_perm   = insert_data_perm;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            insert_pending      <= 1'b0;
            insert_data_pv      <= 1'b0;
            insert_data_pasid   <= 20'd0;
            insert_data_func_id <= 16'd0;
            insert_data_va      <= 64'd0;
            insert_data_pa      <= 64'd0;
            insert_data_stu     <= 5'd0;
            insert_data_perm    <= 4'd0;
            insert_set_idx      <= 5'd0;
            insert_way_idx      <= 6'd0;
        end else begin
            if (arb_ins_grant) begin
                insert_pending      <= 1'b1;
                insert_data_pv      <= arb_ins_pv;
                insert_data_pasid   <= arb_ins_pasid;
                insert_data_func_id <= arb_ins_func_id;
                insert_data_va      <= arb_ins_va;
                insert_data_pa      <= arb_ins_pa;
                insert_data_stu     <= arb_ins_stu;
                insert_data_perm    <= arb_ins_perm;
                insert_set_idx      <= ins_set_idx;
            end

            if (dc_rsp_valid && insert_pending) begin
                if (dc_duplicate) begin
                    insert_way_idx <= dc_dup_entry_idx[5:0];
                    insert_set_idx <= dc_dup_entry_idx[10:6];
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
    // NRU way partition
    //=========================================================================
    assign ea_nru_way_base  = get_user_way_base(ea_cfg_num_users, arb_ins_func_id[5:0]);
    assign ea_nru_way_limit = get_user_way_limit(ea_cfg_num_users, arb_ins_func_id[5:0]);
    assign ea_nru_clear_all_used = 1'b0;

    //=========================================================================
    // NRU Decay Timer
    //=========================================================================
    reg [9:0] nru_decay_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nru_decay_counter <= 10'd0;
            ea_nru_decay_tick <= 1'b0;
        end else begin
            if (nru_decay_counter == 10'd1023) begin
                nru_decay_counter <= 10'd0;
                ea_nru_decay_tick <= 1'b1;
            end else begin
                nru_decay_counter <= nru_decay_counter + 10'd1;
                ea_nru_decay_tick <= 1'b0;
            end
        end
    end

    //=========================================================================
    // Response Output
    //=========================================================================
    reg         dma_lu_rsp_hit_r;
    reg         dma_lu_rsp_pre_hit_r;
    reg [63:0]  dma_lu_rsp_pa_r;
    reg [3:0]   dma_lu_rsp_perm_r;
    reg         dma_lu_rsp_hit_pv_r;

    assign dma_lu_rsp_valid  = lu_engine_rsp_valid && rsp_is_lookup[2];
    always @(*) begin
        dma_lu_rsp_hit_r     = lu_engine_rsp_hit;
        dma_lu_rsp_pre_hit_r = lu_engine_rsp_pre_hit;
        if (!ats_enable[arb_lu_func_id[5:0]]) begin
            dma_lu_rsp_hit_r     = 1'b0;
            dma_lu_rsp_pre_hit_r = 1'b0;
        end
    end
    assign dma_lu_rsp_hit     = dma_lu_rsp_hit_r;
    assign dma_lu_rsp_pre_hit = dma_lu_rsp_pre_hit_r;
    assign dma_lu_rsp_translated_addr = lu_engine_rsp_pa;
    assign dma_lu_rsp_perm    = lu_engine_rsp_perm;
    assign dma_lu_rsp_hit_pv  = lu_engine_rsp_hit_pv;

    // Relook response
    assign dma_rl_rsp_valid  = lu_engine_rsp_valid && !rsp_is_lookup[2];
    assign dma_rl_rsp_hit    = lu_engine_rsp_hit;
    assign dma_rl_rsp_translated_addr = lu_engine_rsp_pa;
    assign dma_rl_rsp_perm   = lu_engine_rsp_perm;

    // Flow-control ready pass-through
    assign dma_lu_req_ready  = lu_req_ready;
    assign dma_rl_req_ready  = rl_req_ready;
    assign ats_inv_req_ready = inv_req_ready;

    // FLR done / Prefetch valid / Inv ack
    assign flr_done            = invh_flr_done;
    assign prefetch_rsp_valid  = {16{lu_engine_rsp_valid}};
    assign ats_inv_ack_valid   = invh_inv_ack;

endmodule
