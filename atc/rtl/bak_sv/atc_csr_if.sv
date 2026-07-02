//=============================================================================
// atc_csr_if.sv — CSR Interface Adapter
// Handles edge detection for ats_enable → ats_enable_toggle
// Registers flr_req for synchronous use
//=============================================================================
module atc_csr_if
    import atc_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- CSR inputs ----
    input  logic [65:0]                  ats_enable,         // per-function ATS enable
    input  logic                         flr_req_raw,        // FLR request (could be async)
    input  logic [FUNC_ID_WIDTH-1:0]     flr_func_id_raw,
    input  logic [N_USER_W-1:0]          csr_num_users,      // partition config

    // ---- Conditioned outputs ----
    output logic [65:0]                  ats_enable_sync,
    output logic [65:0]                  ats_enable_toggle,  // per-function toggle on any edge
    output logic                         flr_req_sync,
    output logic [FUNC_ID_WIDTH-1:0]     flr_func_id_sync,
    output logic [N_USER_W-1:0]          cfg_num_users       // pass-through
);

    //=========================================================================
    // ats_enable edge detection
    //=========================================================================
    logic [65:0] ats_enable_d1;  // delayed 1 cycle

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ats_enable_d1 <= {66{1'b1}};  // all enabled after reset
        end else begin
            ats_enable_d1 <= ats_enable;
        end
    end

    assign ats_enable_sync  = ats_enable;
    assign ats_enable_toggle = ats_enable ^ ats_enable_d1;  // per-bit edge detect

    //=========================================================================
    // FLR synchronization (2-stage synchronizer for async input)
    //=========================================================================
    logic flr_req_s1, flr_req_s2;
    logic [FUNC_ID_WIDTH-1:0] flr_func_id_s1, flr_func_id_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flr_req_s1       <= 1'b0;
            flr_req_s2       <= 1'b0;
            flr_func_id_s1   <= '0;
            flr_func_id_s2   <= '0;
        end else begin
            {flr_req_s2, flr_req_s1}       <= {flr_req_s1, flr_req_raw};
            {flr_func_id_s2, flr_func_id_s1} <= {flr_func_id_s1, flr_func_id_raw};
        end
    end

    assign flr_req_sync      = flr_req_s2;
    assign flr_func_id_sync  = flr_func_id_s2;
    assign cfg_num_users     = csr_num_users;  // synchronous, pass-through

endmodule : atc_csr_if
