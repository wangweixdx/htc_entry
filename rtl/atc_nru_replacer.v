// atc_nru_replacer.v — NRU Victim Selection (iverilog-compatible)
`include "atc_defines.vh"
module atc_nru_replacer (
    input clk, rst_n, victim_sel_en,
    output [5:0] victim_way,
    output victim_valid,
    input nru_update_en,
    input [5:0] nru_update_way,
    input [1:0] nru_update_val,
    output [63:0][1:0] nru_state_out,
    input nru_clear_all_used, nru_decay_tick,
    input [6:0] way_base, way_limit
);
    reg [63:0] nru_used;
    reg [63:0] nru_not_last;
    genvar gi;
    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : gen_nru
            assign nru_state_out[gi] = {nru_used[gi], nru_not_last[gi]};
        end
    endgenerate
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 64; i = i + 1) begin
                nru_used[i] <= 1'b0; nru_not_last[i] <= 1'b1;
            end
        end else begin
            if (nru_clear_all_used) begin
                for (i = 0; i < 64; i = i + 1) begin
                    nru_used[i] <= 1'b0; if (i == 0) nru_not_last[i] <= 1'b0;
                end
            end else if (nru_decay_tick) begin
                for (i = 0; i < 64; i = i + 1) nru_used[i] <= 1'b0;
            end else if (nru_update_en) begin
                nru_used[nru_update_way] <= nru_update_val[1];
                nru_not_last[nru_update_way] <= nru_update_val[0];
            end
        end
    end
    reg found; reg [5:0] sel_way; integer j;
    always @(*) begin
        found = 1'b0; sel_way = way_base[5:0];
        for (j = 0; j < 64; j = j + 1) begin
            if (!found && j >= way_base && j < way_limit && !nru_used[j] && nru_not_last[j]) begin found = 1'b1; sel_way = j[5:0]; end
        end
        if (!found) for (j = 0; j < 64; j = j + 1) begin
            if (!found && j >= way_base && j < way_limit && !nru_used[j] && !nru_not_last[j]) begin found = 1'b1; sel_way = j[5:0]; end
        end
        if (!found) for (j = 0; j < 64; j = j + 1) begin
            if (!found && j >= way_base && j < way_limit && nru_used[j] && nru_not_last[j]) begin found = 1'b1; sel_way = j[5:0]; end
        end
        if (!found) for (j = 0; j < 64; j = j + 1) begin
            if (!found && j >= way_base && j < way_limit) begin found = 1'b1; sel_way = j[5:0]; end
        end
    end
    assign victim_way = sel_way;
    assign victim_valid = found && victim_sel_en;
endmodule
