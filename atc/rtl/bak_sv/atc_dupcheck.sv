//=============================================================================
// atc_dupcheck.sv — Address Duplicate Check (4-cycle full traversal)
// Traverses all 2048 entries over 4 cycles (512 entries/cycle) to detect
// whether a new translation address already exists in the cache.
//=============================================================================
module atc_dupcheck
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Duplicate check request ----
    input  logic                         dup_req_valid,
    input  dupcheck_payload_t            dup_req,
    output logic                         dup_req_ready,

    // ---- Duplicate check result ----
    output logic                         dup_rsp_valid,
    output logic                         duplicate,
    output logic [ENTRY_IDX_W-1:0]       dup_entry_idx,

    // ---- Entry Array Interface (wide read of subset) ----
    output logic [2:0]                   ea_subset_id,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0]  ea_valids,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PV_WIDTH-1:0] ea_pvs,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][PASID_WIDTH-1:0] ea_pasids,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][FUNC_ID_WIDTH-1:0] ea_funcids,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][VA_WIDTH-1:0] ea_vas,
    input  logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0][STU_WIDTH-1:0] ea_stus
);

    //=========================================================================
    // FSM: IDLE → SCAN[0..3] → JUDGE → DONE
    //=========================================================================
    typedef enum logic [2:0] {
        DC_IDLE,
        DC_SCAN0, DC_SCAN1, DC_SCAN2, DC_SCAN3,
        DC_RESULT
    } dc_state_t;

    dc_state_t state, state_next;

    // Stored request
    dupcheck_payload_t stored_payload;
    logic              busy;

    // Per-subset match accumulation
    logic [DUPCHECK_CYCLES-1:0]                        subset_has_match;
    logic [DUPCHECK_CYCLES-1:0][ENTRY_IDX_W-1:0]       subset_match_idx;

    // Masked lookup address
    logic [VA_WIDTH-1:0] dup_addr_masked;
    assign dup_addr_masked = apply_stu_mask(stored_payload.untranslated_addr, stored_payload.stu);

    always_comb begin
        state_next = state;
        dup_req_ready = 1'b0;
        dup_rsp_valid = 1'b0;
        duplicate = 1'b0;
        dup_entry_idx = '0;

        case (state)
            DC_IDLE: begin
                dup_req_ready = 1'b1;
                if (dup_req_valid) begin
                    state_next = DC_SCAN0;
                end
            end

            DC_SCAN0: state_next = DC_SCAN1;
            DC_SCAN1: state_next = DC_SCAN2;
            DC_SCAN2: state_next = DC_SCAN3;
            DC_SCAN3: state_next = DC_RESULT;

            DC_RESULT: begin
                dup_rsp_valid = 1'b1;
                // Check all subsets for any match
                duplicate = |subset_has_match;
                // Priority encode the first match
                for (int i = 0; i < DUPCHECK_CYCLES; i++) begin
                    if (subset_has_match[i]) begin
                        dup_entry_idx = subset_match_idx[i];
                        break;
                    end
                end
                state_next = DC_IDLE;
            end

            default: state_next = DC_IDLE;
        endcase
    end

    //=========================================================================
    // Subset ID mapping: which 8 sets to read each cycle
    //=========================================================================
    assign ea_subset_id = (state == DC_SCAN0) ? 3'd0 :
                          (state == DC_SCAN1) ? 3'd1 :
                          (state == DC_SCAN2) ? 3'd2 :
                          (state == DC_SCAN3) ? 3'd3 : 3'd0;

    //=========================================================================
    // Per-cycle comparison (combinational)
    //=========================================================================
    // For each cycle, compare the current 8-set × 64-way subset against the request
    logic [DUPCHECK_SETS_PER-1:0][N_WAYS-1:0] way_match;  // per set, per way
    logic [DUPCHECK_SETS_PER-1:0]              set_has_match;

    // Vectorized comparison: all 512 entries of the current subset evaluated in parallel
    generate
        for (genvar s = 0; s < DUPCHECK_SETS_PER; s++) begin : gen_dc_set
            for (genvar w = 0; w < N_WAYS; w++) begin : gen_dc_way
                logic pv_eq, pv_nz;
                logic addr_masked_entry;

                assign pv_eq  = (ea_pvs[s][w] == stored_payload.pv);
                assign pv_nz  = |ea_pvs[s][w];

                assign addr_masked_entry = apply_stu_mask(ea_vas[s][w], stored_payload.stu);

                // Match = PV equal AND entry valid AND (conditional compare)
                assign way_match[s][w] = ea_valids[s][w] && pv_eq && (
                    ( pv_nz && (ea_pasids[s][w] == stored_payload.pasid)
                             && (ea_funcids[s][w] == stored_payload.func_id)
                             && (addr_masked_entry == dup_addr_masked))
                    ||
                    (!pv_nz && (ea_funcids[s][w] == stored_payload.func_id)
                             && (addr_masked_entry == dup_addr_masked))
                );
            end

            assign set_has_match[s] = |way_match[s];
        end
    endgenerate

    //=========================================================================
    // Accumulate match results per subset
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            subset_has_match <= '0;
            subset_match_idx <= '0;
            stored_payload   <= '{
                pv: '0, pasid: '0, func_id: '0,
                untranslated_addr: '0, stu: '0
            };
        end else begin
            case (state)
                DC_IDLE: begin
                    if (dup_req_valid) begin
                        stored_payload <= dup_req;
                        subset_has_match <= '0;
                        subset_match_idx <= '0;
                    end
                end

                DC_SCAN0: begin
                    subset_has_match[0] <= |set_has_match;
                    if (|set_has_match) begin
                        // Find first match index
                        for (int s = 0; s < DUPCHECK_SETS_PER; s++) begin
                            if (set_has_match[s]) begin
                                for (int w = 0; w < N_WAYS; w++) begin
                                    if (way_match[s][w]) begin
                                        subset_match_idx[0] <= {
                                            SET_IDX_W'(s), WAY_IDX_W'(w)
                                        };
                                    end
                                end
                            end
                        end
                    end
                end

                DC_SCAN1: begin
                    subset_has_match[1] <= |set_has_match;
                    if (|set_has_match) begin
                        for (int s = 0; s < DUPCHECK_SETS_PER; s++) begin
                            if (set_has_match[s]) begin
                                for (int w = 0; w < N_WAYS; w++) begin
                                    if (way_match[s][w]) begin
                                        subset_match_idx[1] <= {
                                            SET_IDX_W'(s + DUPCHECK_SETS_PER),
                                            WAY_IDX_W'(w)
                                        };
                                    end
                                end
                            end
                        end
                    end
                end

                DC_SCAN2: begin
                    subset_has_match[2] <= |set_has_match;
                    if (|set_has_match) begin
                        for (int s = 0; s < DUPCHECK_SETS_PER; s++) begin
                            if (set_has_match[s]) begin
                                for (int w = 0; w < N_WAYS; w++) begin
                                    if (way_match[s][w]) begin
                                        subset_match_idx[2] <= {
                                            SET_IDX_W'(s + 2*DUPCHECK_SETS_PER),
                                            WAY_IDX_W'(w)
                                        };
                                    end
                                end
                            end
                        end
                    end
                end

                DC_SCAN3: begin
                    subset_has_match[3] <= |set_has_match;
                    if (|set_has_match) begin
                        for (int s = 0; s < DUPCHECK_SETS_PER; s++) begin
                            if (set_has_match[s]) begin
                                for (int w = 0; w < N_WAYS; w++) begin
                                    if (way_match[s][w]) begin
                                        subset_match_idx[3] <= {
                                            SET_IDX_W'(s + 3*DUPCHECK_SETS_PER),
                                            WAY_IDX_W'(w)
                                        };
                                    end
                                end
                            end
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    //=========================================================================
    // FSM Register
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= DC_IDLE;
        end else begin
            state <= state_next;
        end
    end

endmodule : atc_dupcheck
