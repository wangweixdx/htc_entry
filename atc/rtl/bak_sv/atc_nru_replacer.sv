//=============================================================================
// atc_nru_replacer.sv — NRU (Not Recently Used) Victim Selection
// Per-set logic: manages 64 × 2b NRU state, selects victim way for insertion
//=============================================================================
module atc_nru_replacer
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Victim selection request ----
    input  logic                         victim_sel_en,   // request victim selection
    output logic [WAY_IDX_W-1:0]         victim_way,      // selected way index
    output logic                         victim_valid,     // valid victim found

    // ---- NRU state update ----
    input  logic                         nru_update_en,
    input  logic [WAY_IDX_W-1:0]         nru_update_way,
    input  logic [NRU_HINT_W-1:0]        nru_update_val,

    // ---- NRU state read (for lookup/access tracking) ----
    output logic [N_WAYS-1:0][NRU_HINT_W-1:0] nru_state_out,

    // ---- Global operations ----
    input  logic                         nru_clear_all_used,  // clear all used bits
    input  logic                         nru_decay_tick,      // periodic decay trigger

    // ---- Partition way range (for >32 user mode) ----
    input  logic [WAY_IDX_W:0]           way_base,            // first eligible way
    input  logic [WAY_IDX_W:0]           way_limit            // last+1 eligible way (0-64)
);

    //=========================================================================
    // NRU State Storage: 64 ways × 2 bits
    //=========================================================================
    logic [N_WAYS-1:0][NRU_HINT_W-1:0] nru_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize all ways as FREE (used=0, not_last=1)
            for (int i = 0; i < N_WAYS; i++) begin
                nru_state[i] <= NRU_FREE;
            end
        end else begin
            if (nru_clear_all_used) begin
                // Clear used bit on all ways, randomly set one way's not_last=0
                for (int i = 0; i < N_WAYS; i++) begin
                    nru_state[i][1] <= 1'b0;  // used = 0
                    // Keep not_last as-is except for way 0 (pseudo-random)
                    if (i == 0) nru_state[i][0] <= 1'b0;  // not_last = 0
                end
            end else if (nru_decay_tick) begin
                // Periodic decay: clear all used bits
                for (int i = 0; i < N_WAYS; i++) begin
                    nru_state[i][1] <= 1'b0;  // used = 0
                end
            end else if (nru_update_en) begin
                nru_state[nru_update_way] <= nru_update_val;
            end
        end
    end

    assign nru_state_out = nru_state;

    //=========================================================================
    // Victim Selection (combinational priority encoder)
    // Priority: NRU_FREE(01) > NRU_IDLE(00) > NRU_ACTIVE(11) > NRU_PROTECT(10)
    //=========================================================================
    logic       found;
    logic [5:0] sel_way;

    // Victim search: full range with partition gating for DC synthesis compatibility
    // way_base/way_limit filter applied as condition instead of loop bounds
    logic in_range;
    always_comb begin
        found   = 1'b0;
        sel_way = WAY_IDX_W'(way_base);

        // Priority 1: FREE (used=0, not_last=1)
        for (int i = 0; i < N_WAYS; i++) begin
            in_range = (i >= int'(way_base)) && (i < int'(way_limit));
            if (!found && in_range && nru_state[i] == NRU_FREE) begin
                found   = 1'b1;
                sel_way = WAY_IDX_W'(i);
            end
        end

        // Priority 2: IDLE (used=0, not_last=0)
        if (!found) begin
            for (int i = 0; i < N_WAYS; i++) begin
                in_range = (i >= int'(way_base)) && (i < int'(way_limit));
                if (!found && in_range && nru_state[i] == NRU_IDLE) begin
                    found   = 1'b1;
                    sel_way = WAY_IDX_W'(i);
                end
            end
        end

        // Priority 3: ACTIVE (used=1, not_last=1)
        if (!found) begin
            for (int i = 0; i < N_WAYS; i++) begin
                in_range = (i >= int'(way_base)) && (i < int'(way_limit));
                if (!found && in_range && nru_state[i] == NRU_ACTIVE) begin
                    found   = 1'b1;
                    sel_way = WAY_IDX_W'(i);
                end
            end
        end

        // Priority 4 (fallback): PROTECT (used=1, not_last=0)
        if (!found) begin
            for (int i = 0; i < N_WAYS; i++) begin
                in_range = (i >= int'(way_base)) && (i < int'(way_limit));
                if (!found && in_range) begin
                    found   = 1'b1;
                    sel_way = WAY_IDX_W'(i);
                end
            end
        end
    end

    assign victim_way   = sel_way;
    assign victim_valid = found && victim_sel_en;

endmodule : atc_nru_replacer
