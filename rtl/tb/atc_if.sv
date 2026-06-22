//=============================================================================
// atc_if.sv — ATC Verification Interface
// Bundles all DUT signals into a single interface for agent connections
//=============================================================================
interface atc_if (input logic clk, input logic rst_n);

    import atc_pkg::*;

    // ---- DMA Lookup Request ----
    logic                         dma_lu_req_valid;
    logic [PV_WIDTH-1:0]          dma_lu_req_pv;
    logic [PASID_WIDTH-1:0]       dma_lu_req_pasid;
    logic [FUNC_ID_WIDTH-1:0]     dma_lu_req_func_id;
    logic [VA_WIDTH-1:0]          dma_lu_req_addr;

    // ---- DMA Lookup Response ----
    logic                         dma_lu_rsp_valid;
    logic                         dma_lu_rsp_hit;
    logic [PA_WIDTH-1:0]          dma_lu_rsp_translated_addr;
    logic [PERM_WIDTH-1:0]        dma_lu_rsp_perm;
    logic                         dma_lu_req_ready;

    // ---- DMA Relook Response ----
    logic                         dma_rl_rsp_valid;
    logic                         dma_rl_rsp_hit;
    logic [PA_WIDTH-1:0]          dma_rl_rsp_translated_addr;
    logic [PERM_WIDTH-1:0]        dma_rl_rsp_perm;
    logic                         dma_rl_req_ready;

    // ---- ATS Completion (Insert) ----
    logic                         ats_comp_valid;
    logic [PV_WIDTH-1:0]          ats_comp_pv;
    logic [PASID_WIDTH-1:0]       ats_comp_pasid;
    logic [FUNC_ID_WIDTH-1:0]     ats_comp_func_id;
    logic [VA_WIDTH-1:0]          ats_comp_untranslated_addr;
    logic [PA_WIDTH-1:0]          ats_comp_translated_addr;
    logic [STU_WIDTH-1:0]         ats_comp_stu;
    logic [PERM_WIDTH-1:0]        ats_comp_perm;

    // ---- ATS Invalidation ----
    logic                         ats_inv_req_valid;
    logic [FUNC_ID_WIDTH-1:0]     ats_inv_mask;
    logic                         ats_inv_pv_valid;
    logic [PV_WIDTH-1:0]          ats_inv_pv;
    logic [PASID_WIDTH-1:0]       ats_inv_pasid;
    logic [FUNC_ID_WIDTH-1:0]     ats_inv_func_id;
    logic [VA_WIDTH-1:0]          ats_inv_untranslated_addr;
    logic                         ats_inv_ack_valid;
    logic                         ats_inv_req_ready;
    logic                         ats_comp_ready;

    // ---- CSR ----
    logic [65:0]                  csr_ats_enable;   // per-function ATS enable bits
    logic [65:0]                  csr_prefetch_enable; // per-function prefetch enable
    logic                         csr_flr_req;
    logic [FUNC_ID_WIDTH-1:0]     csr_flr_func_id;
    logic                         csr_flr_req_done;
    logic [N_USER_W-1:0]          csr_num_users;

    // ---- Prefetch Outputs ----
    logic [15:0]                  prefetch_hit;
    logic [15:0][PA_WIDTH-1:0]   prefetch_pa;
    logic [15:0][PERM_WIDTH-1:0] prefetch_perm;
    logic [15:0]                  prefetch_rsp_valid;

    // ---- Status ----
    logic                         atc_active;
    logic [ENTRY_IDX_W-1:0]       atc_entry_count;

    //=========================================================================
    // Clocking Blocks for Driver / Monitor
    //=========================================================================

    // DMA clocking block (driver perspective)
    clocking dma_drv_cb @(posedge clk);
        output dma_lu_req_valid, dma_lu_req_pv, dma_lu_req_pasid,
               dma_lu_req_func_id, dma_lu_req_addr;
        input  dma_lu_rsp_valid, dma_lu_rsp_hit,
               dma_lu_rsp_translated_addr, dma_lu_rsp_perm,
               dma_lu_req_ready;
    endclocking

    // DMA monitor clocking block
    clocking dma_mon_cb @(posedge clk);
        input dma_lu_req_valid, dma_lu_req_pv, dma_lu_req_pasid,
              dma_lu_req_func_id, dma_lu_req_addr,
              dma_lu_rsp_valid, dma_lu_rsp_hit,
              dma_lu_rsp_translated_addr, dma_lu_rsp_perm,
              dma_lu_req_ready;
    endclocking

    // ATS clocking block (driver)
    clocking ats_drv_cb @(posedge clk);
        output ats_comp_valid, ats_comp_pv, ats_comp_pasid,
               ats_comp_func_id, ats_comp_untranslated_addr,
               ats_comp_translated_addr, ats_comp_stu, ats_comp_perm,
               ats_inv_req_valid, ats_inv_mask, ats_inv_pv_valid,
               ats_inv_pv, ats_inv_pasid, ats_inv_func_id,
               ats_inv_untranslated_addr;
        input  ats_inv_ack_valid;
    endclocking

    // CSR clocking block (driver)
    clocking csr_drv_cb @(posedge clk);
        output csr_ats_enable, csr_flr_req, csr_flr_func_id;
    endclocking

    //=========================================================================
    // Modport declarations
    //=========================================================================
    modport dut (
        input  clk, rst_n,
        input  dma_lu_req_valid, dma_lu_req_pv, dma_lu_req_pasid,
               dma_lu_req_func_id, dma_lu_req_addr,
        output dma_lu_rsp_valid, dma_lu_rsp_hit,
               dma_lu_rsp_translated_addr, dma_lu_rsp_perm,
        input  ats_comp_valid, ats_comp_pv, ats_comp_pasid,
               ats_comp_func_id, ats_comp_untranslated_addr,
               ats_comp_translated_addr, ats_comp_stu, ats_comp_perm,
        input  ats_inv_req_valid, ats_inv_mask, ats_inv_pv_valid,
               ats_inv_pv, ats_inv_pasid, ats_inv_func_id,
               ats_inv_untranslated_addr,
        output ats_inv_ack_valid,
        input  csr_ats_enable, csr_flr_req, csr_flr_func_id,
        output atc_active, atc_entry_count
    );

    modport dma_drv (clocking dma_drv_cb);
    modport dma_mon (clocking dma_mon_cb);
    modport ats_drv (clocking ats_drv_cb);
    modport csr_drv (clocking csr_drv_cb);

endinterface : atc_if
