//=============================================================================
// atc_lookup_engine.v — 4-stage Lookup Pipeline (Verilog-2001)
//
// S0: Hash computation + set selection → register
// S1: TAG compare (combinational, 64-way) → register hit results;
//     SRAM sync read issued (rd_en + addr latched by SRAM at S1 posedge)
// S2: SRAM data returns → register
// S3: Response generation from registered SRAM data
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
    output reg                      lu_req_ready,

    // ---- Lookup Response Output ----
    output reg                      lu_rsp_valid,
    output reg                      lu_rsp_hit,
    output reg [63:0]               lu_rsp_translated_addr,
    output reg [3:0]                lu_rsp_perm,
    output reg                      lu_rsp_hit_pv,
    output reg                      lu_rsp_pre_hit,
    output reg                      lu_rsp_exact_hit,
    output reg [15:0]               lu_rsp_prefetch_hit,

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

    // ---- SRAM Data Read (sync: 1-cycle latency) ----
    input  [63:0]                   sram_rd_pa,
    input  [3:0]                    sram_rd_perm,

    // ---- NRU update ----
    output                          nru_update_en,
    output [5:0]                    nru_update_way,
    output [1:0]                    nru_update_val,

    // ---- Partition config ----
    input  [2:0]                    cfg_num_users,

    // ---- Prefetch enable (per-function) ----
    input  [65:0]                   prefetch_enable
);

    //=========================================================================
    // Hash Function
    //  - prefetch_enable[func_id]=0: hash by 4KB-aligned VA (bits [15:12])
    //  - prefetch_enable[func_id]=1: hash by 64KB-aligned VA (bits [19:16])
    //    so all 17 prefetch addresses land in the same set
    //=========================================================================
    wire prefetch_en;
    assign prefetch_en = prefetch_enable[lu_req_func_id[5:0]];

    wire [63:0] hash_va;
    assign hash_va = prefetch_en ? {lu_req_va[63:20], lu_req_va[19:16],
                                      lu_req_va[19:16], lu_req_va[11:0]}
                                 : lu_req_va;

    wire [4:0] s0_set_idx;
    assign s0_set_idx = partition_hash(cfg_num_users, lu_req_func_id[5:0],
                                       lu_req_func_id, hash_va);

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
    // S1 captured data (TAG compare results only — SRAM data not ready yet)
    //=========================================================================
    reg          s1_captured_pv;
    reg [5:0]    s1_captured_way;
    reg          s1_captured_hit;
    reg [15:0]   s1_captured_prefetch_hit;
    reg          s1_captured_pre_hit;
    reg          s1_valid;
    reg [4:0]    s1_set_idx_r;

    //=========================================================================
    // S2 captured data (SRAM data arrives here)
    //=========================================================================
    reg [63:0]   s2_captured_pa;
    reg [3:0]    s2_captured_perm;
    reg          s2_hit;
    reg          s2_exact_hit;
    reg [15:0]   s2_prefetch_hit;
    reg          s2_pre_hit;
    reg          s2_hit_pv;
    reg          s2_valid;

    //=========================================================================
    // S3 captured data (result output)
    //=========================================================================
    reg         s3_valid;
    reg         s3_hit;
    reg         s3_exact_hit;
    reg [15:0]  s3_prefetch_hit;
    reg         s3_pre_hit;
    reg [63:0]  s3_translated_addr;
    reg [3:0]   s3_perm;
    reg         s3_hit_pv;

    //=========================================================================
    // S0: Request Dispatch + Hash
    //=========================================================================
    always @(*) begin
        lu_req_ready = 1'b1;
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
    assign prefetch_offsets[16] = 64'h0000_0000_0001_0000;  // 64KB

    //=========================================================================
    // S0 → Entry Array (TAG comparison in S1)
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
    // S3: Result Collection + Response
    //=========================================================================
    assign lu_rsp_valid          = s3_valid;
    assign lu_rsp_hit            = s3_hit;
    assign lu_rsp_translated_addr = s3_translated_addr;
    assign lu_rsp_perm           = s3_perm;
    assign lu_rsp_hit_pv         = s3_hit_pv;
    assign lu_rsp_pre_hit        = s3_pre_hit;
    assign lu_rsp_exact_hit      = s3_exact_hit;
    assign lu_rsp_prefetch_hit   = s3_prefetch_hit;

    //=========================================================================
    // NRU Update on Hit (based on S1 TAG compare result)
    //=========================================================================
    assign nru_update_en   = s1_valid && s1_captured_hit;
    assign nru_update_way  = s1_captured_way;
    assign nru_update_val  = `NRU_ACTIVE;

    //=========================================================================
    // Pipeline Register Update
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
            // S1 (TAG results)
            s1_captured_pv      <= 1'b0;
            s1_captured_way     <= 6'd0;
            s1_captured_hit     <= 1'b0;
            s1_captured_prefetch_hit <= 16'd0;
            s1_captured_pre_hit <= 1'b0;
            s1_valid            <= 1'b0;
            s1_set_idx_r        <= 5'd0;
            // S2 (SRAM data)
            s2_captured_pa      <= 64'd0;
            s2_captured_perm    <= 4'd0;
            s2_hit              <= 1'b0;
            s2_exact_hit        <= 1'b0;
            s2_prefetch_hit     <= 16'd0;
            s2_pre_hit          <= 1'b0;
            s2_hit_pv           <= 1'b0;
            s2_valid            <= 1'b0;
            // S3 (result)
            s3_valid            <= 1'b0;
            s3_hit              <= 1'b0;
            s3_exact_hit        <= 1'b0;
            s3_prefetch_hit     <= 16'd0;
            s3_pre_hit          <= 1'b0;
            s3_translated_addr  <= 64'd0;
            s3_perm             <= 4'd0;
            s3_hit_pv           <= 1'b0;
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

            // S1: capture TAG compare results (SRAM read issued in this cycle)
            s1_captured_pv      <= ea_hit_pv;
            s1_captured_way     <= ea_hit_way_idx;
            s1_captured_hit     <= |ea_hit_vectors[0];
            s1_captured_pre_hit <= |ea_hit_vectors[16] && !(|ea_hit_vectors[0]);
            s1_valid            <= s0_valid;
            s1_set_idx_r        <= s0_set_idx_r;
            begin
                integer pf;
                for (pf = 0; pf < 16; pf = pf + 1)
                    s1_captured_prefetch_hit[pf] <= |ea_hit_vectors[pf+1];
            end

            // S2: capture SRAM data (sync SRAM returns data here)
            s2_captured_pa      <= sram_rd_pa;
            s2_captured_perm    <= sram_rd_perm;
            s2_hit              <= s1_captured_hit;
            s2_exact_hit        <= s1_captured_hit;
            s2_prefetch_hit     <= s1_captured_prefetch_hit;
            s2_pre_hit          <= s1_captured_pre_hit;
            s2_hit_pv           <= s1_captured_pv;
            s2_valid            <= s1_valid;

            // S3: result collection
            s3_valid <= s2_valid;
            if (s2_valid) begin
                s3_hit             <= s2_hit || s2_pre_hit;
                s3_exact_hit       <= s2_exact_hit;
                s3_prefetch_hit    <= s2_prefetch_hit;
                s3_pre_hit         <= s2_pre_hit;
                s3_translated_addr <= s2_captured_pa;
                s3_perm            <= s2_captured_perm;
                s3_hit_pv          <= s2_hit_pv;
            end
        end
    end

endmodule
