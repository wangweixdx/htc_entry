//=============================================================================
// atc_lookup_engine.sv — 3-stage Lookup Pipeline with TAG/SRAM split
//
// S0: Hash computation + set selection → register
// S1: TAG compare (combinational, 64-way) → hit_way → SRAM async read → register
//     SRAM data (translated_addr, perm) available same cycle
// S2: Response generation from registered SRAM data
//
// Key timing (SF4X @1GHz, 1ns cycle):
//   S0→S1 path: Tag register (50ps) + Mux (100ps) + Compare (100ps)
//             + Hit Encoder (100ps) + SRAM async (200ps) + Setup (50ps) ≈ 600ps ✓
//=============================================================================
/* verilator lint_off ENUMVALUE */
module atc_lookup_engine
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Lookup Request Input (from atc_ctrl arbiter) ----
    input  logic                         lu_req_valid,
    input  lu_request_t                  lu_req,
    output logic                         lu_req_ready,

    // ---- Lookup Response Output ----
    output logic                         lu_rsp_valid,
    output lu_response_t                 lu_rsp,

    // ---- Entry Array Interface (TAG comparison) ----
    output logic [SET_IDX_W-1:0]         ea_set_idx,
    output logic                         ea_set_en,
    output logic                         ea_cmp_en,
    output logic [PV_WIDTH-1:0]          ea_cmp_pv,
    output logic [PASID_WIDTH-1:0]       ea_cmp_pasid,
    output logic [FUNC_ID_WIDTH-1:0]     ea_cmp_func_id,
    output logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] ea_cmp_addr,

    // Comparison results (17-vector)
    input  logic [PREFETCH_COUNT-1:0][HIT_VEC_W-1:0]  ea_hit_vectors,
    input  logic [WAY_IDX_W-1:0]         ea_hit_way_idx,
    input  logic                         ea_any_hit,
    input  logic [PV_WIDTH-1:0]          ea_hit_pv,

    // ---- SRAM Data Read (async, valid same cycle as ea_any_hit) ----
    input  logic [PA_WIDTH-1:0]          sram_rd_pa,
    input  logic [PERM_WIDTH-1:0]        sram_rd_perm,

    // ---- NRU update ----
    output logic                         nru_update_en,
    output logic [WAY_IDX_W-1:0]         nru_update_way,
    output logic [NRU_HINT_W-1:0]        nru_update_val,

    // ---- Partition config ----
    input  logic [N_USER_W-1:0]          cfg_num_users
);

    //=========================================================================
    // Hash Function: set_index = (FuncID[3:0] ^ VA[15:12]) % 32
    //=========================================================================
    function automatic logic [SET_IDX_W-1:0] hash_set_idx(
        logic [FUNC_ID_WIDTH-1:0] func_id,
        logic [VA_WIDTH-1:0]      va
    );
        logic [3:0] func_low = func_id[3:0];
        logic [3:0] va_nibble = va[15:12];
        logic [4:0] hash_result;
        hash_result = {1'b0, func_low} ^ {1'b0, va_nibble};
        hash_set_idx = hash_result[SET_IDX_W-1:0];
    endfunction

    //=========================================================================
    // Pipeline Registers
    //=========================================================================
    pipe_s0_t s0_reg, s0_next;
    pipe_s1_t s1_reg, s1_next;
    pipe_s2_t s2_reg, s2_next;

    //=========================================================================
    // S1 captured data (from TAG compare + SRAM read, captured at posedge)
    //=========================================================================
    logic [PA_WIDTH-1:0]  s1_captured_pa;
    logic [PERM_WIDTH-1:0] s1_captured_perm;
    logic [PV_WIDTH-1:0]  s1_captured_pv;
    logic [WAY_IDX_W-1:0] s1_captured_way;
    logic                  s1_captured_hit;
    logic                  s1_captured_pre_hit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_captured_pa      <= '0;
            s1_captured_perm    <= '0;
            s1_captured_pv      <= '0;
            s1_captured_way     <= '0;
            s1_captured_hit     <= 1'b0;
            s1_captured_pre_hit <= 1'b0;
        end else begin
            // Capture tag compare + SRAM data at end of S0 cycle
            s1_captured_pa      <= sram_rd_pa;
            s1_captured_perm    <= sram_rd_perm;
            s1_captured_pv      <= ea_hit_pv;
            s1_captured_way     <= ea_hit_way_idx;
            s1_captured_hit     <= |ea_hit_vectors[0];  // current addr hit
            s1_captured_pre_hit <= |ea_hit_vectors[PREFETCH_COUNT-1] && !(|ea_hit_vectors[0]);
        end
    end

    //=========================================================================
    // S0: Request Dispatch + Hash
    //=========================================================================
    always_comb begin
        s0_next = '0;  // explicit zero-init for Verilator compat
        lu_req_ready = 1'b1;

        if (lu_req_valid) begin
            s0_next.valid     = 1'b1;
            s0_next.req_type  = REQ_LOOKUP;
            s0_next.set_idx   = partition_hash(cfg_num_users,
                int'(lu_req.func_id[5:0]), lu_req.func_id, lu_req.untranslated_addr);
            s0_next.lu_pv      = lu_req.pv;
            s0_next.lu_pasid   = lu_req.pasid;
            s0_next.lu_func_id = lu_req.func_id;
            s0_next.lu_va      = lu_req.untranslated_addr;
        end
    end

    //=========================================================================
    // S0 → Entry Array (TAG compare + SRAM read in one combinational path)
    //=========================================================================
    assign ea_set_idx    = s0_reg.set_idx;
    assign ea_set_en     = s0_reg.valid && (s0_reg.req_type == REQ_LOOKUP);
    assign ea_cmp_en     = s0_reg.valid && (s0_reg.req_type == REQ_LOOKUP);
    assign ea_cmp_pv     = s0_reg.lu_pv;
    assign ea_cmp_pasid  = s0_reg.lu_pasid;
    assign ea_cmp_func_id = s0_reg.lu_func_id;
    // Dispatch 17 addresses (current + 16 prefetch at 4KB steps)
    genvar aidx;
    generate
        for (aidx = 0; aidx < PREFETCH_COUNT; aidx++) begin : gen_cmp_addr
            assign ea_cmp_addr[aidx] = s0_reg.lu_va + PREFETCH_OFFSETS[aidx];
        end
    endgenerate

    //=========================================================================
    // S1: Register stage (data captured from s1_captured_*)
    //=========================================================================
    always_comb begin
        s1_next = s1_reg;
        s1_next.valid = 1'b0;

        if (s0_reg.valid && (s0_reg.req_type == REQ_LOOKUP)) begin
            s1_next.valid          = 1'b1;
            s1_next.req_type       = REQ_LOOKUP;
            s1_next.set_idx        = s0_reg.set_idx;
            s1_next.hit_vector     = ea_hit_vectors[0];
            s1_next.hit_pre_vector = ea_hit_vectors[PREFETCH_COUNT-1];
        end
    end

    //=========================================================================
    // S2: Result Collection + Response
    //=========================================================================
    always_comb begin
        s2_next = s2_reg;
        s2_next.valid = 1'b0;
        lu_rsp_valid = 1'b0;
        lu_rsp = '{
            valid: 1'b0, hit: 1'b0,
            translated_addr: '0, perm: '0,
            hit_pv: '0, pre_hit: 1'b0
        };

        if (s1_reg.valid && (s1_reg.req_type == REQ_LOOKUP)) begin
            s2_next.valid       = 1'b1;
            s2_next.req_type    = REQ_LOOKUP;
            s2_next.hit         = s1_captured_hit || s1_captured_pre_hit;
            s2_next.pre_hit     = s1_captured_pre_hit;
            s2_next.translated_addr = s1_captured_pa;
            s2_next.perm        = s1_captured_perm;
            s2_next.hit_pv      = s1_captured_pv;
            s2_next.hit_entry_idx = {s1_reg.set_idx, s1_captured_way};
        end

        if (s2_reg.valid && s2_reg.req_type == REQ_LOOKUP) begin
            lu_rsp_valid = 1'b1;
            lu_rsp.valid  = 1'b1;
            lu_rsp.hit    = s2_reg.hit;
            lu_rsp.translated_addr = s2_reg.translated_addr;
            lu_rsp.perm   = s2_reg.perm;
            lu_rsp.hit_pv = s2_reg.hit_pv;
            lu_rsp.pre_hit = s2_reg.pre_hit;
        end
    end

    //=========================================================================
    // NRU Update on Hit
    //=========================================================================
    assign nru_update_en   = s1_reg.valid && s1_captured_hit;
    assign nru_update_way  = s1_captured_way;
    assign nru_update_val  = NRU_ACTIVE;

    //=========================================================================
    // Pipeline Register Update
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_reg <= '0;
            s1_reg <= '0;
            s2_reg <= '0;
        end else begin
            s0_reg <= s0_next;
            s1_reg <= s1_next;
            s2_reg <= s2_next;
        end
    end

endmodule : atc_lookup_engine
/* verilator lint_on ENUMVALUE */
