//=============================================================================
// atc_inv_handler.sv — Invalidation Handler: 3 modes
//   1. Regular ATS Invalidation — clears entries matching inv request
//   2. ATS Enable Toggle — clears ALL entries (global invalidation)
//   3. FLR (Function Level Reset) — clears entries for a specific Function ID
//
// Multi-cycle execution for full-traversal invalidation.
//=============================================================================
module atc_inv_handler
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Invalidation Request Inputs ----
    // Regular ATS invalidation
    input  logic                         inv_req_valid,
    input  ats_inv_req_t                 inv_req,
    output logic                         inv_req_ready,
    output logic                         inv_ack_valid,

    // ATS enable toggle
    input  logic [65:0]                  ats_toggle_req,   // per-function toggle

    // FLR
    input  logic                         flr_req,
    input  logic [FUNC_ID_WIDTH-1:0]     flr_func_id,
    output logic                         flr_done,

    // ---- Entry Array Interface (batch clear + individual invalidation) ----
    output logic                         ea_batch_clr_en,
    output logic [FUNC_ID_WIDTH-1:0]     ea_batch_clr_func_id,
    output logic                         ea_batch_clr_all,

    // Individual invalidation (per-set, per-way)
    output logic                         ea_inv_en,
    output logic [SET_IDX_W-1:0]         ea_inv_set_idx,
    output logic [WAY_IDX_W-1:0]         ea_inv_way_idx,

    // ---- Comparison port for regular invalidation (via entry array) ----
    output logic                         ea_cmp_inv_mode,  // 1=use invalidation compare rules
    output logic                         ea_cmp_en,
    output logic [SET_IDX_W-1:0]         ea_cmp_set_idx,
    output logic [PV_WIDTH-1:0]          ea_cmp_pv,
    output logic [PASID_WIDTH-1:0]       ea_cmp_pasid,
    output logic [FUNC_ID_WIDTH-1:0]     ea_cmp_func_id,
    output logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] ea_cmp_addr,

    input  logic [PREFETCH_COUNT-1:0][HIT_VEC_W-1:0]  ea_hit_vectors,
    input  logic [WAY_IDX_W-1:0]         ea_hit_way_idx,
    input  logic                         ea_any_hit,

    // ---- Busy / status ----
    output logic                         inv_busy,

    // ---- Partition config ----
    input  logic [N_USER_W-1:0]          cfg_num_users
);

    //=========================================================================
    // Partition scan range (latched on entry from IDLE)
    //=========================================================================
    logic [SET_IDX_W-1:0] scan_set_base;   // first set to scan
    logic [SET_IDX_W-1:0] scan_set_limit;  // one past last set
    wire  [SET_IDX_W-1:0] scan_set_last;   // last valid set (limit-1)
    assign scan_set_last = scan_set_limit - SET_IDX_W'(1);

    //=========================================================================
    // FSM States
    //=========================================================================
    typedef enum logic [3:0] {
        INV_IDLE,
        // Regular ATS invalidation path (per-set traversal)
        INV_REG_SCAN,     // scan each set for matching entries
        INV_REG_CLEAR,    // clear matched entry
        INV_REG_NEXT_SET, // advance to next set
        // ATS Toggle path (32 sets × 64 ways, 4 cycles)
        INV_ATS_CLR,      // batch clearing all entries
        INV_ATS_WAIT,     // wait for completion
        // FLR path (32 sets × 64 ways, compare func_id, 4 cycles)
        INV_FLR_SCAN,     // scan for func_id match
        INV_FLR_CLR,      // clear matching entries
        INV_FLR_WAIT,
        // Done
        INV_DONE
    } inv_state_t;

    inv_state_t state, state_next;

    // Scan counters
    logic [SET_IDX_W-1:0]  scan_set_cnt;
    logic [WAY_IDX_W-1:0]  scan_way_cnt;
    logic [WAY_IDX_W-1:0]  batch_cycle_cnt;  // 6 bits, counts up to N_WAYS-1 (63)

    // Stored request
    ats_inv_req_t stored_inv_req;

    // Pending flags to track which operation is in progress
    logic reg_inv_pending;     // regular ATS invalidation in progress
    logic flr_pending;         // FLR in progress
    logic ats_toggle_pending;  // ATS toggle in progress

    //=========================================================================
    // FSM Combinational
    //=========================================================================
    always_comb begin
        state_next        = state;
        inv_req_ready     = 1'b0;
        inv_ack_valid     = 1'b0;
        flr_done          = 1'b0;
        inv_busy          = (state != INV_IDLE) && (state != INV_DONE);

        // Default: use invalidation comparison rules (override for lookup in atc_ctrl mux)
        ea_cmp_inv_mode   = 1'b1;

        ea_batch_clr_en   = 1'b0;
        ea_batch_clr_func_id = flr_func_id;
        ea_batch_clr_all  = 1'b0;

        ea_inv_en         = 1'b0;
        ea_inv_set_idx    = scan_set_cnt;
        ea_inv_way_idx    = ea_hit_way_idx;  // use actual hit way, not scan counter

        ea_cmp_en         = 1'b0;
        ea_cmp_set_idx    = scan_set_cnt;
        ea_cmp_pv         = stored_inv_req.pv;
        ea_cmp_pasid      = stored_inv_req.pasid;
        ea_cmp_func_id    = stored_inv_req.func_id;
        // Invalidation uses only current address (no prefetch)
        for (int p = 0; p < PREFETCH_COUNT; p++)
            ea_cmp_addr[p] = stored_inv_req.untranslated_addr;

        case (state)
            INV_IDLE: begin
                inv_req_ready = 1'b1;
                // Priority: FLR > ATS Toggle > Regular Inv
                if (flr_req) begin
                    state_next = INV_FLR_SCAN;
                end else if (|ats_toggle_req) begin
                    state_next = INV_ATS_CLR;
                end else if (inv_req_valid) begin
                    state_next = INV_REG_SCAN;
                end
            end

            // ---- Regular ATS Invalidation (uses cmp_inv_mode=1) ----
            INV_REG_SCAN: begin
                ea_cmp_inv_mode = 1'b1;
                ea_cmp_en = 1'b1;
                if (ea_any_hit) begin
                    ea_inv_en = 1'b1;
                    state_next = INV_REG_CLEAR;
                end else if (scan_set_cnt == scan_set_last) begin
                    state_next = INV_DONE;
                end else begin
                    state_next = INV_REG_NEXT_SET;
                end
            end

            INV_REG_NEXT_SET: begin
                state_next = INV_REG_SCAN;
            end

            INV_REG_CLEAR: begin
                // Clearing done this cycle, move to next set or done
                if (scan_set_cnt == scan_set_last) begin
                    state_next = INV_DONE;
                end else begin
                    state_next = INV_REG_SCAN;
                end
            end

            // ---- ATS Toggle: Batch Clear All (64 cycles for 2048 entries) ----
            INV_ATS_CLR: begin
                ea_batch_clr_en  = 1'b1;
                ea_batch_clr_all = 1'b1;
                if (batch_cycle_cnt == WAY_IDX_W'(N_WAYS-1)) begin
                    state_next = INV_DONE;
                end
            end

            // ---- FLR: Batch Clear with func_id matching (up to 64 cycles) ----
            INV_FLR_SCAN: begin
                ea_batch_clr_en  = 1'b1;
                ea_batch_clr_func_id = flr_func_id;
                ea_batch_clr_all = 1'b0;
                if (batch_cycle_cnt == WAY_IDX_W'(N_WAYS-1)) begin
                    state_next = INV_DONE;
                end
            end

            INV_DONE: begin
                // Use pending flags to assert correct done/ack
                inv_ack_valid = reg_inv_pending;
                flr_done      = flr_pending || ats_toggle_pending;
                state_next    = INV_IDLE;
            end

            default: state_next = INV_IDLE;
        endcase
    end

    //=========================================================================
    // Counters & Registers
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= INV_IDLE;
            scan_set_cnt     <= '0;
            scan_way_cnt     <= '0;
            batch_cycle_cnt  <= '0;
            scan_set_base    <= '0;
            scan_set_limit   <= SET_IDX_W'(N_SETS);
            reg_inv_pending  <= 1'b0;
            flr_pending      <= 1'b0;
            ats_toggle_pending <= 1'b0;
            stored_inv_req   <= '{
                inv_mask: '0, pv: '0, pv_valid: 1'b0,
                pasid: '0, func_id: '0, untranslated_addr: '0
            };
        end else begin
            state <= state_next;

            case (state)
                INV_IDLE: begin
                    scan_way_cnt    <= '0;
                    batch_cycle_cnt <= '0;
                    // Set pending flag and partition range based on trigger
                    if (flr_req) begin
                        flr_pending <= 1'b1;
                        reg_inv_pending <= 1'b0;
                        ats_toggle_pending <= 1'b0;
                        scan_set_base  <= get_user_set_base(cfg_num_users,
                            int'(flr_func_id[5:0]));
                        scan_set_limit <= get_user_set_limit(cfg_num_users,
                            int'(flr_func_id[5:0]));
                        scan_set_cnt   <= get_user_set_base(cfg_num_users,
                            int'(flr_func_id[5:0]));
                    end else if (|ats_toggle_req) begin
                        ats_toggle_pending <= 1'b1;
                        reg_inv_pending <= 1'b0;
                        flr_pending <= 1'b0;
                        // ATS toggle: global operation, scan all sets
                        scan_set_base  <= '0;
                        scan_set_limit <= SET_IDX_W'(N_SETS);
                        scan_set_cnt   <= '0;
                    end else if (inv_req_valid) begin
                        reg_inv_pending <= 1'b1;
                        flr_pending <= 1'b0;
                        ats_toggle_pending <= 1'b0;
                        stored_inv_req <= inv_req;
                        scan_set_base  <= get_user_set_base(cfg_num_users,
                            int'(inv_req.func_id[5:0]));
                        scan_set_limit <= get_user_set_limit(cfg_num_users,
                            int'(inv_req.func_id[5:0]));
                        scan_set_cnt   <= get_user_set_base(cfg_num_users,
                            int'(inv_req.func_id[5:0]));
                    end
                end

                INV_REG_SCAN: begin
                    // scan_set_cnt stays (comparing current set)
                end

                INV_REG_NEXT_SET: begin
                    scan_set_cnt <= scan_set_cnt + 1'b1;
                end

                INV_REG_CLEAR: begin
                    if (scan_set_cnt == scan_set_last) begin
                        scan_set_cnt <= scan_set_base;  // wrap to partition start
                    end else begin
                        scan_set_cnt <= scan_set_cnt + 1'b1;
                    end
                end

                INV_ATS_CLR: begin
                    batch_cycle_cnt <= batch_cycle_cnt + 1'b1;
                end

                INV_FLR_SCAN: begin
                    batch_cycle_cnt <= batch_cycle_cnt + 1'b1;
                end

                INV_DONE: begin
                    // Clear all pending flags
                    reg_inv_pending   <= 1'b0;
                    flr_pending       <= 1'b0;
                    ats_toggle_pending <= 1'b0;
                end

                default: ;
            endcase
        end
    end

endmodule : atc_inv_handler
