# run_sim_wave.tcl -- run the behavioural simulation and bring up the 14-signal view.
#
# Why this cannot be done after the run:
#   xsim only records the signals that are already in the wave window when the run
#   starts. Clicking Run Simulation launches with the generated "add_wave /" set
#   (the 13 tb ports only), so internal signals (u/fend, u/wr_ok, u/ds_start,
#   u/ds_busy, u/u_ds/pa_done, u/u_ds/pb_busy) are NEVER logged -- wherever you
#   drag the cursor afterwards, those rows stay empty.
#
# Order that works:
#   0. open the project if needed
#   1. close_sim
#   2. set xsim.simulate.runtime = 0 ns      (elaborate, do not run)
#   3. launch_simulation                     (stops at time 0)
#   4. drop the default wave config, open wave_demo.wcfg   (14 signals in window)
#   5. restore runtime = all, then run all   (now all 14 signals get logged)
#
# Usage, in the project Tcl Console:
#     source {<repo>/scripts/run_sim_wave.tcl}
# KEEP THIS FILE PURE ASCII.

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set PROJ [file join $root _proj fft_spectrum_1gsps fft_spectrum_1gsps.xpr]
set WCFG [file join $here wave_demo.wcfg]
set SIMD [file join $root sim]

# ---- 0) project ----
if {[catch {current_project} proj_now] || $proj_now eq ""} {
    if {![file exists $PROJ]} {
        puts "!! no project at $PROJ -- run scripts/build_project.tcl first"
        return
    }
    puts "=== no project open, opening $PROJ ==="
    open_project $PROJ
} else {
    puts "=== project: $proj_now ==="
}

# ---- 1) close any running simulation ----
if {[catch {close_sim} cs_err]} {
    puts "=== close_sim: nothing to close ==="
} else {
    puts "=== previous simulation closed ==="
}

# ---- 2) elaborate only (runtime 0) so the run waits for our wave window ----
set rt_ok 1
if {[catch {set_property -name {xsim.simulate.runtime} -value {0 ns} -objects [get_filesets sim_1]} rt_err]} {
    set rt_ok 0
    puts "!! cannot set runtime to 0 ns: $rt_err"
    puts "!! the internal signals will NOT be logged in this run"
}

# ---- 3) launch ----
puts "=== launching simulation (elaborate only) ==="
if {[catch {launch_simulation} ls_err]} {
    puts "!! launch_simulation failed: $ls_err"
    catch {set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]}
    return
}
after 500

# ---- 3b) ROM images next to the xsim working directory ----
# $readmemh("iq4.mem") resolves against the xsim run directory, not against sim/.
# Missing images do not abort the run: the ROM silently loads as all zeros.
set xsimdir ""
if {[catch {set sdir [get_property DIRECTORY [get_filesets sim_1]]}]} { set sdir "" }
if {$sdir ne ""} {
    foreach cand [glob -nocomplain -types d -directory $sdir */*] {
        if {[file isdirectory [file join $cand xsim]]} { set xsimdir [file join $cand xsim] }
    }
}
if {$xsimdir ne ""} {
    foreach m {iq4.mem hann4.mem wt1.mem wt2.mem wt3.mem} {
        set src [file join $SIMD $m]
        if {[file exists $src]} {
            if {[catch {file copy -force $src [file join $xsimdir $m]} e]} {
                puts "!! copy $m failed: $e"
            }
        } else {
            puts "!! missing $src"
        }
    }
    puts "=== ROM images copied to $xsimdir ==="
} else {
    puts "!! xsim run directory not found; if the spectrum comes out all zeros,"
    puts "!! copy sim/*.mem next to the simulator working directory and rerun"
}

# ---- 4) replace the default config with the 14-signal one ----
set n_cfg 0
foreach c [get_wave_configs -quiet *] {
    if {![catch {delete_wave_config $c}]} { incr n_cfg }
}
puts "=== removed $n_cfg default wave config(s) ==="

if {[catch {open_wave_config $WCFG} wcfg_err]} {
    puts "=== wave_demo.wcfg failed ($wcfg_err), building the 14 signals by hand ==="
    add_wave_divider {1 CLK / FRAME}
    add_wave {/tb_sys4/clk2}
    add_wave {/tb_sys4/rst_n}
    add_wave {/tb_sys4/u/fend}
    add_wave {/tb_sys4/u/wr_ok}
    add_wave_divider {2 ONE ANALYSIS}
    add_wave {/tb_sys4/u/ds_start}
    add_wave {/tb_sys4/u/ds_busy}
    add_wave {/tb_sys4/u/u_ds/pa_done}
    add_wave {/tb_sys4/u/u_ds/pb_busy}
    add_wave {/tb_sys4/D}
    add_wave_divider {3 RESULT}
    add_wave {/tb_sys4/LAT}
    add_wave {/tb_sys4/L}
    add_wave {/tb_sys4/R}
    add_wave {/tb_sys4/BW}
    add_wave {/tb_sys4/DC}
} else {
    puts "=== wave_demo.wcfg opened (14 signals, zoom 50-66 us) ==="
}

# ---- 5) restore the project setting, then run ----
catch {set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]}

if {$rt_ok} {
    puts "=== running all (about 1 minute), all 14 signals are being logged ==="
    run all
    puts "=== done: cursor at 52.6us shows fend/ds_start; 52.6-63.7us shows ds_busy/pb_busy ==="
} else {
    puts "=== runtime was not 0, so the run already finished during launch ==="
    puts "=== expect EMPTY rows for the internal signals; fix runtime and rerun ==="
}
