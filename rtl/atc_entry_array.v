//=============================================================================
// atc_entry_array.v — 2048-entry array: 32 × atc_set + 1 × atc_data_sram (Verilog-2001)
//
// TAG storage:  2048 × 107b in register-based atc_entry_tag (inside atc_set)
// DATA storage: 2048 ×  68b in atc_data_sram
// NRU storage:  2048 ×   2b in register-based atc_nru_replacer (inside atc_set)
//=============================================================================
`include "atc_defines.vh"

module atc_entry_array (
    input                           clk,
    input                           rst_n,

    // ---- Set select ----
    input  [4:0]                    sel_set_idx,
    input                           sel_set_en,

    // ---- Tag write port ----
    input                           wr_en,
    input  [4:0]                    wr_set_idx,
    input  [5:0]                    wr_way_idx,
    input                           wr_valid,
    input                           wr_pv,
    input  [19:0]                   wr_pasid,
    input  [15:0]                   wr_func_id,
    input  [63:0]                   wr_va,
    input  [4:0]                    wr_stu,

    // ---- SRAM data write port ----
    input                           sram_wr_en,
    input  [10:0]                   sram_wr_addr,
    input  [63:0]                   sram_wr_pa,
    input  [3:0]                    sram_wr_perm,

    // ---- Comparison port ----
    input                           cmp_en,
    input                           cmp_inv_mode,
    input                           cmp_pv,
    input  [19:0]                   cmp_pasid,
    input  [15:0]                   cmp_func_id,
    input  [16:0][63:0]             cmp_addr,

    // ---- Comparison results (from selected set) ----
    output [16:0][63:0]             hit_vectors,
    output [5:0]                    hit_way_idx,
    output                          any_hit,
    output                          hit_pv,

    // ---- SRAM read port (async) ----
    output [63:0]                   sram_rd_pa,
    output [3:0]                    sram_rd_perm,

    // ---- NRU victim selection (from selected set) ----
    input                           victim_sel_en,
    output [5:0]                    victim_way,
    output                          victim_valid,

    // ---- NRU update (to selected set) ----
    input                           nru_update_en,
    input  [5:0]                    nru_update_way,
    input  [1:0]                    nru_update_val,
    input                           nru_clear_all_used,
    input                           nru_decay_tick,
    input  [6:0]                    nru_way_base,
    input  [6:0]                    nru_way_limit,

    // ---- Invalidation ----
    input                           inv_en,
    input  [5:0]                    inv_way_idx,

    // ---- DupCheck: full traversal read (all sets, all ways) ----
    input  [2:0]                    dupcheck_subset_id,
    output [7:0][63:0]              dupcheck_valids,
    output [7:0][63:0]              dupcheck_pvs,
    output [7:0][63:0][19:0]        dupcheck_pasids,
    output [7:0][63:0][15:0]        dupcheck_funcids,
    output [7:0][63:0][63:0]        dupcheck_vas,
    output [7:0][63:0][4:0]         dupcheck_stus,

    // ---- Batch Clear (ATS Toggle / FLR) ----
    input                           batch_clr_en,
    input  [15:0]                   batch_clr_func_id,
    input                           batch_clr_all
);

    //=========================================================================
    // Decoded signals per set
    //=========================================================================
    wire [31:0] set_wr_en;
    wire [31:0] set_cmp_en;
    wire [31:0] set_victim_sel_en;
    wire [31:0] set_nru_update_en;
    wire [31:0] set_inv_en;

    // Collected outputs per set
    wire [31:0][16:0][63:0]    set_hit_vectors;
    wire [31:0][5:0]            set_hit_way_idxs;
    wire [31:0]                 set_any_hits;
    wire [31:0]                 set_hit_pvs;
    wire [31:0][63:0]           set_all_pvs;
    wire [31:0][63:0][19:0]     set_all_pasids;
    wire [31:0][63:0][15:0]     set_all_funcids;
    wire [31:0][63:0][63:0]     set_all_vas;
    wire [31:0][63:0][4:0]      set_all_stus;
    wire [31:0][63:0]           set_all_valids;
    wire [31:0][5:0]            set_victim_ways;
    wire [31:0]                 set_victim_valids;

    // SRAM read from each set
    wire [31:0]                 set_sram_rd_en;
    wire [31:0][10:0]           set_sram_rd_addr;

    // Batch clear
    wire [31:0]                 set_batch_clr;
    wire [31:0][5:0]            batch_clr_way_idx;
    wire [31:0][63:0]           batch_clr_func_match;

    // Batch clear way counter
    reg [5:0] batch_clr_way_counter;

    //=========================================================================
    // Generate 32 atc_set instances
    //=========================================================================
    genvar s;
    generate
        for (s = 0; s < 32; s = s + 1) begin : gen_set

            assign set_wr_en[s]         = wr_en && (wr_set_idx == s[4:0]);
            assign set_cmp_en[s]        = cmp_en && sel_set_en
                                          && (sel_set_idx == s[4:0]);
            assign set_victim_sel_en[s] = victim_sel_en && (sel_set_idx == s[4:0]);
            assign set_nru_update_en[s] = nru_update_en && (sel_set_idx == s[4:0]);
            assign set_inv_en[s]        = inv_en && (sel_set_idx == s[4:0]);

            atc_set u_set (
                .clk                (clk),
                .rst_n              (rst_n),
                .my_set_idx         (s[4:0]),
                .wr_en              (set_wr_en[s] || set_batch_clr[s]),
                .wr_way             (batch_clr_en ? batch_clr_way_idx[s] : wr_way_idx),
                .wr_valid           (set_batch_clr[s] ? 1'b0  : wr_valid),
                .wr_pv              (set_batch_clr[s] ? 1'b0  : wr_pv),
                .wr_pasid           (set_batch_clr[s] ? 20'd0 : wr_pasid),
                .wr_func_id         (set_batch_clr[s] ? 16'd0 : wr_func_id),
                .wr_va              (set_batch_clr[s] ? 64'd0 : wr_va),
                .wr_stu             (set_batch_clr[s] ? 5'd0  : wr_stu),
                .cmp_en             (set_cmp_en[s]),
                .cmp_inv_mode       (cmp_inv_mode),
                .cmp_pv             (cmp_pv),
                .cmp_pasid          (cmp_pasid),
                .cmp_func_id        (cmp_func_id),
                .cmp_addr           (cmp_addr),
                .hit_vectors        (set_hit_vectors[s]),
                .hit_way_idx        (set_hit_way_idxs[s]),
                .any_hit            (set_any_hits[s]),
                .hit_pv             (set_hit_pvs[s]),
                .all_pvs            (set_all_pvs[s]),
                .all_pasids         (set_all_pasids[s]),
                .all_funcids        (set_all_funcids[s]),
                .all_vas            (set_all_vas[s]),
                .all_stus           (set_all_stus[s]),
                .all_valids         (set_all_valids[s]),
                .sram_rd_en         (set_sram_rd_en[s]),
                .sram_rd_addr       (set_sram_rd_addr[s]),
                .victim_sel_en      (set_victim_sel_en[s]),
                .victim_way         (set_victim_ways[s]),
                .victim_valid       (set_victim_valids[s]),
                .nru_update_en      (set_nru_update_en[s]),
                .nru_update_way     (nru_update_way),
                .nru_update_val     (nru_update_val),
                .nru_clear_all_used (nru_clear_all_used && (sel_set_idx == s[4:0])),
                .nru_decay_tick     (nru_decay_tick),
                .nru_way_base       (nru_way_base),
                .nru_way_limit      (nru_way_limit),
                .inv_way_en         (set_inv_en[s]),
                .inv_way_idx        (inv_way_idx)
            );

            assign batch_clr_way_idx[s] = batch_clr_way_counter;

            // FLR func_id matching: compare each way's func_id
            genvar wf;
            for (wf = 0; wf < 64; wf = wf + 1) begin : gen_flr_match
                assign batch_clr_func_match[s][wf] = batch_clr_en && !batch_clr_all &&
                    (set_all_funcids[s][wf] == batch_clr_func_id);
            end

            assign set_batch_clr[s] = batch_clr_en &&
                (batch_clr_all || batch_clr_func_match[s][batch_clr_way_idx[s]]);
        end
    endgenerate

    //=========================================================================
    // Batch clear way counter FSM
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            batch_clr_way_counter <= 6'd0;
        end else if (batch_clr_en) begin
            batch_clr_way_counter <= batch_clr_way_counter + 6'd1;
        end else begin
            batch_clr_way_counter <= 6'd0;
        end
    end

    //=========================================================================
    // Output Mux: select results from the targeted set
    //=========================================================================
    assign hit_vectors  = set_hit_vectors[sel_set_idx];
    assign hit_way_idx    = set_hit_way_idxs[sel_set_idx];
    assign any_hit        = set_any_hits[sel_set_idx];
    assign hit_pv         = set_hit_pvs[sel_set_idx];
    assign victim_way     = set_victim_ways[sel_set_idx];
    assign victim_valid   = set_victim_valids[sel_set_idx];

    //=========================================================================
    // Data SRAM: 2048 words × 68 bits, async read
    //=========================================================================
    wire                        sram_rd_en_muxed;
    wire [10:0]                 sram_rd_addr_muxed;

    assign sram_rd_en_muxed   = set_sram_rd_en[sel_set_idx];
    assign sram_rd_addr_muxed = set_sram_rd_addr[sel_set_idx];

    atc_data_sram u_data_sram (
        .clk                 (clk),
        .rst_n               (rst_n),
        .rd_en               (sram_rd_en_muxed),
        .rd_addr             (sram_rd_addr_muxed),
        .rd_translated_addr  (sram_rd_pa),
        .rd_perm             (sram_rd_perm),
        .wr_en               (sram_wr_en),
        .wr_addr             (sram_wr_addr),
        .wr_translated_addr  (sram_wr_pa),
        .wr_perm             (sram_wr_perm)
    );

    //=========================================================================
    // DupCheck Output: route the right 8-set subset
    //=========================================================================
    genvar d;
    generate
        for (d = 0; d < 8; d = d + 1) begin : gen_dc_route
            assign dupcheck_valids[d]   = set_all_valids[d + dupcheck_subset_id * 8];
            assign dupcheck_pvs[d]      = set_all_pvs[d + dupcheck_subset_id * 8];
            assign dupcheck_pasids[d]   = set_all_pasids[d + dupcheck_subset_id * 8];
            assign dupcheck_funcids[d]  = set_all_funcids[d + dupcheck_subset_id * 8];
            assign dupcheck_vas[d]      = set_all_vas[d + dupcheck_subset_id * 8];
            assign dupcheck_stus[d]     = set_all_stus[d + dupcheck_subset_id * 8];
        end
    endgenerate

endmodule
