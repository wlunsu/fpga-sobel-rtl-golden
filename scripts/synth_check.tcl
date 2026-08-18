# Out-of-context synthesis check for the Red Pitaya Z10 device.

set script_path [file normalize [info script]]
if {[info exists ::env(SOBEL_PROJECT_ROOT)]} {
    # Vivado 2020.1's Windows batch wrapper can mis-normalize a current
    # directory containing spaces.  The PowerShell wrapper supplies the exact
    # workspace path through this process-local environment variable.
    set project_root $::env(SOBEL_PROJECT_ROOT)
} else {
    set project_root [file dirname [file dirname $script_path]]
}
set build_dir [file join $project_root build synth]
set report_dir [file join $project_root reports]

file mkdir $build_dir
file mkdir $report_dir
cd $build_dir

read_verilog [file join $project_root rtl sobel_operator.v]
read_verilog [file join $project_root rtl sobel_stream_core.v]

# A single process is sufficient for this small learning core.
set_param general.maxThreads 1

synth_design \
    -top sobel_stream_core \
    -part xc7z010clg400-1 \
    -mode out_of_context

create_clock -name pixel_clk -period 10.000 [get_ports clk]

report_utilization \
    -file [file join $report_dir synthesis_utilization_xc7z010.rpt]
report_timing_summary \
    -delay_type max \
    -max_paths 10 \
    -file [file join $report_dir synthesis_timing_xc7z010_100mhz.rpt]

write_checkpoint -force [file join $build_dir sobel_stream_core_synth.dcp]

puts "SYNTH_CHECK_PASS: sobel_stream_core synthesized for xc7z010clg400-1"
