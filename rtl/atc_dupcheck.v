//=============================================================================
// atc_dupcheck.v — Address Duplicate Check (Verilog-2001)
// 4-cycle full traversal of 2048 entries to detect duplicate addresses.
//=============================================================================
`include "atc_defines.vh"

module atc_dupcheck (
    input                           clk,
    input                           rst_n,

    // ---- Duplicate check request ----
    input                           dup_req_valid,
    input                           dup_req_pv,
    input  [19:0]                   dup_req_pasid,
    input  [15:0]                   dup_req_func_id,
    input  [63:0]                   dup_req_va,
    input  [4:0]                    dup_req_stu,
    output reg                      dup_req_ready,

    // ---- Duplicate check result ----
    output reg                      dup_rsp_valid,
    output reg                      duplicate,
    output reg [10:0]               dup_entry_idx,

    // ---- Entry Array Interface (wide read of subset: 8 sets × 64 ways) ----
    output [2:0]                    ea_subset_id,
    input  [7:0][63:0]              ea_valids,
    input  [7:0][63:0]              ea_pvs,
    input  [7:0][63:0][19:0]        ea_pasids,
    input  [7:0][63:0][15:0]        ea_funcids,
    input  [7:0][63:0][63:0]        ea_vas,
    input  [7:0][63:0][4:0]         ea_stus
);

    //=========================================================================
    // FSM: IDLE → SCAN[0..3] → RESULT
    //=========================================================================
    reg [2:0] state, state_next;

    // Stored request
    reg         stored_pv;
    reg [19:0]  stored_pasid;
    reg [15:0]  stored_func_id;
    reg [63:0]  stored_va;
    reg [4:0]   stored_stu;
    reg         busy;

    // Per-subset match accumulation
    reg [3:0]                       subset_has_match;
    reg [3:0][10:0]                 subset_match_idx;

    // Masked lookup address
    wire [63:0] dup_addr_masked;
    assign dup_addr_masked = apply_stu_mask(stored_va, stored_stu);

    always @(*) begin
        state_next = state;
        dup_req_ready = 1'b0;
        dup_rsp_valid = 1'b0;
        duplicate = 1'b0;
        dup_entry_idx = 11'd0;

        case (state)
            `DC_IDLE: begin
                dup_req_ready = 1'b1;
                if (dup_req_valid) begin
                    state_next = `DC_SCAN0;
                end
            end

            `DC_SCAN0: state_next = `DC_SCAN1;
            `DC_SCAN1: state_next = `DC_SCAN2;
            `DC_SCAN2: state_next = `DC_SCAN3;
            `DC_SCAN3: state_next = `DC_RESULT;

            `DC_RESULT: begin
                dup_rsp_valid = 1'b1;
                duplicate = |subset_has_match;
                if (subset_has_match[0])      dup_entry_idx = subset_match_idx[0];
                else if (subset_has_match[1]) dup_entry_idx = subset_match_idx[1];
                else if (subset_has_match[2]) dup_entry_idx = subset_match_idx[2];
                else                          dup_entry_idx = subset_match_idx[3];
                state_next = `DC_IDLE;
            end

            default: state_next = `DC_IDLE;
        endcase
    end

    //=========================================================================
    // Subset ID mapping
    //=========================================================================
    assign ea_subset_id = (state == `DC_SCAN0) ? 3'd0 :
                          (state == `DC_SCAN1) ? 3'd1 :
                          (state == `DC_SCAN2) ? 3'd2 :
                          (state == `DC_SCAN3) ? 3'd3 : 3'd0;

    //=========================================================================
    // Per-cycle comparison (combinational) — all 512 entries in parallel
    //=========================================================================
    wire [7:0][63:0] way_match;    // per set, per way
    wire [7:0]       set_has_match;
    wire [511:0]     way_match_flat; // flat for iverilog procedural access

    genvar s, w;
    generate
        for (s = 0; s < 8; s = s + 1) begin : gen_dc_set
            for (w = 0; w < 64; w = w + 1) begin : gen_dc_way
                wire pv_eq, pv_nz;
                wire [63:0] addr_masked_entry;

                assign pv_eq  = (ea_pvs[s][w] == stored_pv);
                assign pv_nz  = |ea_pvs[s][w];

                assign addr_masked_entry = apply_stu_mask(ea_vas[s][w], stored_stu);

                assign way_match[s][w] = ea_valids[s][w] && pv_eq && (
                    ( pv_nz && (ea_pasids[s][w] == stored_pasid)
                             && (ea_funcids[s][w] == stored_func_id)
                             && (addr_masked_entry == dup_addr_masked))
                    ||
                    (!pv_nz && (ea_funcids[s][w] == stored_func_id)
                             && (addr_masked_entry == dup_addr_masked))
                );
                assign way_match_flat[s*64 + w] = way_match[s][w];
            end

            assign set_has_match[s] = |way_match[s];
        end
    endgenerate

    //=========================================================================
    // Accumulate match results per subset
    //=========================================================================
    integer s_idx, w_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            subset_has_match <= 4'd0;
            subset_match_idx <= 44'd0;  // 4 × 11b
            stored_pv        <= 1'b0;
            stored_pasid     <= 20'd0;
            stored_func_id   <= 16'd0;
            stored_va        <= 64'd0;
            stored_stu       <= 5'd0;
        end else begin
            case (state)
                `DC_IDLE: begin
                    if (dup_req_valid) begin
                        stored_pv        <= dup_req_pv;
                        stored_pasid     <= dup_req_pasid;
                        stored_func_id   <= dup_req_func_id;
                        stored_va        <= dup_req_va;
                        stored_stu       <= dup_req_stu;
                        subset_has_match <= 4'd0;
                        subset_match_idx <= 44'd0;
                    end
                end

                `DC_SCAN0: begin
                    subset_has_match[0] <= |set_has_match;
                    if (|set_has_match) begin
                        for (s_idx = 0; s_idx < 8; s_idx = s_idx + 1) begin
                            if (set_has_match[s_idx]) begin
                                for (w_idx = 0; w_idx < 64; w_idx = w_idx + 1) begin
                                    if (way_match_flat[s_idx*64 + w_idx]) begin
                                        subset_match_idx[0] <= {s_idx[4:0], w_idx[5:0]};
                                    end
                                end
                            end
                        end
                    end
                end

                `DC_SCAN1: begin
                    subset_has_match[1] <= |set_has_match;
                    if (|set_has_match) begin
                        for (s_idx = 0; s_idx < 8; s_idx = s_idx + 1) begin
                            if (set_has_match[s_idx]) begin
                                for (w_idx = 0; w_idx < 64; w_idx = w_idx + 1) begin
                                    if (way_match_flat[s_idx*64 + w_idx]) begin
                                        subset_match_idx[1] <= {s_idx[4:0] + 5'd8, w_idx[5:0]};
                                    end
                                end
                            end
                        end
                    end
                end

                `DC_SCAN2: begin
                    subset_has_match[2] <= |set_has_match;
                    if (|set_has_match) begin
                        for (s_idx = 0; s_idx < 8; s_idx = s_idx + 1) begin
                            if (set_has_match[s_idx]) begin
                                for (w_idx = 0; w_idx < 64; w_idx = w_idx + 1) begin
                                    if (way_match_flat[s_idx*64 + w_idx]) begin
                                        subset_match_idx[2] <= {s_idx[4:0] + 5'd16, w_idx[5:0]};
                                    end
                                end
                            end
                        end
                    end
                end

                `DC_SCAN3: begin
                    subset_has_match[3] <= |set_has_match;
                    if (|set_has_match) begin
                        for (s_idx = 0; s_idx < 8; s_idx = s_idx + 1) begin
                            if (set_has_match[s_idx]) begin
                                for (w_idx = 0; w_idx < 64; w_idx = w_idx + 1) begin
                                    if (way_match_flat[s_idx*64 + w_idx]) begin
                                        subset_match_idx[3] <= {s_idx[4:0] + 5'd24, w_idx[5:0]};
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= `DC_IDLE;
        end else begin
            state <= state_next;
        end
    end

endmodule
