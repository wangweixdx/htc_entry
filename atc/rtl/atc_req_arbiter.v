//=============================================================================
// atc_req_arbiter.v — Request Arbiter (Verilog-2001)
// Priority: FLR > ATS Toggle > Invalidate > Insert > Relook > Lookup
//=============================================================================
`include "atc_defines.vh"

module atc_req_arbiter (
    input                           clk,
    input                           rst_n,

    // ---- Request sources ----
    input                           lu_req_valid,
    input                           lu_req_pv,
    input  [19:0]                   lu_req_pasid,
    input  [15:0]                   lu_req_func_id,
    input  [63:0]                   lu_req_va,
    output                          lu_req_grant,

    input                           ins_req_valid,
    input                           ins_req_pv,
    input  [19:0]                   ins_req_pasid,
    input  [15:0]                   ins_req_func_id,
    input  [63:0]                   ins_req_va,
    input  [63:0]                   ins_req_pa,
    input  [4:0]                    ins_req_stu,
    input  [3:0]                    ins_req_perm,
    output                          ins_req_grant,

    input                           inv_req_valid,
    input  [15:0]                   inv_req_mask,
    input                           inv_req_pv_valid,
    input                           inv_req_pv,
    input  [19:0]                   inv_req_pasid,
    input  [15:0]                   inv_req_func_id,
    input  [63:0]                   inv_req_va,
    output                          inv_req_grant,

    input  [65:0]                   ats_toggle_req,
    output [65:0]                   ats_toggle_grant,

    input                           rl_req_valid,
    input                           rl_req_pv,
    input  [19:0]                   rl_req_pasid,
    input  [15:0]                   rl_req_func_id,
    input  [63:0]                   rl_req_va,
    output                          rl_req_grant,
    output                          rl_req_data_pv,
    output [19:0]                   rl_req_data_pasid,
    output [15:0]                   rl_req_data_func_id,
    output [63:0]                   rl_req_data_va,

    input                           flr_req,
    input  [15:0]                   flr_func_id,
    output                          flr_grant,

    // ---- Selected request output ----
    output                          req_out_valid,
    output [2:0]                    req_out_type,
    output                          req_out_lu_pv,
    output [19:0]                   req_out_lu_pasid,
    output [15:0]                   req_out_lu_func_id,
    output [63:0]                   req_out_lu_va,
    output                          req_out_ins_pv,
    output [19:0]                   req_out_ins_pasid,
    output [15:0]                   req_out_ins_func_id,
    output [63:0]                   req_out_ins_va,
    output [63:0]                   req_out_ins_pa,
    output [4:0]                    req_out_ins_stu,
    output [3:0]                    req_out_ins_perm,
    output [15:0]                   req_out_inv_mask,
    output                          req_out_inv_pv_valid,
    output                          req_out_inv_pv,
    output [19:0]                   req_out_inv_pasid,
    output [15:0]                   req_out_inv_func_id,
    output [63:0]                   req_out_inv_va,
    output [15:0]                   req_out_flr_func_id,

    // ---- Flow-control ready signals ----
    output                          lu_req_ready,
    output                          rl_req_ready,
    output                          ins_req_ready,
    output                          inv_req_ready,

    // ---- Downstream busy ----
    input                           downstream_busy
);

    //=========================================================================
    // Priority Arbitration (combinational)
    //=========================================================================
    reg [2:0] selected;

    always @(*) begin
        selected = `SEL_NONE;
        if (flr_req && !downstream_busy) begin
            selected = `SEL_FLR;
        end else if (|ats_toggle_req && !downstream_busy) begin
            selected = `SEL_ATS_TOGGLE;
        end else if (inv_req_valid && !downstream_busy) begin
            selected = `SEL_INV;
        end else if (ins_req_valid && !downstream_busy) begin
            selected = `SEL_INSERT;
        end else if (rl_req_valid && !downstream_busy) begin
            selected = `SEL_RELOOK;
        end else if (lu_req_valid && !downstream_busy) begin
            selected = `SEL_LOOKUP;
        end
    end

    //=========================================================================
    // Flow-control ready — gated by higher-priority requests
    // A lower-priority channel must deassert ready when a higher-priority
    // request is active, so the requester holds data until granted.
    //=========================================================================
    assign lu_req_ready  = !downstream_busy && !flr_req && !(|ats_toggle_req)
                           && !inv_req_valid && !ins_req_valid && !rl_req_valid;
    assign rl_req_ready  = !downstream_busy && !flr_req && !(|ats_toggle_req)
                           && !inv_req_valid && !ins_req_valid;
    assign ins_req_ready = !downstream_busy && !flr_req && !(|ats_toggle_req)
                           && !inv_req_valid;
    assign inv_req_ready = !downstream_busy && !flr_req && !(|ats_toggle_req);

    //=========================================================================
    // Grant signals (combinational)
    //=========================================================================
    wire                         flr_grant_comb;
    wire [65:0]                  ats_toggle_grant_comb;
    wire                         inv_req_grant_comb, ins_req_grant_comb;
    wire                         rl_req_grant_comb, lu_req_grant_comb;
    wire                         req_out_valid_comb;
    wire [2:0]                   req_out_type_comb;
    wire [15:0]                  req_out_flr_func_id_comb;

    assign flr_grant_comb           = (selected == `SEL_FLR);
    assign ats_toggle_grant_comb    = (selected == `SEL_ATS_TOGGLE) ? ats_toggle_req : 66'd0;
    assign inv_req_grant_comb       = (selected == `SEL_INV);
    assign ins_req_grant_comb       = (selected == `SEL_INSERT);
    assign lu_req_grant_comb        = (selected == `SEL_LOOKUP);
    assign rl_req_grant_comb        = (selected == `SEL_RELOOK);

    assign req_out_valid_comb       = (selected != `SEL_NONE);
    assign req_out_type_comb        = (selected == `SEL_FLR)        ? `REQ_FLR :
                                      (selected == `SEL_ATS_TOGGLE) ? `REQ_ATS_TOGGLE :
                                      (selected == `SEL_INV)        ? `REQ_INVALIDATE :
                                      (selected == `SEL_INSERT)     ? `REQ_INSERT :
                                      (selected == `SEL_RELOOK)     ? `REQ_RELOOK :
                                                                      `REQ_LOOKUP;
    assign req_out_flr_func_id_comb  = flr_func_id;

    //=========================================================================
    // Register stage: captures grant at posedge, 1 cycle latency
    //=========================================================================
    reg                         flr_grant_r, inv_req_grant_r, ins_req_grant_r;
    reg                         rl_req_grant_r, lu_req_grant_r;
    reg [65:0]                  ats_toggle_grant_r;
    reg                         req_out_valid_r;
    reg [2:0]                   req_out_type_r;
    reg [15:0]                  req_out_flr_func_id_r;

    // Request outputs (registered passthrough)
    reg                         req_lu_pv_r, req_ins_pv_r, req_rl_pv_r;
    reg [19:0]                  req_lu_pasid_r, req_ins_pasid_r, req_rl_pasid_r;
    reg [15:0]                  req_lu_func_id_r, req_ins_func_id_r, req_rl_func_id_r;
    reg [63:0]                  req_lu_va_r, req_ins_va_r, req_rl_va_r;
    reg [63:0]                  req_ins_pa_r;
    reg [4:0]                   req_ins_stu_r;
    reg [3:0]                   req_ins_perm_r;
    reg [15:0]                  req_inv_mask_r;
    reg                         req_inv_pv_valid_r, req_inv_pv_r;
    reg [19:0]                  req_inv_pasid_r;
    reg [15:0]                  req_inv_func_id_r;
    reg [63:0]                  req_inv_va_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flr_grant_r           <= 1'b0;
            ats_toggle_grant_r    <= 66'd0;
            inv_req_grant_r       <= 1'b0;
            ins_req_grant_r       <= 1'b0;
            rl_req_grant_r        <= 1'b0;
            lu_req_grant_r        <= 1'b0;
            req_out_valid_r       <= 1'b0;
            req_out_type_r        <= `REQ_LOOKUP;
            req_out_flr_func_id_r <= 16'd0;
            // request payloads
            req_lu_pv_r           <= 1'b0;
            req_lu_pasid_r        <= 20'd0;
            req_lu_func_id_r      <= 16'd0;
            req_lu_va_r           <= 64'd0;
            req_ins_pv_r          <= 1'b0;
            req_ins_pasid_r       <= 20'd0;
            req_ins_func_id_r     <= 16'd0;
            req_ins_va_r          <= 64'd0;
            req_ins_pa_r          <= 64'd0;
            req_ins_stu_r         <= 5'd0;
            req_ins_perm_r        <= 4'd0;
            req_inv_mask_r        <= 16'd0;
            req_inv_pv_valid_r    <= 1'b0;
            req_inv_pv_r          <= 1'b0;
            req_inv_pasid_r       <= 20'd0;
            req_inv_func_id_r     <= 16'd0;
            req_inv_va_r          <= 64'd0;
            req_rl_pv_r           <= 1'b0;
            req_rl_pasid_r        <= 20'd0;
            req_rl_func_id_r      <= 16'd0;
            req_rl_va_r           <= 64'd0;
        end else begin
            flr_grant_r           <= flr_grant_comb;
            ats_toggle_grant_r    <= ats_toggle_grant_comb;
            inv_req_grant_r       <= inv_req_grant_comb;
            ins_req_grant_r       <= ins_req_grant_comb;
            rl_req_grant_r        <= rl_req_grant_comb;
            lu_req_grant_r        <= lu_req_grant_comb;
            req_out_valid_r       <= req_out_valid_comb;
            req_out_type_r        <= req_out_type_comb;
            req_out_flr_func_id_r <= req_out_flr_func_id_comb;
            // sample request payloads
            req_lu_pv_r           <= lu_req_pv;
            req_lu_pasid_r        <= lu_req_pasid;
            req_lu_func_id_r      <= lu_req_func_id;
            req_lu_va_r           <= lu_req_va;
            req_ins_pv_r          <= ins_req_pv;
            req_ins_pasid_r       <= ins_req_pasid;
            req_ins_func_id_r     <= ins_req_func_id;
            req_ins_va_r          <= ins_req_va;
            req_ins_pa_r          <= ins_req_pa;
            req_ins_stu_r         <= ins_req_stu;
            req_ins_perm_r        <= ins_req_perm;
            req_inv_mask_r        <= inv_req_mask;
            req_inv_pv_valid_r    <= inv_req_pv_valid;
            req_inv_pv_r          <= inv_req_pv;
            req_inv_pasid_r       <= inv_req_pasid;
            req_inv_func_id_r     <= inv_req_func_id;
            req_inv_va_r          <= inv_req_va;
            req_rl_pv_r           <= rl_req_pv;
            req_rl_pasid_r        <= rl_req_pasid;
            req_rl_func_id_r      <= rl_req_func_id;
            req_rl_va_r           <= rl_req_va;
        end
    end

    assign flr_grant           = flr_grant_r;
    assign ats_toggle_grant    = ats_toggle_grant_r;
    assign inv_req_grant       = inv_req_grant_r;
    assign ins_req_grant       = ins_req_grant_r;
    assign rl_req_grant        = rl_req_grant_r;
    assign lu_req_grant        = lu_req_grant_r;
    assign rl_req_data_pv      = req_rl_pv_r;
    assign rl_req_data_pasid   = req_rl_pasid_r;
    assign rl_req_data_func_id = req_rl_func_id_r;
    assign rl_req_data_va      = req_rl_va_r;
    assign req_out_valid       = req_out_valid_r;
    assign req_out_type        = req_out_type_r;
    assign req_out_flr_func_id = req_out_flr_func_id_r;
    assign req_out_lu_pv       = req_lu_pv_r;
    assign req_out_lu_pasid    = req_lu_pasid_r;
    assign req_out_lu_func_id  = req_lu_func_id_r;
    assign req_out_lu_va       = req_lu_va_r;
    assign req_out_ins_pv      = req_ins_pv_r;
    assign req_out_ins_pasid   = req_ins_pasid_r;
    assign req_out_ins_func_id = req_ins_func_id_r;
    assign req_out_ins_va      = req_ins_va_r;
    assign req_out_ins_pa      = req_ins_pa_r;
    assign req_out_ins_stu     = req_ins_stu_r;
    assign req_out_ins_perm    = req_ins_perm_r;
    assign req_out_inv_mask     = req_inv_mask_r;
    assign req_out_inv_pv_valid = req_inv_pv_valid_r;
    assign req_out_inv_pv       = req_inv_pv_r;
    assign req_out_inv_pasid    = req_inv_pasid_r;
    assign req_out_inv_func_id  = req_inv_func_id_r;
    assign req_out_inv_va       = req_inv_va_r;

endmodule
