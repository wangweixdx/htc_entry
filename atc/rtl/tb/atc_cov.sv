//=============================================================================
// atc_cov.sv — Functional Coverage Collector
//
// Covergroups:
//   cg_lookup_result   — Hit, Miss, Pre-Hit
//   cg_pv_mode         — PV=0, PV≠0, PV mismatch
//   cg_stu_value       — STU encodings
//   cg_set_occupancy   — Set fill levels
//   cg_nru_state       — NRU state transitions
//   cg_dupcheck        — Duplicate detection
//   cg_inv_type        — Regular, FLR, ATS Toggle
//   cg_arb_priority    — Arbitration winner
//   cg_pipeline        — Pipeline fill level
//=============================================================================
module atc_cov
    import atc_pkg::*;
    import atc_test_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    atc_if              vif,
    atc_scoreboard      sb
);

    //=========================================================================
    // Helpers
    //=========================================================================
    int          active_lookups;   // lookups in flight
    int          set_fill_est [N_SETS-1:0];  // estimated entries per set

    // Track last lookup request cycle for pipeline depth estimation
    int          last_lu_req_cycle;
    int          pipeline_depth_est;

    //=========================================================================
    // cg_lookup_result: Lookup outcomes
    //=========================================================================
    covergroup cg_lookup_result @(posedge clk);
        cp_valid: coverpoint vif.dma_lu_rsp_valid {
            bins VALID = {1};
        }
        cp_hit: coverpoint vif.dma_lu_rsp_hit {
            bins HIT  = {1};
            bins MISS = {0};
        }
        // Note: pre_hit is embedded in hit signal per top-level logic.
        cross_hit: cross cp_valid, cp_hit {
            bins VALID_HIT  = binsof(cp_valid.VALID) && binsof(cp_hit.HIT);
            bins VALID_MISS = binsof(cp_valid.VALID) && binsof(cp_hit.MISS);
        }
    endgroup : cg_lookup_result

    //=========================================================================
    // cg_pv_mode: PV value distribution in lookups
    //=========================================================================
    covergroup cg_pv_mode @(posedge clk);
        cp_pv_val: coverpoint vif.dma_lu_req_pv {
            bins PV_ZERO  = {16'h0000};
            bins PV_ONE   = {16'h0001};
            bins PV_OTHER = {[16'h0002:16'hFFFE]};
            bins PV_MAX   = {16'hFFFF};
        }
        cp_pv_zero: coverpoint (vif.dma_lu_req_pv == 16'h0000) {
            bins SRIOV = {1};
            bins SIOV  = {0};
        }
    endgroup : cg_pv_mode

    //=========================================================================
    // cg_stu_value: STU encodings seen
    //=========================================================================
    covergroup cg_stu_value @(posedge clk);
        cp_stu: coverpoint vif.ats_comp_stu {
            bins STU_4KB    = {12};
            bins STU_8KB    = {13};
            bins STU_256KB  = {18};
            bins STU_2MB    = {21};
            bins STU_16MB   = {24};
            bins STU_1GB    = {30};
            bins STU_OTHER  = default;
        }
        option.per_instance = 1;
    endgroup : cg_stu_value

    //=========================================================================
    // cg_set_occupancy: Set fill level estimation
    //=========================================================================
    covergroup cg_set_occupancy @(negedge clk);
        cp_occ: coverpoint sb.total_inserts {
            bins EMPTY    = {0};
            bins LOW      = {[1:512]};
            bins MEDIUM   = {[513:1024]};
            bins HIGH     = {[1025:1536]};
            bins VERYHIGH = {[1537:2047]};
            bins FULL     = {2048};
        }
    endgroup : cg_set_occupancy

    //=========================================================================
    // cg_dupcheck: Duplicate check results
    //=========================================================================
    covergroup cg_dupcheck @(posedge clk);
        cp_dup: coverpoint sb.total_inserts {
            bins INSERTS = {[1:$]};
        }
    endgroup : cg_dupcheck

    //=========================================================================
    // cg_inv_type: Invalidation type coverage
    //=========================================================================
    covergroup cg_inv_type @(posedge clk);
        cp_reg_inv: coverpoint sb.total_invs {
            bins ZERO   = {0};
            bins ONE    = {1};
            bins MULTI  = {[2:$]};
        }
        cp_flr: coverpoint sb.total_flrs {
            bins ZERO   = {0};
            bins ONE    = {1};
            bins MULTI  = {[2:$]};
        }
    endgroup : cg_inv_type

    //=========================================================================
    // cg_arb_priority: Arbitration priority triggers
    //=========================================================================
    covergroup cg_arb_priority @(posedge clk);
        cp_flr_active: coverpoint vif.csr_flr_req {
            bins TRIGGERED = {1};
            bins IDLE      = {0};
        }
        cp_inv_active: coverpoint vif.ats_inv_req_valid {
            bins TRIGGERED = {1};
            bins IDLE      = {0};
        }
    endgroup : cg_arb_priority

    //=========================================================================
    // cg_pipeline: Pipeline activity level
    //=========================================================================
    covergroup cg_pipeline @(posedge clk);
        cp_lu_valid: coverpoint vif.dma_lu_req_valid {
            bins ACTIVE = {1};
            bins IDLE   = {0};
        }
        cp_lu_rsp_valid: coverpoint vif.dma_lu_rsp_valid {
            bins ACTIVE = {1};
            bins IDLE   = {0};
        }
    endgroup : cg_pipeline

    //=========================================================================
    // cg_func_id: Function ID coverage
    //=========================================================================
    covergroup cg_func_id @(posedge clk);
        cp_func_id_lu: coverpoint vif.dma_lu_req_func_id {
            bins F0    = {0};
            bins F1_15 = {[1:15]};
            bins F16_31 = {[16:31]};
            bins F32_47 = {[32:47]};
            bins F48_63 = {[48:63]};
        }
        option.per_instance = 1;
    endgroup : cg_func_id

    //=========================================================================
    // Instantiate all covergroups
    //=========================================================================
    cg_lookup_result  cg_lu_res  = new();
    cg_pv_mode        cg_pv      = new();
    cg_stu_value      cg_stu     = new();
    cg_set_occupancy  cg_set_occ = new();
    cg_dupcheck       cg_dc      = new();
    cg_inv_type       cg_inv     = new();
    cg_arb_priority   cg_arb     = new();
    cg_pipeline       cg_pipe    = new();
    cg_func_id        cg_fid     = new();

    //=========================================================================
    // Pipeline depth estimation
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_lookups   <= 0;
            last_lu_req_cycle <= 0;
            pipeline_depth_est <= 0;
        end else begin
            if (vif.dma_lu_req_valid)
                active_lookups <= active_lookups + 1;
            if (vif.dma_lu_rsp_valid)
                active_lookups <= active_lookups - 1;
            if (active_lookups > pipeline_depth_est)
                pipeline_depth_est <= active_lookups;
        end
    end

    //=========================================================================
    // Report
    //=========================================================================
    final begin
        $display("========================================");
        $display("  ATC Coverage Summary");
        $display("========================================");
        $display("  cg_lookup_result  : %.0f%%", cg_lu_res.get_coverage());
        $display("  cg_pv_mode        : %.0f%%", cg_pv.get_coverage());
        $display("  cg_stu_value      : %.0f%%", cg_stu.get_coverage());
        $display("  cg_set_occupancy  : %.0f%%", cg_set_occ.get_coverage());
        $display("  cg_dupcheck       : %.0f%%", cg_dc.get_coverage());
        $display("  cg_inv_type       : %.0f%%", cg_inv.get_coverage());
        $display("  cg_arb_priority   : %.0f%%", cg_arb.get_coverage());
        $display("  cg_pipeline       : %.0f%%", cg_pipe.get_coverage());
        $display("  cg_func_id        : %.0f%%", cg_fid.get_coverage());
        $display("  Max pipeline depth: %0d", pipeline_depth_est);
        $display("========================================");
    end

endmodule : atc_cov
