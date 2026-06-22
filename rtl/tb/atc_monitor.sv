//=============================================================================
// atc_monitor.sv — Passive Monitor
//
// Samples all DUT ports passively and feeds observed transactions to the
// scoreboard for real-time checking. Tracks timing statistics.
//=============================================================================
module atc_monitor
    import atc_pkg::*;
    import atc_test_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    atc_if              vif,
    atc_scoreboard      sb
);

    //=========================================================================
    // Observed transaction logs (for post-simulation analysis)
    //=========================================================================
    typedef struct {
        int                             cycle;
        logic [PV_WIDTH-1:0]            pv;
        logic [PASID_WIDTH-1:0]         pasid;
        logic [FUNC_ID_WIDTH-1:0]       func_id;
        logic [VA_WIDTH-1:0]            addr;
    } mon_lu_req_t;

    typedef struct {
        int                             cycle;
        logic                           hit;
        logic [PA_WIDTH-1:0]            pa;
        logic [PERM_WIDTH-1:0]          perm;
    } mon_lu_rsp_t;

    typedef struct {
        int                             cycle;
        logic [PV_WIDTH-1:0]            pv;
        logic [PASID_WIDTH-1:0]         pasid;
        logic [FUNC_ID_WIDTH-1:0]       func_id;
        logic [VA_WIDTH-1:0]            va;
        logic [PA_WIDTH-1:0]            pa;
        logic [STU_WIDTH-1:0]           stu;
        logic [PERM_WIDTH-1:0]          perm;
    } mon_ins_t;

    typedef struct {
        int                             cycle;
        logic                           pv_valid;
        logic [PV_WIDTH-1:0]            pv;
        logic [PASID_WIDTH-1:0]         pasid;
        logic [FUNC_ID_WIDTH-1:0]       func_id;
        logic [VA_WIDTH-1:0]            addr;
    } mon_inv_t;

    // Transaction logs (circular, max 4096 entries)
    localparam int LOG_DEPTH = 4096;
    mon_lu_req_t  lu_req_log [LOG_DEPTH-1:0];
    mon_lu_rsp_t  lu_rsp_log [LOG_DEPTH-1:0];
    mon_ins_t     ins_log    [LOG_DEPTH-1:0];
    mon_inv_t     inv_log    [LOG_DEPTH-1:0];

    int lu_req_cnt, lu_rsp_cnt, ins_cnt, inv_cnt;
    int lu_req_wptr, lu_rsp_wptr, ins_wptr, inv_wptr;

    //=========================================================================
    // Statistics
    //=========================================================================
    int   lu_total_hits;
    int   lu_total_misses;
    int   lu_min_latency;
    int   lu_max_latency;
    real  lu_avg_latency;

    int   lu_req_cycle;   // cycle of last LU request (for latency calc)
    int   lu_latency_tmp;  // temp for latency calc

    //=========================================================================
    // Passive Sampling
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lu_req_cnt  <= 0;
            lu_rsp_cnt  <= 0;
            ins_cnt     <= 0;
            inv_cnt     <= 0;
            lu_req_wptr <= 0;
            lu_rsp_wptr <= 0;
            ins_wptr    <= 0;
            inv_wptr    <= 0;

            lu_total_hits   <= 0;
            lu_total_misses <= 0;
            lu_min_latency  <= 999;
            lu_max_latency  <= 0;
            lu_req_cycle    <= 0;
        end else begin
            // Sample DMA lookup requests
            if (vif.dma_lu_req_valid) begin
                lu_req_log[lu_req_wptr].cycle    = sb.cycle_count;
                lu_req_log[lu_req_wptr].pv       = vif.dma_lu_req_pv;
                lu_req_log[lu_req_wptr].pasid    = vif.dma_lu_req_pasid;
                lu_req_log[lu_req_wptr].func_id  = vif.dma_lu_req_func_id;
                lu_req_log[lu_req_wptr].addr     = vif.dma_lu_req_addr;
                lu_req_wptr <= (lu_req_wptr + 1) % LOG_DEPTH;
                lu_req_cnt  <= lu_req_cnt + 1;
                lu_req_cycle <= sb.cycle_count;
            end

            // Sample DMA lookup responses
            if (vif.dma_lu_rsp_valid) begin
                lu_rsp_log[lu_rsp_wptr].cycle = sb.cycle_count;
                lu_rsp_log[lu_rsp_wptr].hit   = vif.dma_lu_rsp_hit;
                lu_rsp_log[lu_rsp_wptr].pa    = vif.dma_lu_rsp_translated_addr;
                lu_rsp_log[lu_rsp_wptr].perm  = vif.dma_lu_rsp_perm;
                lu_rsp_wptr <= (lu_rsp_wptr + 1) % LOG_DEPTH;
                lu_rsp_cnt  <= lu_rsp_cnt + 1;

                if (vif.dma_lu_rsp_hit)
                    lu_total_hits <= lu_total_hits + 1;
                else
                    lu_total_misses <= lu_total_misses + 1;

                // Latency tracking
                lu_latency_tmp = sb.cycle_count - lu_req_cycle;
                if (lu_latency_tmp < lu_min_latency) lu_min_latency <= lu_latency_tmp;
                if (lu_latency_tmp > lu_max_latency) lu_max_latency <= lu_latency_tmp;
            end

            // Sample ATS completions (inserts)
            if (vif.ats_comp_valid) begin
                ins_log[ins_wptr].cycle              = sb.cycle_count;
                ins_log[ins_wptr].pv                 = vif.ats_comp_pv;
                ins_log[ins_wptr].pasid              = vif.ats_comp_pasid;
                ins_log[ins_wptr].func_id            = vif.ats_comp_func_id;
                ins_log[ins_wptr].va                 = vif.ats_comp_untranslated_addr;
                ins_log[ins_wptr].pa                 = vif.ats_comp_translated_addr;
                ins_log[ins_wptr].stu                = vif.ats_comp_stu;
                ins_log[ins_wptr].perm              = vif.ats_comp_perm;
                ins_wptr <= (ins_wptr + 1) % LOG_DEPTH;
                ins_cnt  <= ins_cnt + 1;
            end

            // Sample ATS invalidations
            if (vif.ats_inv_req_valid) begin
                inv_log[inv_wptr].cycle              = sb.cycle_count;
                inv_log[inv_wptr].pv_valid           = vif.ats_inv_pv_valid;
                inv_log[inv_wptr].pv                 = vif.ats_inv_pv;
                inv_log[inv_wptr].pasid              = vif.ats_inv_pasid;
                inv_log[inv_wptr].func_id            = vif.ats_inv_func_id;
                inv_log[inv_wptr].addr               = vif.ats_inv_untranslated_addr;
                inv_wptr <= (inv_wptr + 1) % LOG_DEPTH;
                inv_cnt  <= inv_cnt + 1;
            end
        end
    end

    //=========================================================================
    // Report
    //=========================================================================
    final begin
        $display("========================================");
        $display("  ATC Monitor Statistics");
        $display("========================================");
        $display("  LU Requests:     %0d", lu_req_cnt);
        $display("  LU Responses:    %0d", lu_rsp_cnt);
        $display("  LU Hits:         %0d", lu_total_hits);
        $display("  LU Misses:       %0d", lu_total_misses);
        if (lu_total_hits + lu_total_misses > 0)
            $display("  LU Hit Rate:     %.1f%%",
                     100.0 * lu_total_hits / (lu_total_hits + lu_total_misses));
        $display("  LU Min Latency:  %0d", lu_min_latency);
        $display("  LU Max Latency:  %0d", lu_max_latency);
        $display("  Inserts:         %0d", ins_cnt);
        $display("  Invalidations:   %0d", inv_cnt);
        $display("========================================");
    end

endmodule : atc_monitor
