//=============================================================================
// atc_defines.vh — ATC Global Parameters & Helper Functions (Verilog-2001)
// Target: EP-side ATC Controller, SF4X @ 1GHz
//=============================================================================

//=========================================================================
// Structural Parameters
//=========================================================================
`define N_SETS          32
`define N_WAYS          64
`define N_ENTRIES       2048

`define SET_IDX_W       5
`define WAY_IDX_W       6
`define ENTRY_IDX_W     11

//=========================================================================
// Field Width Parameters
//=========================================================================
`define PV_WIDTH        1
`define PASID_WIDTH     20
`define FUNC_ID_WIDTH   16
`define VA_WIDTH        64
`define PA_WIDTH        64
`define STU_WIDTH       5
`define PERM_WIDTH      4
`define NRU_HINT_W      2

//=========================================================================
// Pipeline & Timing Parameters
//=========================================================================
`define PIPELINE_STAGES          3
`define DUPCHECK_CYCLES          4
`define DUPCHECK_SETS_PER        8
`define NRU_DECAY_INTERVAL       1024
`define ATS_TOGGLE_CLEANUP_CYCLES 4
`define FLR_CLEANUP_CYCLES       4

//=========================================================================
// Partition Parameters
//=========================================================================
`define N_USER_W                 3
`define PART_1                   0
`define PART_2                   1
`define PART_4                   2
`define PART_8                   3
`define PART_16                  4
`define PART_32                  5
`define PART_64                  6
`define PART_48                  7
`define PART_MAX                 7

//=========================================================================
// 64K Pre-lookup / Prefetch
//=========================================================================
`define LOOKAHEAD_OFFSET         64'h0001_0000
`define PREFETCH_COUNT           17
`define PREFETCH_IDX_W           5

//=========================================================================
// Entry Storage Bit Layout
//   | valid | PV | PASID | FuncID | VA | STU | PA | perm | nru |
//   |   1   | 1  |   20  |   16   | 64 |  5  | 64 |  4   |  2  |
//   Total: 177 bits
//=========================================================================
`define ENTRY_WIDTH              177
`define TAG_WIDTH                118
`define DATA_WIDTH               68
`define SRAM_DEPTH               2048
`define SRAM_ADDR_W              11

`define ENTRY_VALID_MSB          176
`define ENTRY_VALID_LSB          176
`define ENTRY_PV_MSB             175
`define ENTRY_PV_LSB             175
`define ENTRY_PASID_MSB          174
`define ENTRY_PASID_LSB          155
`define ENTRY_FUNCID_MSB         154
`define ENTRY_FUNCID_LSB         139
`define ENTRY_VA_MSB             138
`define ENTRY_VA_LSB             75
`define ENTRY_STU_MSB            74
`define ENTRY_STU_LSB            70
`define ENTRY_PA_MSB             69
`define ENTRY_PA_LSB             6
`define ENTRY_PERM_MSB           5
`define ENTRY_PERM_LSB           2
`define ENTRY_NRU_MSB            1
`define ENTRY_NRU_LSB            0

//=========================================================================
// Hit Vector Width
//=========================================================================
`define HIT_VEC_W                `N_WAYS

//=========================================================================
// Request Type Encoding
//=========================================================================
`define REQ_LOOKUP              3'b000
`define REQ_INSERT              3'b001
`define REQ_INVALIDATE          3'b010
`define REQ_ATS_TOGGLE          3'b011
`define REQ_FLR                 3'b100
`define REQ_RELOOK              3'b101

//=========================================================================
// NRU State Encoding
//=========================================================================
`define NRU_FREE                2'b01
`define NRU_IDLE                2'b00
`define NRU_ACTIVE              2'b11
`define NRU_PROTECT             2'b10

//=========================================================================
// DupCheck State Encoding
//=========================================================================
`define DC_IDLE                 3'd0
`define DC_SCAN0                3'd1
`define DC_SCAN1                3'd2
`define DC_SCAN2                3'd3
`define DC_SCAN3                3'd4
`define DC_RESULT               3'd5

//=========================================================================
// Invalidation State Encoding
//=========================================================================
`define INV_IDLE                4'd0
`define INV_REG_SCAN            4'd1
`define INV_REG_CLEAR           4'd2
`define INV_REG_NEXT_SET        4'd3
`define INV_ATS_CLR             4'd4
`define INV_ATS_WAIT            4'd5
`define INV_FLR_SCAN            4'd6
`define INV_FLR_CLR             4'd7
`define INV_FLR_WAIT            4'd8
`define INV_DONE                4'd9

//=========================================================================
// Arbiter Select Encoding
//=========================================================================
`define SEL_FLR                 3'd0
`define SEL_ATS_TOGGLE          3'd1
`define SEL_INV                 3'd2
`define SEL_INSERT              3'd3
`define SEL_RELOOK              3'd5
`define SEL_LOOKUP              3'd4
`define SEL_NONE                3'd7

//=========================================================================
// Helper Functions
//=========================================================================

// clog2 function (required by Verilog-2001 for constant expressions)
function integer clog2;
    input integer value;
    integer tmp;
    begin
        tmp = value - 1;
        for (clog2 = 0; tmp > 0; clog2 = clog2 + 1)
            tmp = tmp >> 1;
    end
endfunction

// STU mask: bits below STU are masked to 0
function [63:0] apply_stu_mask;
    input [63:0] addr;
    input [4:0]  stu;
    reg [63:0] mask;
    begin
        mask = ~((64'd1 << stu) - 64'd1);
        apply_stu_mask = addr & mask;
    end
endfunction

// Partition: convert encoding to number of users
function integer num_users_from_part;
    input [2:0] part;
    begin
        case (part)
            `PART_1:  num_users_from_part = 1;
            `PART_2:  num_users_from_part = 2;
            `PART_4:  num_users_from_part = 4;
            `PART_8:  num_users_from_part = 8;
            `PART_16: num_users_from_part = 16;
            `PART_32: num_users_from_part = 32;
            `PART_64: num_users_from_part = 64;
            `PART_48: num_users_from_part = 48;
            default:  num_users_from_part = 1;
        endcase
    end
endfunction

// Partition: sets per user
function integer get_sets_per_user;
    input [2:0] part;
    integer n;
    begin
        n = num_users_from_part(part);
        get_sets_per_user = (n <= 32) ? `N_SETS / n : `N_SETS;
    end
endfunction

// Partition: ways per user
function integer get_ways_per_user;
    input [2:0] part;
    integer n, users_per_set;
    begin
        n = num_users_from_part(part);
        users_per_set = (n + `N_SETS - 1) / `N_SETS;
        get_ways_per_user = (n > 32) ? `N_WAYS / users_per_set : `N_WAYS;
    end
endfunction

// Partition: base set index for user k
function [4:0] get_user_set_base;
    input [2:0] part;
    input integer user_id;
    integer n, sets_per;
    begin
        n = num_users_from_part(part);
        sets_per = get_sets_per_user(part);
        get_user_set_base = user_id * sets_per;
    end
endfunction

// Partition: base way index for user k
function [5:0] get_user_way_base;
    input [2:0] part;
    input integer user_id;
    integer n, users_per_set;
    begin
        n = num_users_from_part(part);
        users_per_set = (n + `N_SETS - 1) / `N_SETS;
        get_user_way_base = (n > 32) ? (user_id % users_per_set) * get_ways_per_user(part) : 0;
    end
endfunction

// Partition: way limit for user k
function [6:0] get_user_way_limit;
    input [2:0] part;
    input integer user_id;
    integer n, users_per_set;
    begin
        n = num_users_from_part(part);
        if (n <= 32) begin
            get_user_way_limit = `N_WAYS;
        end else begin
            users_per_set = (n + `N_SETS - 1) / `N_SETS;
            get_user_way_limit = ((user_id % users_per_set) + 1) * get_ways_per_user(part);
        end
    end
endfunction

// Partition: set limit for user k
function [4:0] get_user_set_limit;
    input [2:0] part;
    input integer user_id;
    integer sets_per;
    begin
        sets_per = get_sets_per_user(part);
        get_user_set_limit = (user_id + 1) * sets_per;
    end
endfunction

// Partition-aware hash
function [4:0] partition_hash;
    input [2:0] part;
    input integer user_id;
    input [15:0] func_id;
    input [63:0] va;
    reg [4:0] raw_hash;
    reg [4:0] base;
    integer sets_per;
    begin
        raw_hash = ((func_id[3:0] ^ va[15:12]) & 5'h1F);
        sets_per = get_sets_per_user(part);
        if (sets_per >= `N_SETS) begin
            partition_hash = raw_hash;
        end else begin
            base = get_user_set_base(part, user_id);
            partition_hash = base + (raw_hash % sets_per);
        end
    end
endfunction

// Pack entry fields into flat vector
function [176:0] pack_entry;
    input             valid;
    input             pv;
    input [19:0]      pasid;
    input [15:0]      func_id;
    input [63:0]      va;
    input [4:0]       stu;
    input [63:0]      pa;
    input [3:0]       perm;
    input [1:0]       nru;
    begin
        pack_entry = {valid, pv, pasid, func_id, va, stu, pa, perm, nru};
    end
endfunction
