#!/bin/bash
#=============================================================================
# run_cov.sh — ATC Module Simulation & Code Coverage Collection
#
# Usage:
#   ./run_cov.sh                    # Full: compile + sim + report
#   ./run_cov.sh compile            # Compile only
#   ./run_cov.sh sim                # Sim only (requires prior compile)
#   ./run_cov.sh report             # Generate coverage report from existing DB
#   ./run_cov.sh all                # Full pipeline (same as no args)
#   ./run_cov.sh quick              # Fast smoke test with coverage (100 ops)
#
# Environment:
#   VCS_HOME   /usr/Synopsys/vcs/T-2022.06
#   DC_HOME    /usr/Synopsys/syn/T-2022.03-SP2
#=============================================================================
set -e

# --- Configuration ---------------------------------------------------------
VCS_BIN="/usr/Synopsys/vcs/T-2022.06/bin"
DC_BIN="/usr/Synopsys/syn/T-2022.03-SP2/bin"
PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$RTL_DIR/tb"
COV_DIR="$PROJ_DIR/coverage"
VDB_DIR="$COV_DIR/cov_data"
RPT_DIR="$COV_DIR/report"

# Coverage configuration
COV_METRICS="line+cond+fsm+branch"               # metrics to collect
COV_NAME="atc_full"                               # test name in DB
SIM_TIMEOUT="300"                                 # seconds
RND_OPS="10000"                                   # random test iterations

# File lists
RTL_FILES="\
  $RTL_DIR/atc_pkg.sv \
  $RTL_DIR/atc_entry_tag.sv \
  $RTL_DIR/atc_data_sram.sv \
  $RTL_DIR/atc_nru_replacer.sv \
  $RTL_DIR/atc_csr_if.sv \
  $RTL_DIR/atc_req_arbiter.sv \
  $RTL_DIR/atc_set.sv \
  $RTL_DIR/atc_dupcheck.sv \
  $RTL_DIR/atc_lookup_engine.sv \
  $RTL_DIR/atc_inv_handler.sv \
  $RTL_DIR/atc_entry_array.sv \
  $RTL_DIR/atc_ctrl.sv \
  $RTL_DIR/atc_top.sv"

TB_FILES="\
  $TB_DIR/atc_test_pkg.sv \
  $TB_DIR/atc_if.sv \
  $TB_DIR/atc_scoreboard.sv \
  $TB_DIR/atc_monitor.sv \
  $TB_DIR/atc_cov.sv \
  $TB_DIR/ats_agent.sv \
  $TB_DIR/csr_agent.sv \
  $TB_DIR/dma_agent.sv \
  $TB_DIR/atc_checker.sv \
  $TB_DIR/tb_atc_top.sv"

# --- Functions -------------------------------------------------------------
check_tools() {
    if [ ! -x "$VCS_BIN/vcs" ]; then
        echo "ERROR: VCS not found at $VCS_BIN/vcs"
        exit 1
    fi
    echo "[OK] VCS:  $(ls $VCS_BIN/vcs)"
    echo "[OK] URG:  $(ls $VCS_BIN/urg 2>/dev/null || echo 'not found')"
}

setup_dirs() {
    mkdir -p "$COV_DIR" "$VDB_DIR" "$RPT_DIR"
    # Clean previous artifacts (optional, comment out to keep)
    rm -rf "$VDB_DIR" "$RPT_DIR"/*
    rm -rf "$PROJ_DIR/simv" "$PROJ_DIR/simv.daidir" "$PROJ_DIR/csrc"
}

# --- Compile Phase ---------------------------------------------------------
do_compile() {
    echo ""
    echo "=============================================="
    echo "  Phase 1: VCS Compile (Coverage Mode)"
    echo "  Metrics: $COV_METRICS"
    echo "=============================================="
    cd "$PROJ_DIR"

    # Hierarchical coverage filter: DUT only, exclude testbench
    cat > "$COV_DIR/cm_hier.conf" << 'CMEOF'
+tree tb_atc_top.u_dut 0
CMEOF

    local GITHASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local COMPILE_LOG="$COV_DIR/compile_${TIMESTAMP}.log"

    echo "  RTL files: $(echo $RTL_FILES | wc -w)"
    echo "  TB  files: $(echo $TB_FILES | wc -w)"
    echo "  Log: $COMPILE_LOG"

    $VCS_BIN/vcs -full64 -sverilog +v2k \
      -timescale=1ps/1ps \
      -debug_access+all \
      -assert svaext \
      -cm "$COV_METRICS" \
      -cm_dir "$VDB_DIR" \
      -cm_name "$COV_NAME" \
      -cm_hier "$COV_DIR/cm_hier.conf" \
      +incdir+"$RTL_DIR" +incdir+"$TB_DIR" \
      $RTL_FILES $TB_FILES \
      -top tb_atc_top \
      -o "$PROJ_DIR/simv" \
      -l "$COMPILE_LOG" 2>&1 | tail -5

    if [ $? -ne 0 ]; then
        echo "ERROR: Compilation failed. See $COMPILE_LOG"
        exit 1
    fi
    echo "[OK]  Compilation complete: $PROJ_DIR/simv"
    echo "  Log: $COMPILE_LOG"
}

# --- Simulation Phase ------------------------------------------------------
do_sim() {
    echo ""
    echo "=============================================="
    echo "  Phase 2: VCS Simulation"
    echo "=============================================="
    cd "$PROJ_DIR"

    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local SIM_LOG="$COV_DIR/sim_${TIMESTAMP}.log"
    local SIM_OUT="$COV_DIR/sim_${TIMESTAMP}.txt"

    echo "  Database: $VDB_DIR"
    echo "  Test:    $COV_NAME"
    echo "  Timeout: ${SIM_TIMEOUT}s"
    echo "  Log:     $SIM_LOG"

    timeout "$SIM_TIMEOUT" "$PROJ_DIR/simv" \
      +vcs+lic+wait \
      -cm_dir "$VDB_DIR" \
      -cm_name "$COV_NAME" \
      -l "$SIM_LOG" 2>&1 | tee "$SIM_OUT"

    local ret=$?
    if [ $ret -eq 124 ]; then
        echo "WARNING: Simulation timed out after ${SIM_TIMEOUT}s"
        return 1
    elif [ $ret -ne 0 ]; then
        echo "ERROR: Simulation failed with exit code $ret"
        return 1
    fi

    # Quick pass/fail summary
    echo ""
    echo "--- Test Results ---"
    grep -c "PASSED" "$SIM_OUT" 2>/dev/null && echo " tests passed"
    grep -c "FAILED\|Error:" "$SIM_OUT" 2>/dev/null && echo " failures"
    grep "RESULT:" "$SIM_OUT" 2>/dev/null

    echo "[OK]  Simulation complete"
    echo "  Database: $VDB_DIR"
    echo "  Log:      $SIM_LOG"
}

# --- Coverage Report Phase -------------------------------------------------
do_report() {
    echo ""
    echo "=============================================="
    echo "  Phase 3: Coverage Report Generation"
    echo "=============================================="
    cd "$PROJ_DIR"

    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local URG_LOG="$COV_DIR/urg_${TIMESTAMP}.log"

    echo "  Source:  $VDB_DIR"
    echo "  Output:  $RPT_DIR"
    echo "  Log:     $URG_LOG"

    # Check if coverage DB exists
    if [ ! -d "$VDB_DIR/snps" ]; then
        echo "ERROR: Coverage database not found at $VDB_DIR"
        echo "  Run './run_cov.sh sim' first to generate coverage data."
        exit 1
    fi

    # Generate text report
    echo "  Generating text report..."
    $VCS_BIN/urg -dir "$VDB_DIR" \
      -report "$RPT_DIR" \
      -metric "$COV_METRICS" \
      -format text \
      -show tests \
      -show modules \
      -nologo \
      -l "$URG_LOG" 2>&1 || true

    # Check if report was generated (URG may crash on large designs)
    if [ -f "$RPT_DIR/dashboard.html" ] || [ -f "$RPT_DIR/test.txt" ]; then
        echo "[OK]  Report generated: $RPT_DIR"
        if [ -f "$RPT_DIR/dashboard.html" ]; then
            echo "  HTML: $RPT_DIR/dashboard.html"
        fi

        # Extract summary from text report
        echo ""
        echo "--- Coverage Summary ---"
        for f in "$RPT_DIR"/*.txt; do
            if [ -f "$f" ]; then
                echo "  $(basename $f)"
                head -30 "$f" | grep -E "Total|Coverage|Score|%" 2>/dev/null || true
            fi
        done
    else
        echo "WARNING: URG did not generate a report (may have crashed)."
        echo "  Coverage data is still available at: $VDB_DIR"
        echo ""
        echo "  To try again with different options:"
        echo "    $VCS_BIN/urg -dir $VDB_DIR -report $RPT_DIR -metric line -format text"
        echo ""
        echo "  To view in DVE (if installed):"
        echo "    dve -full64 -cov -dir $VDB_DIR"
    fi
}

# --- Quick Mode ------------------------------------------------------------
do_quick() {
    echo "=== Quick Coverage Test (100 random ops) ==="

    # Temporarily modify the testbench to run fewer random ops
    local TB_BACKUP="$PROJ_DIR/rtl/tb/tb_atc_top_backup.sv"
    cp "$PROJ_DIR/rtl/tb/tb_atc_top.sv" "$TB_BACKUP"
    sed -i 's/run_test_random(10000)/run_test_random(100)/' \
        "$PROJ_DIR/rtl/tb/tb_atc_top.sv"

    RND_OPS="100"
    SIM_TIMEOUT="60"

    do_compile
    do_sim
    do_report

    # Restore original testbench
    mv "$TB_BACKUP" "$PROJ_DIR/rtl/tb/tb_atc_top.sv"
    echo "[OK] Original testbench restored"
}

# --- Main ------------------------------------------------------------------
main() {
    local mode="${1:-all}"

    echo "=============================================="
    echo "  ATC Coverage Collection Script"
    echo "  Project: $PROJ_DIR"
    echo "  Date:    $(date)"
    echo "  Mode:    $mode"
    echo "=============================================="

    check_tools
    setup_dirs

    case "$mode" in
        compile)
            do_compile
            ;;
        sim)
            do_sim
            ;;
        report)
            do_report
            ;;
        quick)
            do_quick
            ;;
        all|"")
            do_compile
            do_sim
            do_report
            ;;
        *)
            echo "Usage: $0 {compile|sim|report|quick|all}"
            echo ""
            echo "  compile  - Compile RTL + TB with coverage instrumentation"
            echo "  sim      - Run simulation, collect coverage data"
            echo "  report   - Generate coverage report from existing data"
            echo "  quick    - Fast smoke test (100 random ops)"
            echo "  all      - Full pipeline (compile + sim + report)"
            exit 1
            ;;
    esac

    echo ""
    echo "=============================================="
    echo "  Coverage Collection Complete"
    echo "  Coverage DB:   $VDB_DIR"
    echo "  Coverage Rpt:  $RPT_DIR"
    echo "  Compile Logs:  $COV_DIR/compile_*.log"
    echo "  Sim Logs:      $COV_DIR/sim_*.log"
    echo "=============================================="
}

main "$@"
