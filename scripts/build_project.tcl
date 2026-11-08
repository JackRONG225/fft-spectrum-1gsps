# build_project.tcl -- rebuild the 1 GSPS spectrum analyser project from scratch.
#
# Target : Vivado 2020.2, part xc7a35tfgg484-2, top board_top_4lane
# Usage  : vivado -mode batch -source scripts/build_project.tcl
#      or: source {<repo>/scripts/build_project.tcl}      (Tcl Console)
#
# What it does, in order:
#   1. locate the repo root from this script's own path (no absolute paths)
#   2. create the project under <repo>/_proj/            (keeps the repo root clean)
#   3. add the 36 design sources, the XDC and the MMCM .xci
#   4. set the project-level define CLK2_FREQ_MHZ=125    (UART baud rate depends on it)
#   5. add the behavioural testbench and the vector ROM images
#   6. arm a pre-synthesis hook that copies sim/*.mem into the run directory
#      so that the relative $readmemh() paths in rtl/ resolve without editing RTL
#
# KEEP THIS FILE PURE ASCII. Vivado 2020.2 chokes on GBK comments with
# "missing close-brace" -- this bit us during the competition defence.
#
# See docs/reproduce.md for the six pitfalls this script works around.

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set prjdir [file join $root _proj]
set prjname fft_spectrum_1gsps

puts "### REPO_ROOT $root"
puts "### PROJECT_DIR $prjdir"

if {[llength [get_projects -quiet]] > 0} { close_project -quiet }

# ---- 1) project -------------------------------------------------------------
file mkdir $prjdir
create_project $prjname $prjdir -part xc7a35tfgg484-2 -force
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property simulator_language Mixed [current_project]

# ---- 2) design sources ------------------------------------------------------
# Order follows the delivered project; VHDL dependency order is re-sorted by
# update_compile_order below.
set R [file join $root rtl]
set F [file join $root third_party fftcore]
set G [file join $root gen]

add_files -norecurse [list \
    [file join $R comb4.v] \
    [file join $R ds4.v] \
    [file join $R fe4lane.v] \
    [file join $R mag_sq24.v] \
    [file join $R report_fmt4.v] \
    [file join $R sys4_top.v] \
    [file join $R uart_tx.v] \
    [file join $F fft_types.vhd] \
    [file join $F multiply_add.vhd] \
    [file join $R complex_multiply2_k.vhd] \
    [file join $F complex_ram.vhd] \
    [file join $F complex_ram_lut.vhd] \
    [file join $F twiddle_addr_gen.vhd] \
    [file join $F sr.vhd] \
    [file join $F twiddle_generator.vhd] \
    [file join $F transposer_addr_gen.vhd] \
    [file join $F transposer4.vhd] \
    [file join $F transposer.vhd] \
    [file join $G twiddleRom2048.vhd] \
    [file join $F reorder_buffer.vhd] \
    [file join $G twiddleRom64.vhd] \
    [file join $G twiddleGenerator16.vhd] \
    [file join $F fft4_serial8_bf.vhd] \
    [file join $F fft4_serial8.vhd] \
    [file join $G fft2048_sub16.vhd] \
    [file join $G fft2048_sub64.vhd] \
    [file join $G twiddleGenerator32.vhd] \
    [file join $G twiddleGenerator8.vhd] \
    [file join $F fft2_no_pipeline.vhd] \
    [file join $F fft2_serial.vhd] \
    [file join $G fft2048_sub8.vhd] \
    [file join $G fft2048_sub32.vhd] \
    [file join $G fft2048.vhd] \
    [file join $R fft2048_core.vhd] \
    [file join $R board_top_4lane.v] \
]

# ---- 3) constraints and IP --------------------------------------------------
add_files -fileset constrs_1 -norecurse [file join $root constrs board_4lane.xdc]
add_files -norecurse [file join $root ip clk_wiz_0.xci]

# PITFALL 2: CLK2_FREQ_MHZ is a project-level Verilog define, not a parameter.
# Omit it and the UART divider is computed for the wrong clock: the bit stream
# runs, the board boots, and every character on the serial port is garbage.
set_property verilog_define {CLK2_FREQ_MHZ=125} [current_fileset]

# Set the top AFTER the compile order is resolved, otherwise Vivado 2020.2
# emits "top module can not be validated" critical warnings (harmless, but
# alarming to a first-time reader).
update_compile_order -fileset sources_1
set_property top board_top_4lane [current_fileset]

# ---- 4) simulation ----------------------------------------------------------
add_files -fileset sim_1 -norecurse [file join $root sim tb_sys4.v]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
update_compile_order -fileset sim_1
set_property top tb_sys4 [get_filesets sim_1]

# ---- 5) pre-synthesis hook: ROM images next to the run ----------------------
# rtl/fe4lane.v and rtl/comb4.v call $readmemh("iq4.mem") and friends with
# relative names. Vivado resolves them against the synthesis run directory,
# not against sim/. The hook copies the five .mem files there.
set hook [file join $here _pre_copy_mem.tcl]
if {[file exists $hook]} {
    set job [get_runs synth_1]
    set_property -name {STEPS.SYNTH_DESIGN.TCL.PRE} -value $hook -objects $job
    puts "### PRE_HOOK $hook"
} else {
    puts "### WARN pre-hook missing: copy sim/*.mem into the synth run dir yourself"
}

# ---- 6) report what we built -----------------------------------------------
puts "### PROJECT  [current_project]"
puts "### PART     [get_property part [current_project]]"
puts "### TOP      [get_property top [current_fileset]]"
puts "### DEFINE   [get_property verilog_define [current_fileset]]"
foreach fs [get_filesets] {
    puts "### FILESET $fs : [llength [get_files -quiet -of_objects [get_filesets $fs]]] files"
}
puts "### BUILD_PROJ_DONE"
close_project
