//=============================================================================
// atc_pkg.sv — ATC (Address Translation Cache) Global Parameters & Types
// Target: EP-side ATC Controller, SF4X @ 1GHz
//=============================================================================
package atc_pkg;

    //=========================================================================
    // Structural Parameters
    //=========================================================================
    localparam int N_SETS          = 32;    // Number of sets
    localparam int N_WAYS          = 64;    // Ways per set
    localparam int N_ENTRIES       = N_SETS * N_WAYS;  // Total entries = 2048

    localparam int SET_IDX_W       = $clog2(N_SETS);    //  5
    localparam int WAY_IDX_W       = $clog2(N_WAYS);    //  6
    localparam int ENTRY_IDX_W     = SET_IDX_W + WAY_IDX_W; // 11

    //=========================================================================
    // Field Width Parameters
    //=========================================================================
    localparam int PV_WIDTH        = 1;    // PASID Valid flag (1=valid, 0=ignore)
    localparam int PASID_WIDTH     = 20;   // PCIe standard PASID width
    localparam int FUNC_ID_WIDTH   = 16;
    localparam int VA_WIDTH        = 64;
    localparam int PA_WIDTH        = 64;
    localparam int STU_WIDTH       = 5;
    localparam int PERM_WIDTH      = 4;
    localparam int NRU_HINT_W      = 2;

    //=========================================================================
    // Pipeline & Timing Parameters
    //=========================================================================
    localparam int PIPELINE_STAGES   = 3;   // S0, S1, S2
    localparam int DUPCHECK_CYCLES   = 4;   // 8 sets per cycle
    localparam int DUPCHECK_SETS_PER = N_SETS / DUPCHECK_CYCLES;  // 8
    localparam int NRU_DECAY_INTERVAL   = 1024;  // Cycles between NRU decay
    localparam int ATS_TOGGLE_CLEANUP_CYCLES = 4; // Cycles for ATS toggle inval
    localparam int FLR_CLEANUP_CYCLES       = 4; // Cycles for FLR inval

    //=========================================================================
    // Partition Parameters
    //=========================================================================
    localparam int N_USER_W          = 3;    // config register width (3-bit)
    localparam int PART_1            = 0;    // 1 user  (2048 entries/user)
    localparam int PART_2            = 1;    // 2 users (1024 entries/user)
    localparam int PART_4            = 2;    // 4 users (512 entries/user)
    localparam int PART_8            = 3;    // 8 users (256 entries/user)
    localparam int PART_16           = 4;    // 16 users (128 entries/user)
    localparam int PART_32           = 5;    // 32 users (64 entries/user)
    localparam int PART_64           = 6;    // 64 users (32 entries/user)
    localparam int PART_48           = 7;    // 48 users: reuses 64-way HW (48×32=1536 entries used)
    localparam int PART_MAX          = 7;    // max partition index

    //=========================================================================
    // 64K Pre-lookup
    //=========================================================================
    localparam logic [VA_WIDTH-1:0] LOOKAHEAD_OFFSET = 64'h0001_0000; // 64KB

    //=========================================================================
    // Prefetch offset table: 17 addresses (current + 16 prefetch at 4KB steps)
    //=========================================================================
    localparam int PREFETCH_COUNT = 17;
    localparam int PREFETCH_IDX_W = $clog2(PREFETCH_COUNT);  // 5 bits
    localparam logic [PREFETCH_COUNT-1:0][VA_WIDTH-1:0] PREFETCH_OFFSETS = '{
        64'h0000_0000_0000_0000,  // +0   (current addr)
        64'h0000_0000_0000_1000,  // +4KB
        64'h0000_0000_0000_2000,  // +8KB
        64'h0000_0000_0000_3000,  // +12KB
        64'h0000_0000_0000_4000,  // +16KB
        64'h0000_0000_0000_5000,  // +20KB
        64'h0000_0000_0000_6000,  // +24KB
        64'h0000_0000_0000_7000,  // +28KB
        64'h0000_0000_0000_8000,  // +32KB
        64'h0000_0000_0000_9000,  // +36KB
        64'h0000_0000_0000_A000,  // +40KB
        64'h0000_0000_0000_B000,  // +44KB
        64'h0000_0000_0000_C000,  // +48KB
        64'h0000_0000_0000_D000,  // +52KB
        64'h0000_0000_0000_E000,  // +56KB
        64'h0000_0000_0000_F000,  // +60KB
        64'h0000_0001_0000_0000   // +64KB
    };

    //=========================================================================
    // Entry Storage Bit Layout
    //=========================================================================
    // | valid | PV  | PASID  | FuncID | untranslated_addr | STU | translated_addr | perm | nru  |
    // |   1   | 16  |   16   |   16   |        64         |  5  |       64        |  4   |  2   |
    // Total: 1+16+16+16+64+5+64+4+2 = 188 bits
    //=========================================================================
    localparam int ENTRY_VALID_MSB    = 176;
    localparam int ENTRY_VALID_LSB    = 176;
    localparam int ENTRY_PV_MSB       = 175;
    localparam int ENTRY_PV_LSB       = 175;
    localparam int ENTRY_PASID_MSB    = 174;
    localparam int ENTRY_PASID_LSB    = 155;
    localparam int ENTRY_FUNCID_MSB   = 154;
    localparam int ENTRY_FUNCID_LSB   = 139;
    localparam int ENTRY_VA_MSB       = 138;
    localparam int ENTRY_VA_LSB       = 75;
    localparam int ENTRY_STU_MSB      = 74;
    localparam int ENTRY_STU_LSB      = 70;
    localparam int ENTRY_PA_MSB       = 69;
    localparam int ENTRY_PA_LSB       = 6;
    localparam int ENTRY_PERM_MSB     = 5;
    localparam int ENTRY_PERM_LSB     = 2;
    localparam int ENTRY_NRU_MSB      = 1;
    localparam int ENTRY_NRU_LSB      = 0;
    localparam int ENTRY_WIDTH        = 177;

    //=========================================================================
    // Split storage: TAG (register file) vs DATA (SRAM)
    // TAG = valid + PV + PASID + FuncID + VA + STU → 1+16+16+16+64+5 = 118b
    // DATA = translated_addr + perm → 64+4 = 68b (NRU is separate, 2b in reg)
    //=========================================================================
    localparam int TAG_WIDTH         = 118;  // Tag fields for comparison
    localparam int DATA_WIDTH        = 68;   // Data fields (translated_addr + perm)
    localparam int SRAM_DEPTH        = 2048; // N_ENTRIES
    localparam int SRAM_ADDR_W       = ENTRY_IDX_W;  // 11-bit address

    //=========================================================================
    // Hit Vector Width (64 ways × 2 addresses: addr + addr+64K)
    //=========================================================================
    // For 64K pre-lookup, we maintain a separate hit vector for addr+64K hits.
    // Primary hit vector: 64 bits (hit_h register)
    // Pre-lookup hit vector: 64 bits (hit_pre_h register)
    // Combined: both available to atc_ctrl, 128b total if flattened
    localparam int HIT_VEC_W = N_WAYS;  // 64 bits per address comparison

    //=========================================================================
    // Typedefs
    //=========================================================================

    // Request types for arbitration
    typedef enum logic [2:0] {
        REQ_LOOKUP    = 3'b000,
        REQ_INSERT    = 3'b001,
        REQ_INVALIDATE = 3'b010,
        REQ_ATS_TOGGLE = 3'b011,
        REQ_FLR       = 3'b100,
        REQ_RELOOK    = 3'b101     // second lookup, no prefetch
    } req_type_t;

    // NRU state encoding
    typedef enum logic [NRU_HINT_W-1:0] {
        NRU_FREE     = 2'b01,  // used=0, not_last=1  → preferred victim
        NRU_IDLE     = 2'b00,  // used=0, not_last=0
        NRU_ACTIVE   = 2'b11,  // used=1, not_last=1  → recently used
        NRU_PROTECT  = 2'b10   // used=1, not_last=0  → keep
    } nru_state_t;

    // Lookup request payload (DMA → atc_ctrl)
    typedef struct packed {
        logic [PV_WIDTH-1:0]      pv;
        logic [PASID_WIDTH-1:0]   pasid;
        logic [FUNC_ID_WIDTH-1:0] func_id;
        logic [VA_WIDTH-1:0]      untranslated_addr;
    } lu_request_t;

    // Lookup response (atc_ctrl → DMA)
    typedef struct packed {
        logic                      valid;
        logic                      hit;
        logic [PA_WIDTH-1:0]       translated_addr;
        logic [PERM_WIDTH-1:0]     perm;
        logic [PV_WIDTH-1:0]       hit_pv;
        logic                      pre_hit;  // 64K pre-lookup hit
    } lu_response_t;

    // ATS Translation Completion (from RC TA)
    typedef struct packed {
        logic [PV_WIDTH-1:0]      pv;
        logic [PASID_WIDTH-1:0]   pasid;
        logic [FUNC_ID_WIDTH-1:0] func_id;
        logic [VA_WIDTH-1:0]      untranslated_addr;
        logic [PA_WIDTH-1:0]      translated_addr;
        logic [STU_WIDTH-1:0]     stu;
        logic [PERM_WIDTH-1:0]    perm;
    } ats_completion_t;

    // ATS Invalidation Request (from RC)
    typedef struct packed {
        logic [FUNC_ID_WIDTH-1:0] inv_mask;
        logic [PV_WIDTH-1:0]      pv;
        logic                     pv_valid;   // from ATS Inv request context
        logic [PASID_WIDTH-1:0]   pasid;
        logic [FUNC_ID_WIDTH-1:0] func_id;
        logic [VA_WIDTH-1:0]      untranslated_addr;
    } ats_inv_req_t;

    // Duplicate check input payload
    typedef struct packed {
        logic [PV_WIDTH-1:0]      pv;
        logic [PASID_WIDTH-1:0]   pasid;
        logic [FUNC_ID_WIDTH-1:0] func_id;
        logic [VA_WIDTH-1:0]      untranslated_addr;
        logic [STU_WIDTH-1:0]     stu;
    } dupcheck_payload_t;

    // Entry tag (for comparison — excludes data fields)
    typedef struct packed {
        logic                      valid;
        logic [PV_WIDTH-1:0]       pv;
        logic [PASID_WIDTH-1:0]    pasid;
        logic [FUNC_ID_WIDTH-1:0]  func_id;
        logic [VA_WIDTH-1:0]       untranslated_addr;
        logic [STU_WIDTH-1:0]      stu;
    } entry_tag_t;

    // Entry data (read after hit)
    typedef struct packed {
        logic [PA_WIDTH-1:0]       translated_addr;
        logic [PERM_WIDTH-1:0]     perm;
        logic [NRU_HINT_W-1:0]     nru;
    } entry_data_t;

    // Full entry
    typedef struct packed {
        logic                      valid;
        logic [PV_WIDTH-1:0]       pv;
        logic [PASID_WIDTH-1:0]    pasid;
        logic [FUNC_ID_WIDTH-1:0]  func_id;
        logic [VA_WIDTH-1:0]       untranslated_addr;
        logic [STU_WIDTH-1:0]      stu;
        logic [PA_WIDTH-1:0]       translated_addr;
        logic [PERM_WIDTH-1:0]     perm;
        logic [NRU_HINT_W-1:0]     nru;
    } entry_full_t;

    // Pipeline Stage 0: request dispatch
    typedef struct packed {
        logic                      valid;
        req_type_t                 req_type;
        logic [SET_IDX_W-1:0]      set_idx;
        // Lookup fields
        logic [PV_WIDTH-1:0]       lu_pv;
        logic [PASID_WIDTH-1:0]    lu_pasid;
        logic [FUNC_ID_WIDTH-1:0]  lu_func_id;
        logic [VA_WIDTH-1:0]       lu_va;
        // Insert fields
        logic [WAY_IDX_W-1:0]      ins_way_idx;
        entry_full_t               ins_entry;
        // Invalidate fields
        ats_inv_req_t              inv_req;
        // DupCheck fields
        dupcheck_payload_t         dup_payload;
    } pipe_s0_t;

    // Pipeline Stage 1: access + compare
    typedef struct packed {
        logic                      valid;
        req_type_t                 req_type;
        logic [SET_IDX_W-1:0]      set_idx;
        // Hit vectors from set comparison
        logic [HIT_VEC_W-1:0]      hit_vector;      // addr match
        logic [HIT_VEC_W-1:0]      hit_pre_vector;  // addr+64K match
        // Data from all ways (for mux after hit)
        logic [N_WAYS-1:0][PA_WIDTH-1:0] way_pas;
        logic [N_WAYS-1:0][PERM_WIDTH-1:0] way_perms;
        logic [N_WAYS-1:0][PV_WIDTH-1:0]   way_pvs;
        logic [N_WAYS-1:0]                  way_valids;
        // Insert / Invalidate / DupCheck carry
        logic [WAY_IDX_W-1:0]      ins_way_idx;
        entry_full_t               ins_entry;
        ats_inv_req_t              inv_req;
        dupcheck_payload_t         dup_payload;
        logic                      dupcheck_phase;  // which phase of dupcheck
        logic [2:0]                dupcheck_subset; // which subset (0-3)
    } pipe_s1_t;

    // Pipeline Stage 2: result collection + response
    typedef struct packed {
        logic                      valid;
        req_type_t                 req_type;
        logic                      hit;
        logic                      pre_hit;
        logic [PA_WIDTH-1:0]       translated_addr;
        logic [PERM_WIDTH-1:0]     perm;
        logic [PV_WIDTH-1:0]       hit_pv;
        logic [ENTRY_IDX_W-1:0]    hit_entry_idx;
        // Insert result
        logic                      insert_done;
        // Invalidate result
        logic                      inv_valid;
        logic [ENTRY_IDX_W-1:0]    inv_hit_idx;
        // DupCheck result
        logic                      duplicate;
        logic [ENTRY_IDX_W-1:0]    dup_entry_idx;
    } pipe_s2_t;

    //=========================================================================
    // Partition Helper Functions
    //=========================================================================

    // Convert partition encoding to number of users
    function automatic int num_users_from_part(logic [N_USER_W-1:0] part);
        case (part)
            PART_1:  num_users_from_part = 1;
            PART_2:  num_users_from_part = 2;
            PART_4:  num_users_from_part = 4;
            PART_8:  num_users_from_part = 8;
            PART_16: num_users_from_part = 16;
            PART_32: num_users_from_part = 32;
            PART_64: num_users_from_part = 64;
            PART_48: num_users_from_part = 48;
            default: num_users_from_part = 1;
        endcase
    endfunction

    // Number of full sets owned by each user
    function automatic int get_sets_per_user(logic [N_USER_W-1:0] part);
        int n = num_users_from_part(part);
        get_sets_per_user = (n <= 32) ? N_SETS / n : N_SETS;
    endfunction

    // Number of ways per user within a shared set
    // For n>32: ways_per_user = N_WAYS / ceil(n/N_SETS)
    function automatic int get_ways_per_user(logic [N_USER_W-1:0] part);
        int n = num_users_from_part(part);
        int users_per_set = (n + N_SETS - 1) / N_SETS;  // ceil division
        get_ways_per_user = (n > 32) ? N_WAYS / users_per_set : N_WAYS;
    endfunction

    // Base set index for user k
    function automatic logic [SET_IDX_W-1:0] get_user_set_base(
        logic [N_USER_W-1:0] part, int user_id
    );
        int n = num_users_from_part(part);
        int sets_per = get_sets_per_user(part);
        get_user_set_base = SET_IDX_W'(user_id * sets_per);
    endfunction

    // Base way index for user k (only meaningful when ways_per_user < N_WAYS)
    function automatic logic [WAY_IDX_W-1:0] get_user_way_base(
        logic [N_USER_W-1:0] part, int user_id
    );
        int n = num_users_from_part(part);
        int users_per_set = (n + N_SETS - 1) / N_SETS;  // ceil division
        get_user_way_base = (n > 32) ?
            WAY_IDX_W'((user_id % users_per_set) * get_ways_per_user(part)) : '0;
    endfunction

    // Way limit (exclusive) for user k (7-bit to hold value 64)
    function automatic logic [WAY_IDX_W:0] get_user_way_limit(
        logic [N_USER_W-1:0] part, int user_id
    );
        int n = num_users_from_part(part);
        int users_per_set = (n + N_SETS - 1) / N_SETS;  // ceil division
        if (n <= 32) return N_WAYS;  // 64
        get_user_way_limit = (WAY_IDX_W'(user_id % users_per_set) + 1)
            * get_ways_per_user(part);
    endfunction

    // Set limit (exclusive) for user k
    function automatic logic [SET_IDX_W-1:0] get_user_set_limit(
        logic [N_USER_W-1:0] part, int user_id
    );
        int sets_per = get_sets_per_user(part);
        get_user_set_limit = SET_IDX_W'((user_id + 1) * sets_per);
    endfunction

    // Partition-aware hash: maps raw hash to user's set range
    function automatic logic [SET_IDX_W-1:0] partition_hash(
        logic [N_USER_W-1:0] part, int user_id,
        logic [FUNC_ID_WIDTH-1:0] func_id,
        logic [VA_WIDTH-1:0] va
    );
        logic [SET_IDX_W-1:0] raw_hash;
        logic [SET_IDX_W-1:0] base;
        int sets_per;
        raw_hash  = SET_IDX_W'((func_id[3:0] ^ va[15:12]) & 5'h1F);
        sets_per  = get_sets_per_user(part);
        if (sets_per >= N_SETS) begin
            partition_hash = raw_hash;
        end else begin
            base = get_user_set_base(part, user_id);
            partition_hash = base + SET_IDX_W'(raw_hash % (SET_IDX_W'(sets_per)));
        end
    endfunction

    //=========================================================================
    // Helper Functions
    //=========================================================================

    // Compute STU-based address mask and apply it
    function automatic logic [VA_WIDTH-1:0] apply_stu_mask(
        logic [VA_WIDTH-1:0] addr,
        logic [STU_WIDTH-1:0] stu
    );
        // Generate mask: bits below STU are masked to 0
        // mask = ~((1 << stu) - 1)
        logic [VA_WIDTH-1:0] mask;
        mask = ~((64'd1 << stu) - 64'd1);
        apply_stu_mask = addr & mask;
    endfunction

    // Extract tag from full entry
    function automatic entry_tag_t entry_to_tag(entry_full_t e);
        entry_to_tag.valid            = e.valid;
        entry_to_tag.pv               = e.pv;
        entry_to_tag.pasid            = e.pasid;
        entry_to_tag.func_id          = e.func_id;
        entry_to_tag.untranslated_addr = e.untranslated_addr;
        entry_to_tag.stu              = e.stu;
    endfunction

    // Extract data from full entry
    function automatic entry_data_t entry_to_data(entry_full_t e);
        entry_to_data.translated_addr = e.translated_addr;
        entry_to_data.perm            = e.perm;
        entry_to_data.nru             = e.nru;
    endfunction

    // Pack full entry to flat bits (for synthesized storage)
    function automatic logic [ENTRY_WIDTH-1:0] pack_entry(entry_full_t e);
        logic [ENTRY_WIDTH-1:0] flat;
        flat[ENTRY_VALID_MSB:ENTRY_VALID_LSB] = {1{e.valid}};
        flat[ENTRY_PV_MSB:ENTRY_PV_LSB]       = e.pv;
        flat[ENTRY_PASID_MSB:ENTRY_PASID_LSB] = e.pasid;
        flat[ENTRY_FUNCID_MSB:ENTRY_FUNCID_LSB] = e.func_id;
        flat[ENTRY_VA_MSB:ENTRY_VA_LSB]       = e.untranslated_addr;
        flat[ENTRY_STU_MSB:ENTRY_STU_LSB]     = e.stu;
        flat[ENTRY_PA_MSB:ENTRY_PA_LSB]       = e.translated_addr;
        flat[ENTRY_PERM_MSB:ENTRY_PERM_LSB]   = e.perm;
        flat[ENTRY_NRU_MSB:ENTRY_NRU_LSB]     = e.nru;
        return flat;
    endfunction

    // Unpack flat bits to full entry
    function automatic entry_full_t unpack_entry(logic [ENTRY_WIDTH-1:0] flat);
        entry_full_t e;
        e.valid            = flat[ENTRY_VALID_MSB];
        e.pv               = flat[ENTRY_PV_MSB:ENTRY_PV_LSB];
        e.pasid            = flat[ENTRY_PASID_MSB:ENTRY_PASID_LSB];
        e.func_id          = flat[ENTRY_FUNCID_MSB:ENTRY_FUNCID_LSB];
        e.untranslated_addr = flat[ENTRY_VA_MSB:ENTRY_VA_LSB];
        e.stu              = flat[ENTRY_STU_MSB:ENTRY_STU_LSB];
        e.translated_addr  = flat[ENTRY_PA_MSB:ENTRY_PA_LSB];
        e.perm             = flat[ENTRY_PERM_MSB:ENTRY_PERM_LSB];
        e.nru              = flat[ENTRY_NRU_MSB:ENTRY_NRU_LSB];
        return e;
    endfunction

endpackage : atc_pkg
