//=============================================================================
// csr_agent.sv — CSR Agent (UVM-lite: Driver + Sequencer)
//
// Drives ATS enable toggle and FLR requests.
//=============================================================================
module csr_agent
    import atc_pkg::*;
    import atc_test_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    atc_if              vif,
    atc_scoreboard      sb
);

    //=========================================================================
    // Command Queue
    //=========================================================================
    typedef enum logic [1:0] {
        CSR_CMD_FLR,
        CSR_CMD_ATS_TOGGLE
    } csr_cmd_type_t;

    typedef struct {
        csr_cmd_type_t              cmd_type;
        logic [FUNC_ID_WIDTH-1:0]   flr_func_id;
    } csr_cmd_t;

    csr_cmd_t cmd_queue [$];

    typedef enum logic [2:0] {
        CSR_IDLE,
        CSR_FLR_DRIVE,
        CSR_FLR_WAIT,
        CSR_ATS_TOGGLE_DRIVE,
        CSR_ATS_TOGGLE_WAIT
    } csr_state_t;

    csr_state_t state;
    int         wait_cycles;
    csr_cmd_t   active_cmd;

    //=========================================================================
    // Sequencer: enqueue FLR
    //=========================================================================
    function automatic void enqueue_flr(
        input logic [FUNC_ID_WIDTH-1:0] func_id
    );
        csr_cmd_t cmd;
        cmd.cmd_type     = CSR_CMD_FLR;
        cmd.flr_func_id  = func_id;
        cmd_queue.push_back(cmd);
    endfunction

    //=========================================================================
    // Sequencer: enqueue ATS toggle
    //=========================================================================
    function automatic void enqueue_ats_toggle();
        csr_cmd_t cmd;
        cmd.cmd_type     = CSR_CMD_ATS_TOGGLE;
        cmd.flr_func_id  = '0;
        cmd_queue.push_back(cmd);
    endfunction

    //=========================================================================
    // Driver FSM
    //=========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= CSR_IDLE;
            wait_cycles      <= 0;
            vif.csr_ats_enable  <= 1'b1;
            vif.csr_flr_req     <= 1'b0;
            vif.csr_flr_func_id <= '0;
        end else begin
            case (state)
                CSR_IDLE: begin
                    vif.csr_flr_req <= 1'b0;
                    if (cmd_queue.size() > 0) begin
                        active_cmd = cmd_queue.pop_front();
                        if (active_cmd.cmd_type == CSR_CMD_FLR) begin
                            state <= CSR_FLR_DRIVE;
                        end else begin
                            state <= CSR_ATS_TOGGLE_DRIVE;
                        end
                    end
                end

                CSR_FLR_DRIVE: begin
                    vif.csr_flr_req     <= 1'b1;
                    vif.csr_flr_func_id <= active_cmd.flr_func_id;
                    state       <= CSR_FLR_WAIT;
                    wait_cycles <= 0;
                end

                CSR_FLR_WAIT: begin
                    vif.csr_flr_req <= 1'b0;
                    wait_cycles <= wait_cycles + 1;
                    // FLR takes ~70 cycles to complete (64 way traversal + margin)
                    if (wait_cycles >= 80) begin
                        sb.commit_flr(active_cmd.flr_func_id);
                        state <= CSR_IDLE;
                    end
                end

                CSR_ATS_TOGGLE_DRIVE: begin
                    vif.csr_ats_enable <= ~vif.csr_ats_enable;
                    state       <= CSR_ATS_TOGGLE_WAIT;
                    wait_cycles <= 0;
                end

                CSR_ATS_TOGGLE_WAIT: begin
                    wait_cycles <= wait_cycles + 1;
                    // ATS toggle cleanup takes ~70 cycles
                    if (wait_cycles >= 80) begin
                        sb.commit_ats_toggle();
                        state <= CSR_IDLE;
                    end
                end

                default: state <= CSR_IDLE;
            endcase
        end
    end

    //=========================================================================
    // Status
    //=========================================================================
    function automatic bit is_idle();
        return (state == CSR_IDLE) && (cmd_queue.size() == 0);
    endfunction

endmodule : csr_agent
