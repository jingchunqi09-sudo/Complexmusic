# Gowin V1.9.12.03; the checked-in GPRJ is the single source list.
# open_project places synthesis and PNR outputs under project_root/impl.
set project_root [file normalize [file join [file dirname [info script]] ..]]
cd $project_root
open_project [file join $project_root tang_mega_60k.gprj]
set_device -name GW5AT-60B GW5AT-LV60PG484AC1/I0
set_option -top_module tang_mega_60k_top
set_option -verilog_std v2001
set_option -include_path "$project_root;[file join $project_root src]"
set_option -output_base_name tang_mega_60k
set_option -global_freq 50
set_option -cst_warn_to_error 1
set_option -timing_driven true
set_option -place_option 1
# Same-netlist experiments in build/physical_20261025/full_candidates:
# round_quotient P1R2 saves CLS and improves timing over P0R1/P0R2.
set_option -route_option 2
set_option -clock_route_order 0
set_option -replicate_resources 0
set_option -correct_hold_violation 1
set_option -gen_text_timing_rpt true
run all
