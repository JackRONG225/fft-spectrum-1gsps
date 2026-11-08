# _pre_copy_mem.tcl -- armed by build_project.tcl as STEPS.SYNTH_DESIGN.TCL.PRE.
#
# Why this exists: rtl/fe4lane.v and rtl/comb4.v load their ROM images with
# relative names, e.g. $readmemh("iq4.mem", iq_rom). Vivado resolves such a name
# against the current directory of the synthesis run
# (<project>/<project>.runs/synth_1), NOT against sim/.
#
# If the file is not found, synthesis does NOT fail. It emits
#     CRITICAL WARNING: [Synth 8-4445] cannot open file iq4.mem
# and happily produces a bit stream in which every ROM word is zero. The design
# then builds, programs and reports -- with an all-zero stimulus and therefore an
# all-zero spectrum. That failure mode cost a full evening once.
#
# Copying the five images into the run directory keeps the RTL free of any
# absolute path, which is what makes the repo relocatable.
# KEEP THIS FILE PURE ASCII.

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set simd [file join $root sim]

set mems {iq4.mem hann4.mem wt1.mem wt2.mem wt3.mem}

# DIRECTORY of the run that owns this hook (TCL.PRE runs with that run as context)
set rundir [pwd]
catch { set rundir [get_property DIRECTORY [get_runs -filter {NAME =~ "synth_*"}]] }

puts "### PRE_COPY rundir=$rundir"
foreach m $mems {
    set src [file join $simd $m]
    if {![file exists $src]} {
        puts "### PRE_COPY_MISSING $src"
        continue
    }
    if {[catch {file copy -force $src [file join $rundir $m]} err]} {
        puts "### PRE_COPY_FAIL $m : $err"
    } else {
        puts "### PRE_COPY_OK $m"
    }
}
