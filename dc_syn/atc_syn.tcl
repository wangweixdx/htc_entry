# =============================================================================
# atc_syn.tcl — DC Synthesis Script for ATC Controller
# Target: SF4X @ 1GHz (GTECH feasibility synthesis)
# =============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set RTL_DIR    [file normalize "$SCRIPT_DIR/../rtl"]
set REPORT_DIR "$SCRIPT_DIR/reports"
set OUTPUT_DIR "$SCRIPT_DIR/outputs"

# Ensure output directories exist
if {![file isdirectory $REPORT_DIR]} { file mkdir $REPORT_DIR }
if {![file isdirectory $OUTPUT_DIR]} { file mkdir $OUTPUT_DIR }

# =============================================================================
# 1. Read & Analyze RTL
# =============================================================================
puts "========== \[1/7\] Reading RTL =========="

# Read in dependency order per filelist.f
set rtl_files [list \
    atc_pkg.sv \
    atc_entry_tag.sv \
    atc_data_sram_syn.sv \
    atc_nru_replacer.sv \
    atc_csr_if.sv \
    atc_req_arbiter.sv \
    atc_set.sv \
    atc_dupcheck.sv \
    atc_lookup_engine.sv \
    atc_inv_handler.sv \
    atc_entry_array.sv \
    atc_ctrl.sv \
    atc_top.sv \
]

set SYN_DIR $SCRIPT_DIR
foreach f $rtl_files {
    # Try RTL dir first, then SYN dir
    if {[file exists "$RTL_DIR/$f"]} {
        set full_path "$RTL_DIR/$f"
    } elseif {[file exists "$SYN_DIR/$f"]} {
        set full_path "$SYN_DIR/$f"
    } else {
        puts "  ERROR: File not found: $f (checked $RTL_DIR and $SYN_DIR)"
        exit 1
    }
    puts "  Reading: $f"
    analyze -format sverilog $full_path
}

# =============================================================================
# 2. Elaborate Top-Level
# =============================================================================
puts "========== \[2/7\] Elaborating atc_top =========="
elaborate atc_top

# Report uniquified design
current_design atc_top
puts "  Current design: [get_object_name [current_design]]"

# =============================================================================
# 3. Timing Constraints (1GHz = 1ns)
# =============================================================================
puts "========== \[3/7\] Applying Constraints =========="

# Clock: 1GHz -> 1ns period, 50% duty
set CLK_NAME       "clk"
set CLK_PERIOD     1.0
set CLK_UNCERT     0.05
set CLK_LATENCY    0.05
set CLK_TRANS      0.02
set INPUT_DELAY    0.2
set OUTPUT_DELAY   0.2

# Create clock
create_clock -name $CLK_NAME -period $CLK_PERIOD -waveform {0 0.5} [get_ports clk]
puts "  Clock: $CLK_NAME @ $CLK_PERIOD ns (1GHz)"

# Clock uncertainty (jitter + skew margin)
set_clock_uncertainty $CLK_UNCERT [get_clocks $CLK_NAME]
puts "  Clock uncertainty: ${CLK_UNCERT}ns"

# Clock transition
set_clock_transition $CLK_TRANS [get_clocks $CLK_NAME]

# Clock network latency
set_clock_latency $CLK_LATENCY [get_clocks $CLK_NAME]

# Input/Output delays (conservative estimate)
set_input_delay  -clock $CLK_NAME $INPUT_DELAY  [all_inputs]
set_input_delay  -clock $CLK_NAME $INPUT_DELAY  -clock_fall -add_delay [all_inputs]
set_output_delay -clock $CLK_NAME $OUTPUT_DELAY [all_outputs]

puts "  Input delay:  ${INPUT_DELAY}ns"
puts "  Output delay: ${OUTPUT_DELAY}ns"

# Reset as false path
set_false_path -from [get_ports rst_n]
puts "  False path: rst_n"

# =============================================================================
# 4. Check Design (pre-compile)
# =============================================================================
puts "========== \[4/7\] Pre-compile Checks =========="

redirect "$REPORT_DIR/pre_check.rpt" {
    check_design
    check_timing
}

# =============================================================================
# 5. Compile
# =============================================================================
puts "========== \[5/7\] Unmapped Analysis (skip compile — GTECH OOM) =========="

# Set dont_touch on SRAM black-box instance
if {[sizeof_collection [get_cells -hier *u_data_sram*]] > 0} {
    set_dont_touch [get_cells -hier *u_data_sram*] true
    puts "  dont_touch set on u_data_sram"
}

# Skip gate-level compile (GTECH maps 241K TAG flops → OOM)
# For SF4X real synthesis, use: compile_ultra -gate_clock
# Elaboration-only flow validates RTL is synthesizable

puts "  Skipping gate compile — reporting from elaborated design"

# =============================================================================
# 6. Generate Reports
# =============================================================================
puts "========== \[6/7\] Generating Reports =========="

# Resource estimate (pre-mapped)
redirect -append "$REPORT_DIR/resources.rpt" {
    estimate_resources -hierarchy
}

# Constraints report
redirect "$REPORT_DIR/constraints.rpt" {
    report_constraint -all_violators -verbose
}

# Timing check on unmapped design
redirect "$REPORT_DIR/timing_max.rpt" {
    check_timing -verbose
}

# Hierarchy
redirect "$REPORT_DIR/hierarchy.rpt" {
    report_hierarchy -noleaf -nosplit
}

# Reference list
redirect "$REPORT_DIR/references.rpt" {
    report_reference -hierarchy -nosplit
}

# Area estimate (pre-mapped)
redirect "$REPORT_DIR/area.rpt" {
    estimate_area -hierarchy -nosplit
}

# Cell usage (pre-mapped)
redirect "$REPORT_DIR/cells.rpt" {
    estimate_cells -hierarchy -nosplit
}

# QoR summary
redirect "$REPORT_DIR/qor.rpt" {
    report_qor
}

# Constraints report
redirect "$REPORT_DIR/constraints.rpt" {
    report_constraint -all_violators -verbose
}

# Timing report
redirect "$REPORT_DIR/timing_max.rpt" {
    report_timing -delay max -max_paths 20 -sort_by slack -significant_digits 4
}
redirect "$REPORT_DIR/timing_min.rpt" {
    report_timing -delay min -max_paths 10 -sort_by slack -significant_digits 4
}

# Area report
redirect "$REPORT_DIR/area.rpt" {
    report_area -hierarchy -nosplit
}

# Power report
redirect "$REPORT_DIR/power.rpt" {
    report_power -nosplit
}

# Cell usage
redirect "$REPORT_DIR/cells.rpt" {
    report_cell -nosplit
}

# Resources (DesignWare components used)
redirect "$REPORT_DIR/resources.rpt" {
    report_resources -hierarchy -nosplit
}

# QoR summary
redirect "$REPORT_DIR/qor.rpt" {
    report_qor
}

# =============================================================================
# 7. Write Outputs
# =============================================================================
puts "========== \[7/7\] Writing Outputs =========="

# Netlist
write -format verilog -hierarchy -output "$OUTPUT_DIR/atc_top_syn.v"
puts "  Netlist: $OUTPUT_DIR/atc_top_syn.v"

# SDC (constraints back-annotation)
write_sdc "$OUTPUT_DIR/atc_top.sdc"
puts "  SDC: $OUTPUT_DIR/atc_top.sdc"

# Timing (SDF)
write_sdf "$OUTPUT_DIR/atc_top.sdf"
puts "  SDF: $OUTPUT_DIR/atc_top.sdf"

# DDC (for future sessions)
write -format ddc -hierarchy -output "$OUTPUT_DIR/atc_top.ddc"
puts "  DDC: $OUTPUT_DIR/atc_top.ddc"

puts "============================================"
puts "  ATC Synthesis Complete"
puts "  Reports:  $REPORT_DIR"
puts "  Outputs:  $OUTPUT_DIR"
puts "============================================"

exit
