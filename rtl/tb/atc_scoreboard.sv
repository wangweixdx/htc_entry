//=============================================================================
// atc_scoreboard.sv — Scoreboard with Shadow ATC Reference Model
//
// Maintains a software mirror of the DUT's 2048-entry ATC state.
// Predicts lookup/invalidate/dupcheck results and compares against DUT.
//=============================================================================
module atc_scoreboard
    import atc_pkg::*;
    import atc_test_pkg::*;
(
    input logic clk,
    input logic rst_n,
    input logic [N_USER_W-1:0] cfg_num_users
);

    //=========================================================================
    // Shadow ATC: 2048 entries, software model
    //=========================================================================
    typedef struct {
        logic                         valid;
        logic [PV_WIDTH-1:0]          pv;
        logic [PASID_WIDTH-1:0]       pasid;
        logic [FUNC_ID_WIDTH-1:0]     func_id;
        logic [VA_WIDTH-1:0]          va;
        logic [STU_WIDTH-1:0]         stu;
        logic [PA_WIDTH-1:0]          pa;
        logic [PERM_WIDTH-1:0]        perm;
        logic [NRU_HINT_W-1:0]        nru;     // NRU state tracking
        int                           last_access;
    } shadow_entry_t;

    shadow_entry_t shadow [N_ENTRIES-1:0];

    //=========================================================================
    // Statistics
    //=========================================================================
    int total_lookups    = 0;
    int total_inserts    = 0;
    int total_invs       = 0;
    int total_flrs       = 0;
    int mismatch_count   = 0;
    int cycle_count      = 0;

    //=========================================================================
    // Initialization
    //=========================================================================
    initial begin
        for (int i = 0; i < N_ENTRIES; i++) begin
            shadow[i].valid = 1'b0;
            shadow[i].nru   = NRU_FREE;
            shadow[i].last_access = 0;
        end
    end

    //=========================================================================
    // Hash function (must match DUT exactly)
    //=========================================================================
    function automatic logic [SET_IDX_W-1:0] hash_set_idx(
        logic [FUNC_ID_WIDTH-1:0] func_id,
        logic [VA_WIDTH-1:0]      va
    );
        logic [3:0] func_low    = func_id[3:0];
        logic [3:0] va_nibble   = va[15:12];
        logic [4:0] hash_result = {1'b0, func_low} ^ {1'b0, va_nibble};
        hash_set_idx = hash_result[SET_IDX_W-1:0];
    endfunction

    //=========================================================================
    // Entry index from set + way
    //=========================================================================
    function automatic logic [ENTRY_IDX_W-1:0] entry_idx(
        logic [SET_IDX_W-1:0] set,
        logic [WAY_IDX_W-1:0] way
    );
        entry_idx = {set, way};
    endfunction

    //=========================================================================
    // Compare: check if lookup request hits a shadow entry
    // Uses same logic as DUT: apply_stu_mask, PV matching rules
    //=========================================================================
    function automatic void compare_lookup(
        input  dma_trans_t          tr,
        output logic                 hit,
        output logic                 pre_hit,
        output logic [PA_WIDTH-1:0]  out_pa,
        output logic [PERM_WIDTH-1:0] out_perm,
        output logic [ENTRY_IDX_W-1:0] out_entry
    );
        logic [SET_IDX_W-1:0] set_idx;
        logic [VA_WIDTH-1:0]  addr_b;
        logic                 found, found_pre;

        set_idx = partition_hash(cfg_num_users, int'(tr.func_id[5:0]),
            tr.func_id, tr.addr);
        addr_b  = tr.addr + LOOKAHEAD_OFFSET;

        found     = 1'b0;
        found_pre = 1'b0;
        out_pa    = '0;
        out_perm  = '0;
        out_entry = '0;

        // Search all 64 ways in the target set
        for (int w = 0; w < N_WAYS; w++) begin
            automatic logic [ENTRY_IDX_W-1:0] idx = entry_idx(set_idx, WAY_IDX_W'(w));
            automatic shadow_entry_t e = shadow[idx];
            automatic logic pv_match, pv_nz;
            automatic logic [VA_WIDTH-1:0] lu_masked_a, lu_masked_b, entry_masked;
            automatic logic addr_a_match, addr_b_match;
            automatic logic pasid_match, funcid_match;
            automatic logic tag_match;

            if (!e.valid) continue;

            pv_match  = (tr.pv == e.pv);
            pv_nz     = |e.pv;
            pasid_match  = (tr.pasid == e.pasid);
            funcid_match = (tr.func_id == e.func_id);

            // STU-masked address comparison
            lu_masked_a   = tr.addr & ~((64'd1 << e.stu) - 64'd1);
            lu_masked_b   = addr_b  & ~((64'd1 << e.stu) - 64'd1);
            entry_masked  = e.va    & ~((64'd1 << e.stu) - 64'd1);
            addr_a_match  = (lu_masked_a == entry_masked);
            addr_b_match  = (lu_masked_b == entry_masked);

            // Tag match (lookup rules)
            tag_match = pv_match && (
                ( pv_nz && pasid_match && funcid_match) ||
                (!pv_nz &&                  funcid_match)
            );

            // Hit on primary address
            if (!found && tag_match && addr_a_match) begin
                found     = 1'b1;
                out_pa    = e.pa;
                out_perm  = e.perm;
                out_entry = idx;
                shadow[idx].last_access = cycle_count;
                // Update NRU
                shadow[idx].nru = NRU_ACTIVE;
            end

            // Hit on addr+64K (pre-lookup)
            if (!found_pre && tag_match && addr_b_match && !addr_a_match) begin
                found_pre = 1'b1;
            end
        end

        hit     = found;
        pre_hit = found_pre && !found;
    endfunction

    //=========================================================================
    // DupCheck: check if address already exists
    //=========================================================================
    function automatic logic check_duplicate(
        input ats_comp_trans_t tr,
        output logic [ENTRY_IDX_W-1:0] dup_idx
    );
        logic [VA_WIDTH-1:0] masked_new;
        dup_idx = '0;
        masked_new = tr.untranslated_addr & ~((64'd1 << tr.stu) - 64'd1);

        for (int i = 0; i < N_ENTRIES; i++) begin
            automatic shadow_entry_t e = shadow[i];
            automatic logic [VA_WIDTH-1:0] masked_entry;
            if (!e.valid) continue;

            masked_entry = e.va & ~((64'd1 << e.stu) - 64'd1);

            if (e.pv == tr.pv && e.func_id == tr.func_id &&
                masked_entry == masked_new) begin
                dup_idx = ENTRY_IDX_W'(i);
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    //=========================================================================
    // Find NRU victim in a set
    //=========================================================================
    function automatic logic [WAY_IDX_W-1:0] find_victim(
        input logic [SET_IDX_W-1:0] set_idx
    );
        // Priority: FREE > IDLE > ACTIVE > PROTECT
        for (int w = 0; w < N_WAYS; w++) begin
            if (shadow[entry_idx(set_idx, WAY_IDX_W'(w))].nru == NRU_FREE)
                return WAY_IDX_W'(w);
        end
        for (int w = 0; w < N_WAYS; w++) begin
            if (shadow[entry_idx(set_idx, WAY_IDX_W'(w))].nru == NRU_IDLE)
                return WAY_IDX_W'(w);
        end
        for (int w = 0; w < N_WAYS; w++) begin
            if (shadow[entry_idx(set_idx, WAY_IDX_W'(w))].nru == NRU_ACTIVE)
                return WAY_IDX_W'(w);
        end
        return '0;  // fallback
    endfunction

    //=========================================================================
    // Public API: predict lookup
    //=========================================================================
    function automatic void predict_lookup(inout dma_trans_t tr);
        compare_lookup(tr, tr.exp_hit, tr.exp_pre_hit, tr.exp_pa, tr.exp_perm, entry_idx('0,'0));
    endfunction

    //=========================================================================
    // Public API: check lookup result
    //=========================================================================
    function automatic void check_lookup(
        input dma_trans_t tr,
        input logic       actual_hit,
        input logic [PA_WIDTH-1:0] actual_pa,
        input logic [PERM_WIDTH-1:0] actual_perm
    );
        total_lookups++;
        if (tr.exp_hit != actual_hit) begin
            $display("[SB] MISMATCH: lookup id=%0d exp_hit=%b got_hit=%b",
                     tr.id, tr.exp_hit, actual_hit);
            $display("     PV=%h PASID=%h FuncID=%h Addr=%h",
                     tr.pv, tr.pasid, tr.func_id, tr.addr);
            mismatch_count++;
        end
        if (tr.exp_hit && actual_hit) begin
            if (tr.exp_pa != actual_pa) begin
                $display("[SB] MISMATCH: lookup id=%0d exp_pa=%h got_pa=%h",
                         tr.id, tr.exp_pa, actual_pa);
                mismatch_count++;
            end
            if (tr.exp_perm != actual_perm) begin
                $display("[SB] MISMATCH: lookup id=%0d exp_perm=%b got_perm=%b",
                         tr.id, tr.exp_perm, actual_perm);
                mismatch_count++;
            end
        end
    endfunction

    //=========================================================================
    // Public API: predict insert
    //=========================================================================
    function automatic void predict_insert(inout ats_comp_trans_t tr);
        logic [ENTRY_IDX_W-1:0] dup_idx;
        tr.exp_duplicate = check_duplicate(tr, dup_idx);
    endfunction

    //=========================================================================
    // Public API: commit insert (update shadow)
    //=========================================================================
    function automatic void commit_insert(input ats_comp_trans_t tr);
        logic [SET_IDX_W-1:0]  set_idx;
        logic [WAY_IDX_W-1:0]  way_idx;
        logic [ENTRY_IDX_W-1:0] dup_idx;
        logic                  is_dup;

        total_inserts++;
        set_idx = partition_hash(cfg_num_users, int'(tr.func_id[5:0]),
            tr.func_id, tr.untranslated_addr);
        is_dup  = check_duplicate(tr, dup_idx);

        if (is_dup) begin
            // Overwrite existing entry
            way_idx = dup_idx[WAY_IDX_W-1:0];
            set_idx = dup_idx[ENTRY_IDX_W-1:WAY_IDX_W];
        end else begin
            // Allocate new way via NRU
            way_idx = find_victim(set_idx);
        end

        // Write shadow entry
        shadow[entry_idx(set_idx, way_idx)].valid = 1'b1;
        shadow[entry_idx(set_idx, way_idx)].pv    = tr.pv;
        shadow[entry_idx(set_idx, way_idx)].pasid = tr.pasid;
        shadow[entry_idx(set_idx, way_idx)].func_id = tr.func_id;
        shadow[entry_idx(set_idx, way_idx)].va    = tr.untranslated_addr;
        shadow[entry_idx(set_idx, way_idx)].stu   = tr.stu;
        shadow[entry_idx(set_idx, way_idx)].pa    = tr.translated_addr;
        shadow[entry_idx(set_idx, way_idx)].perm  = tr.perm;
        shadow[entry_idx(set_idx, way_idx)].nru   = NRU_ACTIVE;
        shadow[entry_idx(set_idx, way_idx)].last_access = cycle_count;
    endfunction

    //=========================================================================
    // Public API: predict invalidation
    //=========================================================================
    function automatic void predict_invalidate(input ats_inv_trans_t tr);
        // Find and mark entries to be cleared
        for (int i = 0; i < N_ENTRIES; i++) begin
            automatic shadow_entry_t e = shadow[i];
            if (!e.valid) continue;

            if (tr.pv_valid) begin
                // PV valid: match PV + PASID + FuncID + Addr
                if (e.pv == tr.pv && e.pasid == tr.pasid &&
                    e.func_id == tr.func_id) begin
                    // Addr comparison with STU masking
                    automatic logic [VA_WIDTH-1:0] masked_inv, masked_entry;
                    masked_inv   = tr.untranslated_addr & ~((64'd1 << e.stu) - 64'd1);
                    masked_entry = e.va & ~((64'd1 << e.stu) - 64'd1);
                    if (masked_inv == masked_entry) begin
                        shadow[i].to_clear = 1'b1;
                    end
                end
            end else begin
                // PV invalid: match only FuncID
                if (e.func_id == tr.func_id) begin
                    shadow[i].to_clear = 1'b1;
                end
            end
        end
    endfunction

    // Shadow entry tracking for pending invalidations
    // (Extended shadow with to_clear flag — handled in commit phase)
    logic [N_ENTRIES-1:0] shadow_to_clear;

    function automatic void commit_invalidate(input ats_inv_trans_t tr);
        total_invs++;
        // Apply clears from predict phase
        // In this simplified model, we clear them immediately
        for (int i = 0; i < N_ENTRIES; i++) begin
            if (!shadow[i].valid) continue;
            if (tr.pv_valid) begin
                if (shadow[i].pv == tr.pv && shadow[i].pasid == tr.pasid &&
                    shadow[i].func_id == tr.func_id) begin
                    automatic logic [VA_WIDTH-1:0] masked_inv, masked_entry;
                    masked_inv   = tr.untranslated_addr & ~((64'd1 << shadow[i].stu) - 64'd1);
                    masked_entry = shadow[i].va & ~((64'd1 << shadow[i].stu) - 64'd1);
                    if (masked_inv == masked_entry) begin
                        shadow[i].valid = 1'b0;
                        shadow[i].nru   = NRU_FREE;
                    end
                end
            end else begin
                if (shadow[i].func_id == tr.func_id) begin
                    shadow[i].valid = 1'b0;
                    shadow[i].nru   = NRU_FREE;
                end
            end
        end
    endfunction

    //=========================================================================
    // Public API: commit FLR
    //=========================================================================
    function automatic void commit_flr(input logic [FUNC_ID_WIDTH-1:0] func_id);
        total_flrs++;
        for (int i = 0; i < N_ENTRIES; i++) begin
            if (shadow[i].valid && shadow[i].func_id == func_id) begin
                shadow[i].valid = 1'b0;
                shadow[i].nru   = NRU_FREE;
            end
        end
    endfunction

    //=========================================================================
    // Public API: commit ATS toggle
    //=========================================================================
    function automatic void commit_ats_toggle();
        for (int i = 0; i < N_ENTRIES; i++) begin
            shadow[i].valid = 1'b0;
            shadow[i].nru   = NRU_FREE;
        end
    endfunction

    //=========================================================================
    // Cycle counter
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_count <= 0;
        else cycle_count <= cycle_count + 1;
    end

    //=========================================================================
    // Final report
    //=========================================================================
    final begin
        $display("========================================");
        $display("  ATC Scoreboard Final Report");
        $display("========================================");
        $display("  Total Lookups:    %0d", total_lookups);
        $display("  Total Inserts:    %0d", total_inserts);
        $display("  Total Invalidates:%0d", total_invs);
        $display("  Total FLRs:       %0d", total_flrs);
        $display("  Mismatches:       %0d", mismatch_count);
        if (mismatch_count == 0)
            $display("  RESULT: PASSED");
        else
            $display("  RESULT: FAILED (%0d mismatches)", mismatch_count);
        $display("========================================");
    end

endmodule : atc_scoreboard
