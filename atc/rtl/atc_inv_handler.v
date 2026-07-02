//=============================================================================
// atc_inv_handler.v — Invalidation Handler (Verilog-2001)
// 3 modes:
//   1. Regular ATS Invalidation — clears entries matching inv request
//   2. ATS Enable Toggle — clears ALL entries (global invalidation)
//   3. FLR (Function Level Reset) — clears entries for a specific Function ID
//=============================================================================
`include "atc_defines.vh"

module atc_inv_handler (
    input                           clk,
    input                           rst_n,

    // ---- Invalidation Request Inputs ----
    input                           inv_req_valid,
    input  [15:0]                   inv_req_mask,
    input                           inv_req_pv_valid,
    input                           inv_req_pv,
    input  [19:0]                   inv_req_pasid,
    input  [15:0]                   inv_req_func_id,
    input  [63:0]                   inv_req_va,
    output reg                      inv_req_ready,
    output reg                      inv_ack_valid,

    // ATS enable toggle
    input  [65:0]                   ats_toggle_req,

    // FLR
    input                           flr_req,
    input  [15:0]                   flr_func_id,
    output reg                      flr_done,

    // ---- Entry Array Interface (batch clear + individual invalidation) ----
    output reg                      ea_batch_clr_en,
    output reg [15:0]               ea_batch_clr_func_id,
    output reg                      ea_batch_clr_all,

    // Individual invalidation
    output reg                      ea_inv_en,
    output reg [4:0]                ea_inv_set_idx,
    output reg [5:0]                ea_inv_way_idx,

    // ---- Comparison port for regular invalidation ----
    output reg                      ea_cmp_inv_mode,
    output reg                      ea_cmp_en,
    output reg [4:0]                ea_cmp_set_idx,
    output reg                      ea_cmp_pv,
    output reg [19:0]               ea_cmp_pasid,
    output reg [15:0]               ea_cmp_func_id,
    output reg [16:0][63:0]         ea_cmp_addr,

    input  [16:0][63:0]             ea_hit_vectors,
    input  [5:0]                    ea_hit_way_idx,
    input                           ea_any_hit,

    // ---- Busy / status ----
    output reg                      inv_busy,

    // ---- Partition config ----
    input  [2:0]                    cfg_num_users
);

    //=========================================================================
    // Partition scan range
    //=========================================================================
    reg [4:0] scan_set_base;
    reg [4:0] scan_set_limit;
    wire [4:0] scan_set_last;
    assign scan_set_last = scan_set_limit - 5'd1;

    //=========================================================================
    // FSM
    //=========================================================================
    reg [3:0] state, state_next;

    // Scan counters
    reg [4:0]  scan_set_cnt;
    reg [5:0]  scan_way_cnt;
    reg [5:0]  batch_cycle_cnt;

    // Stored request
    reg [15:0] stored_inv_mask;
    reg        stored_inv_pv_valid;
    reg        stored_inv_pv;
    reg [19:0] stored_inv_pasid;
    reg [15:0] stored_inv_func_id;
    reg [63:0] stored_inv_va;

    // Pending flags
    reg reg_inv_pending;
    reg flr_pending;
    reg ats_toggle_pending;

    //=========================================================================
    // FSM Combinational
    //=========================================================================
    integer p;
    always @(*) begin
        state_next        = state;
        inv_req_ready     = 1'b0;
        inv_ack_valid     = 1'b0;
        flr_done          = 1'b0;
        inv_busy          = (state != `INV_IDLE) && (state != `INV_DONE);

        ea_cmp_inv_mode   = 1'b1;

        ea_batch_clr_en   = 1'b0;
        ea_batch_clr_func_id = flr_func_id;
        ea_batch_clr_all  = 1'b0;

        ea_inv_en         = 1'b0;
        ea_inv_set_idx    = scan_set_cnt;
        ea_inv_way_idx    = ea_hit_way_idx;

        ea_cmp_en         = 1'b0;
        ea_cmp_set_idx    = scan_set_cnt;
        ea_cmp_pv         = stored_inv_pv;
        ea_cmp_pasid      = stored_inv_pasid;
        ea_cmp_func_id    = stored_inv_func_id;
        // Invalidation uses only current address (no prefetch)
        for (p = 0; p < 17; p = p + 1)
            ea_cmp_addr[p] = stored_inv_va;

        case (state)
            `INV_IDLE: begin
                inv_req_ready = 1'b1;
                if (flr_req) begin
                    state_next = `INV_FLR_SCAN;
                end else if (|ats_toggle_req) begin
                    state_next = `INV_ATS_CLR;
                end else if (inv_req_valid) begin
                    state_next = `INV_REG_SCAN;
                end
            end

            `INV_REG_SCAN: begin
                ea_cmp_inv_mode = 1'b1;
                ea_cmp_en = 1'b1;
                if (ea_any_hit) begin
                    ea_inv_en = 1'b1;
                    state_next = `INV_REG_CLEAR;
                end else if (scan_set_cnt == scan_set_last) begin
                    state_next = `INV_DONE;
                end else begin
                    state_next = `INV_REG_NEXT_SET;
                end
            end

            `INV_REG_NEXT_SET: begin
                state_next = `INV_REG_SCAN;
            end

            `INV_REG_CLEAR: begin
                if (scan_set_cnt == scan_set_last) begin
                    state_next = `INV_DONE;
                end else begin
                    state_next = `INV_REG_SCAN;
                end
            end

            `INV_ATS_CLR: begin
                ea_batch_clr_en  = 1'b1;
                ea_batch_clr_all = 1'b1;
                if (batch_cycle_cnt == 6'd63) begin
                    state_next = `INV_DONE;
                end
            end

            `INV_FLR_SCAN: begin
                ea_batch_clr_en  = 1'b1;
                ea_batch_clr_func_id = flr_func_id;
                ea_batch_clr_all = 1'b0;
                if (batch_cycle_cnt == 6'd63) begin
                    state_next = `INV_DONE;
                end
            end

            `INV_DONE: begin
                inv_ack_valid = reg_inv_pending;
                flr_done      = flr_pending || ats_toggle_pending;
                state_next    = `INV_IDLE;
            end

            default: state_next = `INV_IDLE;
        endcase
    end

    //=========================================================================
    // Counters & Registers
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= `INV_IDLE;
            scan_set_cnt     <= 5'd0;
            scan_way_cnt     <= 6'd0;
            batch_cycle_cnt  <= 6'd0;
            scan_set_base    <= 5'd0;
            scan_set_limit   <= 5'd32;
            reg_inv_pending  <= 1'b0;
            flr_pending      <= 1'b0;
            ats_toggle_pending <= 1'b0;
            stored_inv_mask   <= 16'd0;
            stored_inv_pv_valid <= 1'b0;
            stored_inv_pv      <= 1'b0;
            stored_inv_pasid   <= 20'd0;
            stored_inv_func_id <= 16'd0;
            stored_inv_va      <= 64'd0;
        end else begin
            state <= state_next;

            case (state)
                `INV_IDLE: begin
                    scan_way_cnt    <= 6'd0;
                    batch_cycle_cnt <= 6'd0;
                    if (flr_req) begin
                        flr_pending <= 1'b1;
                        reg_inv_pending <= 1'b0;
                        ats_toggle_pending <= 1'b0;
                        scan_set_base  <= get_user_set_base(cfg_num_users, flr_func_id[5:0]);
                        scan_set_limit <= get_user_set_limit(cfg_num_users, flr_func_id[5:0]);
                        scan_set_cnt   <= get_user_set_base(cfg_num_users, flr_func_id[5:0]);
                    end else if (|ats_toggle_req) begin
                        ats_toggle_pending <= 1'b1;
                        reg_inv_pending <= 1'b0;
                        flr_pending <= 1'b0;
                        scan_set_base  <= 5'd0;
                        scan_set_limit <= 5'd32;
                        scan_set_cnt   <= 5'd0;
                    end else if (inv_req_valid) begin
                        reg_inv_pending <= 1'b1;
                        flr_pending <= 1'b0;
                        ats_toggle_pending <= 1'b0;
                        stored_inv_mask   <= inv_req_mask;
                        stored_inv_pv_valid <= inv_req_pv_valid;
                        stored_inv_pv      <= inv_req_pv;
                        stored_inv_pasid   <= inv_req_pasid;
                        stored_inv_func_id <= inv_req_func_id;
                        stored_inv_va      <= inv_req_va;
                        scan_set_base  <= get_user_set_base(cfg_num_users, inv_req_func_id[5:0]);
                        scan_set_limit <= get_user_set_limit(cfg_num_users, inv_req_func_id[5:0]);
                        scan_set_cnt   <= get_user_set_base(cfg_num_users, inv_req_func_id[5:0]);
                    end
                end

                `INV_REG_SCAN: begin
                end

                `INV_REG_NEXT_SET: begin
                    scan_set_cnt <= scan_set_cnt + 5'd1;
                end

                `INV_REG_CLEAR: begin
                    if (scan_set_cnt == scan_set_last) begin
                        scan_set_cnt <= scan_set_base;
                    end else begin
                        scan_set_cnt <= scan_set_cnt + 5'd1;
                    end
                end

                `INV_ATS_CLR: begin
                    batch_cycle_cnt <= batch_cycle_cnt + 6'd1;
                end

                `INV_FLR_SCAN: begin
                    batch_cycle_cnt <= batch_cycle_cnt + 6'd1;
                end

                `INV_DONE: begin
                    reg_inv_pending   <= 1'b0;
                    flr_pending       <= 1'b0;
                    ats_toggle_pending <= 1'b0;
                end

                default: ;
            endcase
        end
    end

endmodule
