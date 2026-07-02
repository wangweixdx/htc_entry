//=============================================================================
// atc_csr_if.v — CSR Interface Adapter (Verilog-2001)
// Handles edge detection for ats_enable → ats_enable_toggle
// Registers flr_req for synchronous use
//=============================================================================
`include "atc_defines.vh"

module atc_csr_if (
    input                   clk,
    input                   rst_n,

    // ---- CSR inputs ----
    input  [65:0]           ats_enable,
    input                   flr_req_raw,
    input  [15:0]           flr_func_id_raw,
    input  [2:0]            csr_num_users,

    // ---- Conditioned outputs ----
    output [65:0]           ats_enable_sync,
    output [65:0]           ats_enable_toggle,
    output                  flr_req_sync,
    output [15:0]           flr_func_id_sync,
    output [2:0]            cfg_num_users
);

    //=========================================================================
    // ats_enable edge detection
    //=========================================================================
    reg [65:0] ats_enable_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ats_enable_d1 <= {66{1'b1}};
        end else begin
            ats_enable_d1 <= ats_enable;
        end
    end

    assign ats_enable_sync  = ats_enable;
    assign ats_enable_toggle = ats_enable ^ ats_enable_d1;

    //=========================================================================
    // FLR synchronization (2-stage synchronizer for async input)
    //=========================================================================
    reg flr_req_s1, flr_req_s2;
    reg [15:0] flr_func_id_s1, flr_func_id_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flr_req_s1       <= 1'b0;
            flr_req_s2       <= 1'b0;
            flr_func_id_s1   <= 16'd0;
            flr_func_id_s2   <= 16'd0;
        end else begin
            {flr_req_s2, flr_req_s1}       <= {flr_req_s1, flr_req_raw};
            {flr_func_id_s2, flr_func_id_s1} <= {flr_func_id_s1, flr_func_id_raw};
        end
    end

    assign flr_req_sync      = flr_req_s2;
    assign flr_func_id_sync  = flr_func_id_s2;
    assign cfg_num_users     = csr_num_users;

endmodule
