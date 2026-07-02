//=============================================================================
// atc_req_arbiter.sv — Request Arbiter
// Priority: FLR > ATS Toggle > Invalidate > Insert > Relook > Lookup
//=============================================================================
module atc_req_arbiter
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- Request sources ----
    // DMA Lookup
    input  logic                         lu_req_valid,
    input  lu_request_t                  lu_req,
    output logic                         lu_req_grant,

    // ATS Completion (Insert)
    input  logic                         ins_req_valid,
    input  ats_completion_t              ins_req,
    output logic                         ins_req_grant,

    // ATS Invalidation
    input  logic                         inv_req_valid,
    input  ats_inv_req_t                 inv_req,
    output logic                         inv_req_grant,

    // ATS Toggle
    input  logic [65:0]                  ats_toggle_req,
    output logic [65:0]                  ats_toggle_grant,

    // DMA Relook (second lookup, no prefetch)
    input  logic                         rl_req_valid,
    input  lu_request_t                  rl_req,
    output logic                         rl_req_grant,

    // FLR
    input  logic                         flr_req,
    input  logic [FUNC_ID_WIDTH-1:0]     flr_func_id,
    output logic                         flr_grant,

    // ---- Selected request output ----
    output logic                         req_out_valid,
    output req_type_t                    req_out_type,
    output lu_request_t                  req_out_lu,
    output ats_completion_t              req_out_ins,
    output ats_inv_req_t                 req_out_inv,
    output logic [FUNC_ID_WIDTH-1:0]     req_out_flr_func_id,

    // ---- Flow-control ready signals (combinational) ----
    output logic                         lu_req_ready,     // DMA lookup channel ready
    output logic                         rl_req_ready,     // DMA relook channel ready
    output logic                         ins_req_ready,    // ATS completion channel ready
    output logic                         inv_req_ready,    // ATS invalidation channel ready

    // ---- Downstream busy ----
    input  logic                         downstream_busy
);

    //=========================================================================
    // Priority Arbitration (combinational)
    //
    // Priority (highest to lowest):
    //   0. FLR          — Function Level Reset
    //   1. ATS Toggle   — ATS enable/disable edge
    //   2. Invalidate   — ATS Invalidation Request from RC
    //   3. Insert       — ATS Translation Completion from RC
    //   4. Relook       — DMA second lookup (no prefetch)
    //   5. Lookup       — DMA address translation request
    //=========================================================================
    typedef enum logic [2:0] {
        SEL_FLR        = 3'd0,
        SEL_ATS_TOGGLE = 3'd1,
        SEL_INV        = 3'd2,
        SEL_INSERT     = 3'd3,
        SEL_RELOOK     = 3'd5,
        SEL_LOOKUP     = 3'd4,
        SEL_NONE       = 3'd7
    } arb_sel_t;

    arb_sel_t selected;

    always_comb begin
        selected = SEL_NONE;
        if (flr_req && !downstream_busy) begin
            selected = SEL_FLR;
        end else if (|ats_toggle_req && !downstream_busy) begin
            selected = SEL_ATS_TOGGLE;
        end else if (inv_req_valid && !downstream_busy) begin
            selected = SEL_INV;
        end else if (ins_req_valid && !downstream_busy) begin
            selected = SEL_INSERT;
        end else if (rl_req_valid && !downstream_busy) begin
            selected = SEL_RELOOK;
        end else if (lu_req_valid && !downstream_busy) begin
            selected = SEL_LOOKUP;
        end
    end

    //=========================================================================
    // Flow-control ready: channel can accept when not blocked by busy
    //=========================================================================
    assign lu_req_ready  = !downstream_busy;
    assign rl_req_ready  = !downstream_busy;
    assign ins_req_ready = !downstream_busy;
    assign inv_req_ready = !downstream_busy;

    //=========================================================================
    // Grant signals (registered to break Verilator combinational loops)
    //=========================================================================
    logic                         flr_grant_comb; logic [65:0] ats_toggle_grant_comb;
    logic                         inv_req_grant_comb, ins_req_grant_comb, rl_req_grant_comb, lu_req_grant_comb;
    logic                         req_out_valid_comb;
    req_type_t                    req_out_type_comb;
    lu_request_t                  req_out_lu_comb;
    ats_completion_t              req_out_ins_comb;
    ats_inv_req_t                 req_out_inv_comb;
    logic [FUNC_ID_WIDTH-1:0]     req_out_flr_func_id_comb;

    assign flr_grant_comb           = (selected == SEL_FLR);
    assign ats_toggle_grant_comb = (selected == SEL_ATS_TOGGLE) ? ats_toggle_req : '0;
    assign inv_req_grant_comb       = (selected == SEL_INV);
    assign ins_req_grant_comb       = (selected == SEL_INSERT);
    assign lu_req_grant_comb        = (selected == SEL_LOOKUP);
    assign rl_req_grant_comb        = (selected == SEL_RELOOK);

    assign req_out_valid_comb       = (selected != SEL_NONE);
    assign req_out_type_comb        = (selected == SEL_FLR)        ? REQ_FLR :
                                      (selected == SEL_ATS_TOGGLE) ? REQ_ATS_TOGGLE :
                                      (selected == SEL_INV)        ? REQ_INVALIDATE :
                                      (selected == SEL_INSERT)     ? REQ_INSERT :
                                      (selected == SEL_RELOOK)     ? REQ_RELOOK :
                                                                     REQ_LOOKUP;
    assign req_out_lu_comb           = lu_req;
    assign req_out_ins_comb          = ins_req;
    assign req_out_inv_comb          = inv_req;
    assign req_out_flr_func_id_comb  = flr_func_id;

    // Register stage: captures grant at posedge, 1 cycle latency
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flr_grant           <= 1'b0;
            ats_toggle_grant    <= '0;
            inv_req_grant       <= 1'b0;
            ins_req_grant       <= 1'b0;
            rl_req_grant        <= 1'b0;
            lu_req_grant        <= 1'b0;
            req_out_valid       <= 1'b0;
            req_out_type        <= REQ_LOOKUP;
            req_out_lu          <= '0;
            req_out_ins         <= '0;
            req_out_inv         <= '0;
            req_out_flr_func_id <= '0;
        end else begin
            flr_grant           <= flr_grant_comb;
            ats_toggle_grant    <= ats_toggle_grant_comb;
            inv_req_grant       <= inv_req_grant_comb;
            ins_req_grant       <= ins_req_grant_comb;
            rl_req_grant        <= rl_req_grant_comb;
            lu_req_grant        <= lu_req_grant_comb;
            req_out_valid       <= req_out_valid_comb;
            req_out_type        <= req_out_type_comb;
            req_out_lu          <= req_out_lu_comb;
            req_out_ins         <= req_out_ins_comb;
            req_out_inv         <= req_out_inv_comb;
            req_out_flr_func_id <= req_out_flr_func_id_comb;
        end
    end

endmodule : atc_req_arbiter
