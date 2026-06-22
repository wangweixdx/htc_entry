//=============================================================================
// atc_lookup_engine.v — 3-stage Lookup Pipeline (Verilog-2001)
//
// S0: Hash computation + set selection → register
// S1: TAG compare (combinational, 64-way) → hit_way → SRAM async read → register
// S2: Response generation from registered SRAM data
//=============================================================================
`include "atc_defines.vh"

module atc_lookup_engine (
    input                           clk,
    input                           rst_n,

    // ---- Lookup Request Input ----
    input                           lu_req_valid,
    input                           lu_req_pv,
    input  [19:0]                   lu_req_pasid,
    input  [15:0]                   lu_req_func_id,
    input  [63:0]                   lu_req_va,
    output                          lu_req_ready,

    // ---- Lookup Response Output ----
    output                          lu_rsp_valid,
    output                          lu_rsp_hit,
    output [63:0]                   lu_rsp_translated_addr,
    output [3:0]                    lu_rsp_perm,
    output                          lu_rsp_hit_pv,
    output                          lu_rsp_pre_hit,

    // ---- Entry Array Interface (TAG comparison) ----
    output [4:0]                    ea_set_idx,
    output                          ea_set_en,
    output                          ea_cmp_en,
    output                          ea_cmp_pv,
    output [19:0]                   ea_cmp_pasid,
    output [15:0]                   ea_cmp_func_id,
    output [16:0][63:0]             ea_cmp_addr,

    // Comparison results (17-vector)
    input  [16:0][63:0]             ea_hit_vectors,
    input  [5:0]                    ea_hit_way_idx,
    input                           ea_any_hit,
    input                           ea_hit_pv,

    // ---- SRAM Data Read (async) ----
    input  [63:0]                   sram_rd_pa,
    input  [3:0]                    sram_rd_perm,

    // ---- NRU update ----
    output                          nru_update_en,
    output [5:0]                    nru_update_way,
    output [1:0]                    nru_update_val,

    // ---- Partition config ----
    input  [2:0]                    cfg_num_users
);

    //=========================================================================
    // Hash Function (local)
    //=========================================================================
    wire [4:0] hash_result;
    assign hash_result = {1'b0, lu_req_func_id[3:0]} ^ {1'b0, lu_req_va[15:12]};

    wire [4:0] s0_set_idx;
    // partition_hash call — approximated with a generate or local function
    // For simplicity, use the partition_hash function from the defines include;
    // if synthesis tools don't support function calls in port maps, unroll here.
    assign s0_set_idx = partition_hash(cfg_num_users, lu_req_func_id[5:0], lu_req_func_id, lu_req_va);

    //=========================================================================
    // Pipeline Registers — S0
    //=========================================================================
    reg         s0_valid;
    reg [4:0]   s0_set_idx_r;
    reg         s0_lu_pv;
    reg [19:0]  s0_lu_pasid;
    reg [15:0]  s0_lu_func_id;
    reg [63:0]  s0_lu_va;

    //=========================================================================
    // S1 captured data (from TAG compare + SRAM read)
    //=========================================================================
    reg [63:0]   s1_captured_pa;
    reg [3:0]    s1_captured_perm;
    reg          s1_captured_pv;
    reg [5:0]    s1_captured_way;
    reg          s1_captured_hit;
    reg          s1_captured_pre_hit;
    reg          s1_valid;
    reg [4:0]    s1_set_idx_r;

    //=========================================================================
    // S2 captured data
    //=========================================================================
    reg         s2_valid;
    reg         s2_hit;
    reg         s2_pre_hit;
    reg [63:0]  s2_translated_addr;
    reg [3:0]   s2_perm;
    reg         s2_hit_pv;

    //=========================================================================
    // S0: Request Dispatch + Hash
    //=========================================================================
    always @(*) begin
        lu_req_ready = 1'b1;
        if (lu_req_valid) begin
            // S0 register will capture
        end
    end

    // Prefetch offset table
    wire [63:0] prefetch_offsets [0:16];
    assign prefetch_offsets[0]  = 64'h0000_0000_0000_0000;
    assign prefetch_offsets[1]  = 64'h0000_0000_0000_1000;
    assign prefetch_offsets[2]  = 64'h0000_0000_0000_2000;
    assign prefetch_offsets[3]  = 64'h0000_0000_0000_3000;
    assign prefetch_offsets[4]  = 64'h0000_0000_0000_4000;
    assign prefetch_offsets[5]  = 64'h0000_0000_0000_5000;
    assign prefetch_offsets[6]  = 64'h0000_0000_0000_6000;
    assign prefetch_offsets[7]  = 64'h0000_0000_0000_7000;
    assign prefetch_offsets[8]  = 64'h0000_0000_0000_8000;
    assign prefetch_offsets[9]  = 64'h0000_0000_0000_9000;
    assign prefetch_offsets[10] = 64'h0000_0000_0000_A000;
    assign prefetch_offsets[11] = 64'h0000_0000_0000_B000;
    assign prefetch_offsets[12] = 64'h0000_0000_0000_C000;
    assign prefetch_offsets[13] = 64'h0000_0000_0000_D000;
    assign prefetch_offsets[14] = 64'h0000_0000_0000_E000;
    assign prefetch_offsets[15] = 64'h0000_0000_0000_F000;
    assign prefetch_offsets[16] = 64'h0000_0001_0000_0000;

    //=========================================================================
    // S0 → Entry Array (TAG compare + SRAM read in one combinational path)
    //=========================================================================
    assign ea_set_idx    = s0_set_idx_r;
    assign ea_set_en     = s0_valid;
    assign ea_cmp_en     = s0_valid;
    assign ea_cmp_pv     = s0_lu_pv;
    assign ea_cmp_pasid  = s0_lu_pasid;
    assign ea_cmp_func_id = s0_lu_func_id;

    genvar aidx;
    generate
        for (aidx = 0; aidx < 17; aidx = aidx + 1) begin : gen_cmp_addr
            assign ea_cmp_addr[aidx] = s0_lu_va + prefetch_offsets[aidx];
        end
    endgenerate

    //=========================================================================
    // S2: Result Collection + Response
    //=========================================================================
    assign lu_rsp_valid          = s2_valid;
    assign lu_rsp_hit            = s2_hit;
    assign lu_rsp_translated_addr = s2_translated_addr;
    assign lu_rsp_perm           = s2_perm;
    assign lu_rsp_hit_pv         = s2_hit_pv;
    assign lu_rsp_pre_hit        = s2_pre_hit;

    //=========================================================================
    // NRU Update on Hit
    //=========================================================================
    assign nru_update_en   = s1_valid && s1_captured_hit;
    assign nru_update_way  = s1_captured_way;
    assign nru_update_val  = `NRU_ACTIVE;

    //=========================================================================
    // Pipeline Register Update (posedge clock)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // S0
            s0_valid       <= 1'b0;
            s0_set_idx_r   <= 5'd0;
            s0_lu_pv       <= 1'b0;
            s0_lu_pasid    <= 20'd0;
            s0_lu_func_id  <= 16'd0;
            s0_lu_va       <= 64'd0;
            // S1 captured
            s1_captured_pa      <= 64'd0;
            s1_captured_perm    <= 4'd0;
            s1_captured_pv      <= 1'b0;
            s1_captured_way     <= 6'd0;
            s1_captured_hit     <= 1'b0;
            s1_captured_pre_hit <= 1'b0;
            s1_valid            <= 1'b0;
            s1_set_idx_r        <= 5'd0;
            // S2
            s2_valid            <= 1'b0;
            s2_hit              <= 1'b0;
            s2_pre_hit          <= 1'b0;
            s2_translated_addr  <= 64'd0;
            s2_perm             <= 4'd0;
            s2_hit_pv           <= 1'b0;
        end else begin
            // S0: capture request
            if (lu_req_valid) begin
                s0_valid      <= 1'b1;
                s0_set_idx_r  <= s0_set_idx;
                s0_lu_pv      <= lu_req_pv;
                s0_lu_pasid   <= lu_req_pasid;
                s0_lu_func_id <= lu_req_func_id;
                s0_lu_va      <= lu_req_va;
            end else begin
                s0_valid <= 1'b0;
            end

            // S1: capture TAG compare + SRAM data
            s1_captured_pa      <= sram_rd_pa;
            s1_captured_perm    <= sram_rd_perm;
            s1_captured_pv      <= ea_hit_pv;
            s1_captured_way     <= ea_hit_way_idx;
            s1_captured_hit     <= |ea_hit_vectors[0];
            s1_captured_pre_hit <= |ea_hit_vectors[16] && !(|ea_hit_vectors[0]);
            s1_valid            <= s0_valid;
            s1_set_idx_r        <= s0_set_idx_r;

            // S2: result collection
            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_hit             <= s1_captured_hit || s1_captured_pre_hit;
                s2_pre_hit         <= s1_captured_pre_hit;
                s2_translated_addr <= s1_captured_pa;
                s2_perm            <= s1_captured_perm;
                s2_hit_pv          <= s1_captured_pv;
            end
        end
    end

endmodule
