//=============================================================================
// dma_agent.sv — DMA Agent (UVM-lite: Driver + Monitor + Sequencer)
//
// Drives DMA Lookup requests and monitors responses.
// Supports directed and constrained-random transaction sequences.
//=============================================================================
module dma_agent
    import atc_pkg::*;
    import atc_test_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    atc_if              vif,
    atc_scoreboard      sb
);

    //=========================================================================
    // Transaction Queue (simple sequencer)
    //=========================================================================
    dma_trans_t  tx_queue [$];
    dma_trans_t  active_tx;
    int          tx_id_counter;

    //=========================================================================
    // Sequencer: enqueue a lookup transaction
    //=========================================================================
    function automatic void enqueue_lookup(
        input logic [PV_WIDTH-1:0]      pv,
        input logic [PASID_WIDTH-1:0]   pasid,
        input logic [FUNC_ID_WIDTH-1:0] func_id,
        input logic [VA_WIDTH-1:0]      addr
    );
        dma_trans_t tr;
        tr.id        = tx_id_counter++;
        tr.pv        = pv;
        tr.pasid     = pasid;
        tr.func_id   = func_id;
        tr.addr      = addr;
        tr.exp_hit   = 1'b0;
        tr.exp_pre_hit = 1'b0;
        tr.exp_pa    = '0;
        tr.exp_perm  = '0;
        tx_queue.push_back(tr);
    endfunction

    //=========================================================================
    // Sequencer: enqueue a random lookup
    //=========================================================================
    function automatic void enqueue_random_lookup();
        dma_trans_t tr;
        tr.id        = tx_id_counter++;
        tr.pv        = 16'($urandom);
        tr.pasid     = 16'($urandom);
        tr.func_id   = 16'($urandom_range(0, 63));
        tr.addr      = 64'($urandom) & 64'h0000_FFFF_FFFF_F000;
        tr.exp_hit   = 1'b0;
        tr.exp_pre_hit = 1'b0;
        tr.exp_pa    = '0;
        tr.exp_perm  = '0;
        tx_queue.push_back(tr);
    endfunction

    //=========================================================================
    // Driver FSM
    //=========================================================================
    typedef enum logic [1:0] {
        DMA_IDLE,
        DMA_DRIVE,
        DMA_WAIT_RSP
    } dma_drv_state_t;

    dma_drv_state_t drv_state;
    int             rsp_wait_cycles;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            drv_state       <= DMA_IDLE;
            active_tx       <= '{
                pv: '0, pasid: '0, func_id: '0, addr: '0,
                exp_hit: 1'b0, exp_pre_hit: 1'b0,
                exp_pa: '0, exp_perm: '0,
                id: 0, cycle_sent: 0, cycle_rcvd: 0
            };
            rsp_wait_cycles <= 0;
            vif.dma_lu_req_valid  <= 1'b0;
            vif.dma_lu_req_pv     <= '0;
            vif.dma_lu_req_pasid  <= '0;
            vif.dma_lu_req_func_id <= '0;
            vif.dma_lu_req_addr   <= '0;
        end else begin
            case (drv_state)
                DMA_IDLE: begin
                    vif.dma_lu_req_valid <= 1'b0;
                    if (tx_queue.size() > 0) begin
                        active_tx = tx_queue.pop_front();
                        sb.predict_lookup(active_tx);
                        active_tx.cycle_sent = sb.cycle_count;
                        drv_state <= DMA_DRIVE;
                    end
                end

                DMA_DRIVE: begin
                    vif.dma_lu_req_valid  <= 1'b1;
                    vif.dma_lu_req_pv     <= active_tx.pv;
                    vif.dma_lu_req_pasid  <= active_tx.pasid;
                    vif.dma_lu_req_func_id <= active_tx.func_id;
                    vif.dma_lu_req_addr   <= active_tx.addr;
                    drv_state <= DMA_WAIT_RSP;
                    rsp_wait_cycles <= 0;
                end

                DMA_WAIT_RSP: begin
                    vif.dma_lu_req_valid <= 1'b0;
                    rsp_wait_cycles <= rsp_wait_cycles + 1;
                    if (vif.dma_lu_rsp_valid) begin
                        active_tx.cycle_rcvd = sb.cycle_count;
                        sb.check_lookup(active_tx,
                                        vif.dma_lu_rsp_hit,
                                        vif.dma_lu_rsp_translated_addr,
                                        vif.dma_lu_rsp_perm);
                        drv_state <= DMA_IDLE;
                    end else if (rsp_wait_cycles > 200) begin
                        $display("[DMA_AGENT] Timeout waiting for lookup response (id=%0d)",
                                 active_tx.id);
                        sb.mismatch_count++;
                        drv_state <= DMA_IDLE;
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // Status
    //=========================================================================
    function automatic int pending_count();
        return tx_queue.size();
    endfunction

    function automatic bit is_idle();
        return (drv_state == DMA_IDLE) && (tx_queue.size() == 0);
    endfunction

endmodule : dma_agent
