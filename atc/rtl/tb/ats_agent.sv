//=============================================================================
// ats_agent.sv — ATS Agent (UVM-lite: Driver + Monitor + Sequencer)
//
// Drives ATS Translation Completions (Insert) and ATS Invalidation Requests,
// monitors ACK responses. Simulates RC-side ATS behavior.
//=============================================================================
module ats_agent
    import atc_pkg::*;
    import atc_test_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    atc_if              vif,
    atc_scoreboard      sb
);

    //=========================================================================
    // Transaction Queues
    //=========================================================================
    ats_comp_trans_t  ins_queue [$];
    ats_inv_trans_t   inv_queue [$];
    int               tx_id_counter;

    typedef enum logic [3:0] {
        ATS_IDLE,
        ATS_INS_DRIVE,
        ATS_INS_WAIT_DC,
        ATS_INV_DRIVE,
        ATS_INV_WAIT_ACK,
        ATS_DONE
    } ats_state_t;

    ats_state_t  state;
    int          wait_cycles;
    ats_comp_trans_t active_ins;
    ats_inv_trans_t  active_inv;

    //=========================================================================
    // Sequencer: enqueue insert
    //=========================================================================
    function automatic void enqueue_insert(
        input logic [PV_WIDTH-1:0]      pv,
        input logic [PASID_WIDTH-1:0]   pasid,
        input logic [FUNC_ID_WIDTH-1:0] func_id,
        input logic [VA_WIDTH-1:0]      va,
        input logic [PA_WIDTH-1:0]      pa,
        input logic [STU_WIDTH-1:0]     stu,
        input logic [PERM_WIDTH-1:0]    perm
    );
        ats_comp_trans_t tr;
        tr.id                = tx_id_counter++;
        tr.pv                = pv;
        tr.pasid             = pasid;
        tr.func_id           = func_id;
        tr.untranslated_addr = va;
        tr.translated_addr   = pa;
        tr.stu               = stu;
        tr.perm              = perm;
        tr.exp_duplicate     = 1'b0;
        ins_queue.push_back(tr);
    endfunction

    //=========================================================================
    // Sequencer: enqueue random insert
    //=========================================================================
    function automatic void enqueue_random_insert();
        ats_comp_trans_t tr;
        tr.id                = tx_id_counter++;
        tr.pv                = 16'($urandom_range(0, 16));
        tr.pasid             = 16'($urandom);
        tr.func_id           = 16'($urandom_range(0, 63));
        tr.untranslated_addr = 64'($urandom) & 64'h0000_FFFF_FFFF_F000;
        tr.translated_addr   = {32'($urandom), 32'($urandom)};
        tr.stu               = 5'($urandom_range(12, 30));
        tr.perm              = 4'($urandom_range(1, 15));
        tr.exp_duplicate     = 1'b0;
        ins_queue.push_back(tr);
    endfunction

    //=========================================================================
    // Sequencer: enqueue invalidate
    //=========================================================================
    function automatic void enqueue_invalidate(
        input logic                     pv_valid,
        input logic [PV_WIDTH-1:0]      pv,
        input logic [PASID_WIDTH-1:0]   pasid,
        input logic [FUNC_ID_WIDTH-1:0] func_id,
        input logic [VA_WIDTH-1:0]      addr
    );
        ats_inv_trans_t tr;
        tr.id                = tx_id_counter++;
        tr.pv_valid          = pv_valid;
        tr.pv                = pv;
        tr.pasid             = pasid;
        tr.func_id           = func_id;
        tr.untranslated_addr = addr;
        tr.inv_mask          = '1;
        inv_queue.push_back(tr);
    endfunction

    //=========================================================================
    // Driver FSM
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ATS_IDLE;
            wait_cycles <= 0;
            vif.ats_comp_valid              <= 1'b0;
            vif.ats_comp_pv                <= '0;
            vif.ats_comp_pasid             <= '0;
            vif.ats_comp_func_id           <= '0;
            vif.ats_comp_untranslated_addr <= '0;
            vif.ats_comp_translated_addr   <= '0;
            vif.ats_comp_stu              <= '0;
            vif.ats_comp_perm             <= '0;
            vif.ats_inv_req_valid          <= 1'b0;
            vif.ats_inv_mask               <= '0;
            vif.ats_inv_pv_valid           <= 1'b0;
            vif.ats_inv_pv                 <= '0;
            vif.ats_inv_pasid             <= '0;
            vif.ats_inv_func_id           <= '0;
            vif.ats_inv_untranslated_addr  <= '0;
        end else begin
            case (state)
                ATS_IDLE: begin
                    vif.ats_comp_valid   <= 1'b0;
                    vif.ats_inv_req_valid <= 1'b0;
                    // Priority: Insert over Invalidate (arbiter handles final priority)
                    if (ins_queue.size() > 0) begin
                        active_ins = ins_queue.pop_front();
                        sb.predict_insert(active_ins);
                        state <= ATS_INS_DRIVE;
                    end else if (inv_queue.size() > 0) begin
                        active_inv = inv_queue.pop_front();
                        sb.predict_invalidate(active_inv);
                        state <= ATS_INV_DRIVE;
                    end
                end

                ATS_INS_DRIVE: begin
                    vif.ats_comp_valid              <= 1'b1;
                    vif.ats_comp_pv                <= active_ins.pv;
                    vif.ats_comp_pasid             <= active_ins.pasid;
                    vif.ats_comp_func_id           <= active_ins.func_id;
                    vif.ats_comp_untranslated_addr <= active_ins.untranslated_addr;
                    vif.ats_comp_translated_addr   <= active_ins.translated_addr;
                    vif.ats_comp_stu              <= active_ins.stu;
                    vif.ats_comp_perm             <= active_ins.perm;
                    state       <= ATS_INS_WAIT_DC;
                    wait_cycles <= 0;
                end

                ATS_INS_WAIT_DC: begin
                    vif.ats_comp_valid <= 1'b0;
                    wait_cycles <= wait_cycles + 1;
                    // Wait for dupcheck (4 cycles) + margin
                    if (wait_cycles >= 6) begin
                        sb.commit_insert(active_ins);
                        state <= ATS_IDLE;
                    end
                end

                ATS_INV_DRIVE: begin
                    vif.ats_inv_req_valid          <= 1'b1;
                    vif.ats_inv_mask               <= active_inv.inv_mask;
                    vif.ats_inv_pv_valid           <= active_inv.pv_valid;
                    vif.ats_inv_pv                 <= active_inv.pv;
                    vif.ats_inv_pasid             <= active_inv.pasid;
                    vif.ats_inv_func_id           <= active_inv.func_id;
                    vif.ats_inv_untranslated_addr  <= active_inv.untranslated_addr;
                    state       <= ATS_INV_WAIT_ACK;
                    wait_cycles <= 0;
                end

                ATS_INV_WAIT_ACK: begin
                    vif.ats_inv_req_valid <= 1'b0;
                    wait_cycles <= wait_cycles + 1;
                    if (vif.ats_inv_ack_valid) begin
                        sb.commit_invalidate(active_inv);
                        state <= ATS_IDLE;
                    end else if (wait_cycles > 500) begin
                        $display("[ATS_AGENT] Timeout waiting for invalidation ACK (id=%0d)",
                                 active_inv.id);
                        sb.mismatch_count++;
                        state <= ATS_IDLE;
                    end
                end

                default: state <= ATS_IDLE;
            endcase
        end
    end

    //=========================================================================
    // Status
    //=========================================================================
    function automatic bit is_idle();
        return (state == ATS_IDLE) && (ins_queue.size() == 0) && (inv_queue.size() == 0);
    endfunction

endmodule : ats_agent
