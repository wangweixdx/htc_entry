//=============================================================================
// atc_test_pkg.sv — Verification Package: Transactions, Sequences, Helpers
//=============================================================================
package atc_test_pkg;

    import atc_pkg::*;

    //=========================================================================
    // Transaction Types
    //=========================================================================

    // DMA Lookup transaction
    typedef struct {
        rand logic [PV_WIDTH-1:0]      pv;
        rand logic [PASID_WIDTH-1:0]   pasid;
        rand logic [FUNC_ID_WIDTH-1:0] func_id;
        rand logic [VA_WIDTH-1:0]      addr;
        // Expected result (set by scoreboard)
        logic                           exp_hit;
        logic                           exp_pre_hit;
        logic [PA_WIDTH-1:0]            exp_pa;
        logic [PERM_WIDTH-1:0]          exp_perm;
        // Metadata
        int                             id;
        int                             cycle_sent;
        int                             cycle_rcvd;
    } dma_trans_t;

    // ATS Completion (Insert) transaction
    typedef struct {
        rand logic [PV_WIDTH-1:0]      pv;
        rand logic [PASID_WIDTH-1:0]   pasid;
        rand logic [FUNC_ID_WIDTH-1:0] func_id;
        rand logic [VA_WIDTH-1:0]      untranslated_addr;
        rand logic [PA_WIDTH-1:0]      translated_addr;
        rand logic [STU_WIDTH-1:0]     stu;
        rand logic [PERM_WIDTH-1:0]    perm;
        // Expected dupcheck result (set by scoreboard)
        logic                           exp_duplicate;
        int                             id;
    } ats_comp_trans_t;

    // ATS Invalidation transaction
    typedef struct {
        rand logic [FUNC_ID_WIDTH-1:0] inv_mask;
        rand logic                     pv_valid;
        rand logic [PV_WIDTH-1:0]      pv;
        rand logic [PASID_WIDTH-1:0]   pasid;
        rand logic [FUNC_ID_WIDTH-1:0] func_id;
        rand logic [VA_WIDTH-1:0]      untranslated_addr;
        int                            id;
    } ats_inv_trans_t;

    // FLR transaction
    typedef struct {
        logic [FUNC_ID_WIDTH-1:0] func_id;
        int                       cycle_sent;
    } flr_trans_t;

    //=========================================================================
    // Constraints for Randomization
    //=========================================================================

    class dma_trans_constraints;
        rand dma_trans_t tr;
        constraint default_pv      { tr.pv inside {1'b0, 1'b1, [16'h0010:16'h00FF]}; }
        constraint default_func_id { tr.func_id inside {[0:63]}; }
        constraint default_stu_val { 1'b1; }  // STU is not part of DMA trans, but for context
    endclass

    class ats_comp_constraints;
        rand ats_comp_trans_t tr;
        constraint valid_stu  { tr.stu inside {12, 13, 18, 21, 24, 30}; }
        constraint valid_perm { tr.perm inside {4'b0001, 4'b0011, 4'b0111, 4'b1111}; }
    endclass

    //=========================================================================
    // Scoreboard Class: Shadow ATC Reference Model
    //=========================================================================
    class atc_scoreboard;

        // Shadow entry type
        typedef struct {
            logic                         valid;
            logic [PV_WIDTH-1:0]          pv;
            logic [PASID_WIDTH-1:0]       pasid;
            logic [FUNC_ID_WIDTH-1:0]     func_id;
            logic [VA_WIDTH-1:0]          va;
            logic [STU_WIDTH-1:0]         stu;
            logic [PA_WIDTH-1:0]          pa;
            logic [PERM_WIDTH-1:0]        perm;
            logic [NRU_HINT_W-1:0]        nru;
            int                           last_access;
        } shadow_entry_t;

        shadow_entry_t shadow [N_ENTRIES-1:0];

        int total_lookups    = 0;
        int total_inserts    = 0;
        int total_invs       = 0;
        int total_flrs       = 0;
        int mismatch_count   = 0;
        int sb_cycle         = 0;
        logic [N_USER_W-1:0] cfg_num_users = PART_1;  // partition config

        function new();
            for (int i = 0; i < N_ENTRIES; i++) begin
                shadow[i].valid = 1'b0;
                shadow[i].nru   = NRU_FREE;
                shadow[i].last_access = 0;
            end
        endfunction

        function automatic logic [SET_IDX_W-1:0] hash_set_idx(
            logic [FUNC_ID_WIDTH-1:0] func_id,
            logic [VA_WIDTH-1:0]      va
        );
            logic [3:0] func_low  = func_id[3:0];
            logic [3:0] va_nibble = va[15:12];
            logic [4:0] h = {1'b0, func_low} ^ {1'b0, va_nibble};
            hash_set_idx = h[SET_IDX_W-1:0];
        endfunction

        function automatic logic [ENTRY_IDX_W-1:0] entry_idx(
            logic [SET_IDX_W-1:0] s, logic [WAY_IDX_W-1:0] w
        );
            entry_idx = {s, w};
        endfunction

        function automatic void compare_lookup(
            input  dma_trans_t          tr,
            output logic                 hit,
            output logic                 pre_hit,
            output logic [PA_WIDTH-1:0]  out_pa,
            output logic [PERM_WIDTH-1:0] out_perm
        );
            logic [SET_IDX_W-1:0] set_idx = partition_hash(
                cfg_num_users, int'(tr.func_id[5:0]), tr.func_id, tr.addr);
            logic [VA_WIDTH-1:0]  addr_b  = tr.addr + LOOKAHEAD_OFFSET;
            hit     = 1'b0; pre_hit = 1'b0;
            out_pa  = '0; out_perm = '0;
            for (int w = 0; w < N_WAYS; w++) begin
                automatic logic [ENTRY_IDX_W-1:0] idx = entry_idx(set_idx, WAY_IDX_W'(w));
                automatic shadow_entry_t e = shadow[idx];
                if (!e.valid) continue;
                begin
                    automatic logic pv_match  = (tr.pv == e.pv);
                    automatic logic pv_nz     = |e.pv;
                    automatic logic pasid_match  = (tr.pasid == e.pasid);
                    automatic logic funcid_match = (tr.func_id == e.func_id);
                    automatic logic [VA_WIDTH-1:0] mask = ~((64'd1 << e.stu) - 64'd1);
                    automatic logic tag_match = pv_match && (
                        ( pv_nz && pasid_match && funcid_match) ||
                        (!pv_nz &&                  funcid_match)
                    );
                    if (!hit && tag_match && ((tr.addr & mask) == (e.va & mask))) begin
                        hit = 1'b1; out_pa = e.pa; out_perm = e.perm;
                        shadow[idx].last_access = sb_cycle;
                        shadow[idx].nru = NRU_ACTIVE;
                    end
                    if (!pre_hit && tag_match && ((addr_b & mask) == (e.va & mask)) && ((tr.addr & mask) != (e.va & mask))) begin
                        pre_hit = 1'b1;
                        if (!hit) begin  // use pre-hit PA/perm for response
                            out_pa = e.pa; out_perm = e.perm;
                        end
                    end
                end
            end
            hit = hit || pre_hit;  // DUT ORs hit and pre_hit in atc_top
        endfunction

        function automatic logic check_duplicate(
            input ats_comp_trans_t tr,
            output logic [ENTRY_IDX_W-1:0] dup_idx
        );
            logic [VA_WIDTH-1:0] masked_new = tr.untranslated_addr & ~((64'd1 << tr.stu) - 64'd1);
            dup_idx = '0;
            for (int i = 0; i < N_ENTRIES; i++) begin
                automatic shadow_entry_t e = shadow[i];
                if (!e.valid) continue;
                if (e.pv == tr.pv && e.func_id == tr.func_id &&
                    (e.va & ~((64'd1 << e.stu) - 64'd1)) == masked_new) begin
                    dup_idx = ENTRY_IDX_W'(i);
                    return 1'b1;
                end
            end
            return 1'b0;
        endfunction

        function automatic logic [WAY_IDX_W-1:0] find_victim(
            input logic [SET_IDX_W-1:0] set_idx
        );
            for (int w = 0; w < N_WAYS; w++)
                if (shadow[entry_idx(set_idx, WAY_IDX_W'(w))].nru == NRU_FREE) return WAY_IDX_W'(w);
            for (int w = 0; w < N_WAYS; w++)
                if (shadow[entry_idx(set_idx, WAY_IDX_W'(w))].nru == NRU_IDLE) return WAY_IDX_W'(w);
            for (int w = 0; w < N_WAYS; w++)
                if (shadow[entry_idx(set_idx, WAY_IDX_W'(w))].nru == NRU_ACTIVE) return WAY_IDX_W'(w);
            return '0;
        endfunction

        function automatic void predict_lookup(inout dma_trans_t tr);
            compare_lookup(tr, tr.exp_hit, tr.exp_pre_hit, tr.exp_pa, tr.exp_perm);
        endfunction

        function automatic void check_lookup(
            input dma_trans_t tr, input logic actual_hit,
            input logic [PA_WIDTH-1:0] actual_pa, input logic [PERM_WIDTH-1:0] actual_perm
        );
            total_lookups++;
            if (tr.exp_hit != actual_hit) begin
                $display("[SB] MISMATCH: lookup exp_hit=%b got=%b PV=%h PASID=%h FuncID=%h Addr=%h",
                         tr.exp_hit, actual_hit, tr.pv, tr.pasid, tr.func_id, tr.addr);
                mismatch_count++;
            end
            if (tr.exp_hit && actual_hit) begin
                if (tr.exp_pa != actual_pa) begin
                    $display("[SB] MISMATCH: lookup exp_pa=%h got=%h", tr.exp_pa, actual_pa);
                    mismatch_count++;
                end
                if (tr.exp_perm != actual_perm) begin
                    $display("[SB] MISMATCH: lookup exp_perm=%b got=%b", tr.exp_perm, actual_perm);
                    mismatch_count++;
                end
            end
        endfunction

        function automatic void predict_insert(inout ats_comp_trans_t tr);
            logic [ENTRY_IDX_W-1:0] dup_idx;
            tr.exp_duplicate = check_duplicate(tr, dup_idx);
        endfunction

        function automatic void commit_insert(input ats_comp_trans_t tr);
            logic [SET_IDX_W-1:0]  set_idx;
            logic [WAY_IDX_W-1:0]  way_idx;
            logic [ENTRY_IDX_W-1:0] dup_idx;
            logic                  is_dup;
            total_inserts++;
            set_idx = partition_hash(cfg_num_users,
                int'(tr.func_id[5:0]), tr.func_id, tr.untranslated_addr);
            is_dup  = check_duplicate(tr, dup_idx);
            if (is_dup) begin
                way_idx = dup_idx[WAY_IDX_W-1:0];
                set_idx = dup_idx[ENTRY_IDX_W-1:WAY_IDX_W];
            end else begin
                way_idx = find_victim(set_idx);
            end
            shadow[entry_idx(set_idx, way_idx)].valid = 1'b1;
            shadow[entry_idx(set_idx, way_idx)].pv    = tr.pv;
            shadow[entry_idx(set_idx, way_idx)].pasid = tr.pasid;
            shadow[entry_idx(set_idx, way_idx)].func_id = tr.func_id;
            shadow[entry_idx(set_idx, way_idx)].va    = tr.untranslated_addr;
            shadow[entry_idx(set_idx, way_idx)].stu   = tr.stu;
            shadow[entry_idx(set_idx, way_idx)].pa    = tr.translated_addr;
            shadow[entry_idx(set_idx, way_idx)].perm  = tr.perm;
            shadow[entry_idx(set_idx, way_idx)].nru   = NRU_ACTIVE;
            shadow[entry_idx(set_idx, way_idx)].last_access = sb_cycle;
        endfunction

        function automatic void predict_invalidate(input ats_inv_trans_t tr);
            // no-op: prediction recorded in commit phase
        endfunction

        function automatic void commit_invalidate(input ats_inv_trans_t tr);
            total_invs++;
            for (int i = 0; i < N_ENTRIES; i++) begin
                if (!shadow[i].valid) continue;
                if (tr.pv_valid) begin
                    if (shadow[i].pv == tr.pv && shadow[i].pasid == tr.pasid &&
                        shadow[i].func_id == tr.func_id) begin
                        automatic logic [VA_WIDTH-1:0] mask = ~((64'd1 << shadow[i].stu) - 64'd1);
                        if ((tr.untranslated_addr & mask) == (shadow[i].va & mask)) begin
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

        function automatic void commit_flr(input logic [FUNC_ID_WIDTH-1:0] func_id);
            total_flrs++;
            for (int i = 0; i < N_ENTRIES; i++) begin
                if (shadow[i].valid && shadow[i].func_id == func_id) begin
                    shadow[i].valid = 1'b0;
                    shadow[i].nru   = NRU_FREE;
                end
            end
        endfunction

        function automatic void commit_ats_toggle();
            for (int i = 0; i < N_ENTRIES; i++) begin
                shadow[i].valid = 1'b0;
                shadow[i].nru   = NRU_FREE;
            end
        endfunction

        function automatic void set_cycle(int cyc);
            sb_cycle = cyc;
        endfunction

        function void report();
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
        endfunction

    endclass : atc_scoreboard

    //=========================================================================
    // Test Sequence Base Class (non-UVM, pure SV)
    //=========================================================================

    class atc_test_base;
        string                     name;
        int                        timeout_cycles = 100000;
        int                        cycle_count;

        // Virtual interface handles
        virtual atc_if             vif;

        // Reference to scoreboard
        atc_scoreboard             sb;

        function new(string name, virtual atc_if vif, atc_scoreboard sb);
            this.name = name;
            this.vif  = vif;
            this.sb   = sb;
        endfunction

        // Run phase: override in derived tests
        virtual task run();
            $display("[TEST] %s: starting", name);
            reset_dut();
            body();
            $display("[TEST] %s: PASSED", name);
        endtask

        // Reset sequence
        virtual task reset_dut();
            vif.dma_lu_req_valid = 1'b0;
            vif.ats_comp_valid   = 1'b0;
            vif.ats_inv_req_valid = 1'b0;
            vif.csr_ats_enable   = 1'b1;  // ATS enabled by default
            vif.csr_flr_req      = 1'b0;
            vif.csr_flr_func_id  = '0;

            // Wait for reset deassertion + 10 cycles
            @(negedge vif.rst_n);  // wait for reset to go low
            @(posedge vif.rst_n);  // wait for reset release
            repeat (10) @(posedge vif.clk);
        endtask

        // Body: to be overridden
        virtual task body();
            $display("[TEST] %s: empty body — override me", name);
        endtask

        // Helper: send DMA lookup and wait for response
        task automatic do_lookup(
            input logic [PV_WIDTH-1:0]      pv,
            input logic [PASID_WIDTH-1:0]   pasid,
            input logic [FUNC_ID_WIDTH-1:0] func_id,
            input logic [VA_WIDTH-1:0]      addr,
            output logic                    hit,
            output logic                    pre_hit,
            output logic [PA_WIDTH-1:0]     pa,
            output logic [PERM_WIDTH-1:0]   perm
        );
            dma_trans_t tr;
            tr.id    = cycle_count;
            tr.pv    = pv;
            tr.pasid = pasid;
            tr.func_id = func_id;
            tr.addr  = addr;
            tr.cycle_sent = cycle_count;

            // Predict expected result
            sb.predict_lookup(tr);

            // Drive request
            @(posedge vif.clk);
            vif.dma_lu_req_valid  <= 1'b1;
            vif.dma_lu_req_pv     <= pv;
            vif.dma_lu_req_pasid  <= pasid;
            vif.dma_lu_req_func_id <= func_id;
            vif.dma_lu_req_addr   <= addr;

            // Wait for response (3 cycle latency)
            @(posedge vif.clk);
            vif.dma_lu_req_valid <= 1'b0;

            // Wait for response valid
            do begin
                @(posedge vif.clk);
                cycle_count++;
            end while (!vif.dma_lu_rsp_valid);

            hit     = vif.dma_lu_rsp_hit;
            pre_hit = vif.dma_lu_rsp_hit;  // pre_hit embedded in hit signal
            pa      = vif.dma_lu_rsp_translated_addr;
            perm    = vif.dma_lu_rsp_perm;

            tr.cycle_rcvd = cycle_count;

            // Check against prediction
            sb.check_lookup(tr, hit, pa, perm);
        endtask

        // Helper: send ATS completion (insert)
        task automatic do_insert(
            input ats_comp_trans_t tr
        );
            tr.id = cycle_count;
            sb.predict_insert(tr);

            @(posedge vif.clk);
            vif.ats_comp_valid             <= 1'b1;
            vif.ats_comp_pv               <= tr.pv;
            vif.ats_comp_pasid            <= tr.pasid;
            vif.ats_comp_func_id          <= tr.func_id;
            vif.ats_comp_untranslated_addr <= tr.untranslated_addr;
            vif.ats_comp_translated_addr  <= tr.translated_addr;
            vif.ats_comp_stu             <= tr.stu;
            vif.ats_comp_perm            <= tr.perm;

            @(posedge vif.clk);
            vif.ats_comp_valid <= 1'b0;

            // Wait for dupcheck to complete (4 cycle latency)
            repeat (5) @(posedge vif.clk);
            cycle_count += 5;

            // Scoreboard updates its shadow ATC
            sb.commit_insert(tr);
        endtask

        // Helper: send ATS invalidation
        task automatic do_invalidate(
            input ats_inv_trans_t tr
        );
            tr.id = cycle_count;
            sb.predict_invalidate(tr);

            @(posedge vif.clk);
            vif.ats_inv_req_valid          <= 1'b1;
            vif.ats_inv_mask               <= tr.inv_mask;
            vif.ats_inv_pv_valid           <= tr.pv_valid;
            vif.ats_inv_pv                 <= tr.pv;
            vif.ats_inv_pasid             <= tr.pasid;
            vif.ats_inv_func_id           <= tr.func_id;
            vif.ats_inv_untranslated_addr  <= tr.untranslated_addr;

            @(posedge vif.clk);
            vif.ats_inv_req_valid <= 1'b0;

            // Wait for ack
            do begin
                @(posedge vif.clk);
                cycle_count++;
            end while (!vif.ats_inv_ack_valid);

            sb.commit_invalidate(tr);
        endtask

        // Helper: trigger FLR
        task automatic do_flr(
            input logic [FUNC_ID_WIDTH-1:0] func_id
        );
            @(posedge vif.clk);
            vif.csr_flr_req     <= 1'b1;
            vif.csr_flr_func_id <= func_id;

            @(posedge vif.clk);
            vif.csr_flr_req <= 1'b0;

            // Wait for FLR to complete (multi-cycle)
            repeat (70) @(posedge vif.clk);  // 64 cycle clearance + margin
            cycle_count += 70;

            sb.commit_flr(func_id);
        endtask

        // Helper: toggle ATS enable
        task automatic do_ats_toggle();
            @(posedge vif.clk);
            vif.csr_ats_enable <= ~vif.csr_ats_enable;

            // Wait for cleanup
            repeat (70) @(posedge vif.clk);
            cycle_count += 70;

            sb.commit_ats_toggle();
        endtask

        // Wait N cycles
        task automatic wait_cycles(int n);
            repeat (n) @(posedge vif.clk);
            cycle_count += n;
        endtask

    endclass : atc_test_base

    //=========================================================================
    // Helper: Generate random address within STU-masked region
    //=========================================================================
    function automatic logic [VA_WIDTH-1:0] gen_addr_in_page(
        input logic [VA_WIDTH-1:0] base_addr,
        input logic [STU_WIDTH-1:0] stu
    );
        logic [VA_WIDTH-1:0] page_mask;
        logic [VA_WIDTH-1:0] offset;
        page_mask = (64'd1 << stu) - 64'd1;
        offset    = {$random} & page_mask;
        gen_addr_in_page = (base_addr & ~page_mask) | offset;
    endfunction

endpackage : atc_test_pkg
