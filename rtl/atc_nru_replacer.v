//=============================================================================
// atc_nru_replacer.v — NRU (Not Recently Used) Victim Selection (Verilog-2001)
// Per-set logic: manages 64 × 2b NRU state, selects victim way for insertion
//=============================================================================
`include "atc_defines.vh"

module atc_nru_replacer (
    input                   clk,
    input                   rst_n,

    // ---- Victim selection request ----
    input                   victim_sel_en,
    output [5:0]            victim_way,
    output                  victim_valid,

    // ---- NRU state update ----
    input                   nru_update_en,
    input  [5:0]            nru_update_way,
    input  [1:0]            nru_update_val,

    // ---- NRU state read ----
    output [63:0][1:0]      nru_state_out,

    // ---- Global operations ----
    input                   nru_clear_all_used,
    input                   nru_decay_tick,

    // ---- Partition way range ----
    input  [6:0]            way_base,
    input  [6:0]            way_limit
);

    //=========================================================================
    // NRU State Storage: 64 ways × 2 bits
    //=========================================================================
    reg [63:0][1:0] nru_state;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 64; i = i + 1) begin
                nru_state[i] <= `NRU_FREE;
            end
        end else begin
            if (nru_clear_all_used) begin
                for (i = 0; i < 64; i = i + 1) begin
                    nru_state[i][1] <= 1'b0;  // used = 0
                    if (i == 0) nru_state[i][0] <= 1'b0;  // not_last = 0
                end
            end else if (nru_decay_tick) begin
                for (i = 0; i < 64; i = i + 1) begin
                    nru_state[i][1] <= 1'b0;
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
    reg         found;
    reg [5:0]   sel_way;
    reg         in_range;
    integer     j;

    always @(*) begin
        found   = 1'b0;
        sel_way = way_base[5:0];

        // Priority 1: FREE (used=0, not_last=1)
        for (j = 0; j < 64; j = j + 1) begin
            in_range = (j >= way_base) && (j < way_limit);
            if (!found && in_range && nru_state[j] == `NRU_FREE) begin
                found   = 1'b1;
                sel_way = j[5:0];
            end
        end

        // Priority 2: IDLE (used=0, not_last=0)
        if (!found) begin
            for (j = 0; j < 64; j = j + 1) begin
                in_range = (j >= way_base) && (j < way_limit);
                if (!found && in_range && nru_state[j] == `NRU_IDLE) begin
                    found   = 1'b1;
                    sel_way = j[5:0];
                end
            end
        end

        // Priority 3: ACTIVE (used=1, not_last=1)
        if (!found) begin
            for (j = 0; j < 64; j = j + 1) begin
                in_range = (j >= way_base) && (j < way_limit);
                if (!found && in_range && nru_state[j] == `NRU_ACTIVE) begin
                    found   = 1'b1;
                    sel_way = j[5:0];
                end
            end
        end

        // Priority 4 (fallback): PROTECT (used=1, not_last=0)
        if (!found) begin
            for (j = 0; j < 64; j = j + 1) begin
                in_range = (j >= way_base) && (j < way_limit);
                if (!found && in_range) begin
                    found   = 1'b1;
                    sel_way = j[5:0];
                end
            end
        end
    end

    assign victim_way   = sel_way;
    assign victim_valid = found && victim_sel_en;

endmodule
