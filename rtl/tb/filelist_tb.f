//=============================================================================
// ATC Verification Compilation Filelist
//=============================================================================

+incdir+../

// RTL Design files (DUT)
../atc_pkg.sv
../atc_entry_tag.sv
../atc_data_sram.sv
../atc_nru_replacer.sv
../atc_csr_if.sv
../atc_req_arbiter.sv
../atc_set.sv
../atc_dupcheck.sv
../atc_lookup_engine.sv
../atc_inv_handler.sv
../atc_entry_array.sv
../atc_ctrl.sv
../atc_top.sv

// Verification files
./atc_test_pkg.sv
./atc_if.sv
./atc_scoreboard.sv
./atc_monitor.sv
./atc_checker.sv
./atc_cov.sv
./dma_agent.sv
./ats_agent.sv
./csr_agent.sv
./tb_atc_top.sv
