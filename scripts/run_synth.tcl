# run_synth.tcl -- synthesise the rebuilt project and check the two things that
# silently go wrong: a missing ROM image (Synth 8-4445) and a wrong DSP count.
#
# Usage: vivado -mode batch -source scripts/run_synth.tcl
# Expected last line: ### SYNTH_CHECK_DONE
#
# Acceptance (from docs/reproduce.md, step 2):
#   ### SYNTH_84445_COUNT 0     <-- must be 0
#   ### SYNTH_DSP         85     <-- must be 85
# KEEP THIS FILE PURE ASCII.

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set xpr  [file join $root _proj fft_spectrum_1gsps.xpr]

if {![file exists $xpr]} {
    puts "### NO_PROJECT $xpr"
    puts "### run scripts/build_project.tcl first"
    return
}

open_project $xpr
puts "### SYNTH_TOP    [get_property top [current_fileset]]"
puts "### SYNTH_PART   [get_property part [current_project]]"
puts "### SYNTH_DEFINE [get_property verilog_define [current_fileset]]"

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "### SYNTH_STATUS $st"

set rundir [get_property DIRECTORY [get_runs synth_1]]
set logf [file join $rundir runme.log]
set n4445 0
if {[file exists $logf]} {
    set fh [open $logf r]
    set txt [read $fh]
    close $fh
    foreach line [split $txt "\n"] {
        if {[string first "8-4445" $line] >= 0} { incr n4445 }
    }
} else {
    puts "### SYNTH_NO_LOG $logf"
}
puts "### SYNTH_84445_COUNT $n4445"

# Did the ROM images reach the run directory?
foreach m {iq4.mem hann4.mem wt1.mem wt2.mem wt3.mem} {
    if {![file exists [file join $rundir $m]]} {
        puts "### SYNTH_MEM_MISSING $m"
    }
}

if {[string first "Complete" $st] >= 0} {
    open_run synth_1 -name synth_1
    # Only the primitive counts that are stable across synth and implementation.
    # LUT / FF from a synthesised netlist differ from the post-route report in
    # docs/reports/, so they are deliberately NOT printed here.
    puts "### SYNTH_DSP    [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]"
    puts "### SYNTH_RAMB36 [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]"
    puts "### SYNTH_RAMB18 [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]"
    puts "### SYNTH_DSP_EXPECT 85   (85/90 = 94.44%)"
    puts "### SYNTH_RAMB_EXPECT 27 RAMB36 + 28 RAMB18 = 41 RAMB36-equivalents (41/50 = 82.00%)"
} else {
    puts "### SYNTH_FAILED see $logf"
}

puts "### SYNTH_CHECK_DONE"
close_project
