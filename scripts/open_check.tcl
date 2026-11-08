# open_check.tcl -- open the rebuilt project and inventory it. No synthesis.
#
# Usage: vivado -mode batch -source scripts/open_check.tcl
# Expected last line: ### OPEN_CHECK_DONE
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

puts "### OPEN_OK    top=[get_property top [current_fileset]]"
puts "### PART       [get_property part [current_project]]"
puts "### VIVADO     [version -short]"
puts "### DEFINE     [get_property verilog_define [current_fileset]]"
set allf [get_files -of_objects [get_filesets sources_1]]
set desf [get_files -of_objects [get_filesets sources_1] -filter {NAME !~ "*ip*"}]
puts "### SRC_FILES  [llength $desf] design sources (fileset total [llength $allf])"
puts "### XDC        [get_files -of_objects [get_filesets constrs_1]]"
puts "### IP         [get_ips]"

update_compile_order -fileset sources_1

if {[catch {check_syntax -fileset sources_1} msg]} {
    puts "### SYNTAX_CHECK_SKIPPED $msg"
} else {
    puts "### SYNTAX_OK"
}

puts "### OPEN_CHECK_DONE"
close_project
