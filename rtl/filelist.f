//=============================================================================
// ATC RTL Compilation Filelist (Verilog-2001, TAG/SRAM split architecture)
// Target: SF4X @ 1GHz, EP-side ATC Controller
//=============================================================================

+incdir+.

// 1. Defines header (must be included first)
atc_defines.vh

// 2. Leaf modules (no internal dependencies)
atc_entry_tag.v            // TAG-only storage + compare
atc_data_sram.v            // Behavioral SRAM wrapper (2048×68b)
atc_nru_replacer.v         // NRU replacement logic
atc_csr_if.v               // CSR edge-detect + sync
atc_req_arbiter.v          // Priority arbiter

// 3. Mid-level modules
atc_set.v                  // 64×atc_entry_tag + hit encoder + SRAM addr
atc_dupcheck.v             // 4-cycle duplicate check (tag-only read)
atc_lookup_engine.v        // 3-stage pipeline (SRAM data read)
atc_inv_handler.v          // 3-mode invalidation handler

// 4. Array + SRAM (depends on atc_set + atc_data_sram)
atc_entry_array.v          // 32×atc_set + 1×atc_data_sram

// 5. Controller (depends on all mid-level)
atc_ctrl.v                 // Central controller with TAG/SRAM split

// 6. Top (depends on all)
atc_top.v                  // Top-level integration
