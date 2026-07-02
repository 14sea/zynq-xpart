# M7.2 flat non-DFX control experiment (2026-07-02).
#
# Question: is the build-dependent array-forward miscompute (docs/m7_2_dcpdiff.md)
# specific to the DFX in-context-routing flow, or does it also hit a plain flat
# (non-partitioned) implementation of the very same netlist at bad-class firmware
# size?
#
# Design = the DFX build minus DFX: same dfx_top / ps BD (PS7+GPIO+HWICAP) /
# neorv32_soc_dfx / rm_train sources, same diag2pad.c IMEM (.text 10928 B, the
# size class that fails ~6/7 P&R rolls in the DFX flow), but NO PR_FLOW, NO
# partition_def, NO pblock — u_soc/wb_tpu_inst is an ordinary flat cell.
#
# Because correctness is a per-build route lottery (diag2settle proved a working
# bad-class DFX build exists), a single flat build passing is weak evidence:
# this script builds THREE rolls (impl_1/2/3, different place directives) in one
# go. Board expectation if the DFX-flow attribution is right: all three compute
# forward B0..B3 = {19,2,10,-1}. Any {-5,-3,-8,-3} roll instead re-opens the
# deeper P&R/floorplan suspicion.
#
# Routed DCP + bit + timing/fingerprint reports are archived per-roll into
# vivado/flat_m72/artifacts/ (OUTSIDE the .runs dir — the diag2settle/diag2pad
# DCPs were lost to a later rebuild; don't repeat that).
#
#   vivado -mode batch -source build_flat.tcl

set proj   flat_m72
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set nhome  $root/rtl_src/neorv32_tpu/neorv32
set bdir   $origin/build
set adir   $origin/artifacts

create_project $proj $bdir -part $part -force
# NOTE: no PR_FLOW here — that is the experiment.

# --- RTL sources: identical set to build_dfx.tcl's static + the rm_train RM ---
set fl [read [open $nhome/rtl/file_list_soc.f r]]
set fl [string map [list NEORV32_RTL_PATH_PLACEHOLDER $nhome/rtl] $fl]
add_files $fl
set_property library neorv32 [get_files $fl]
add_files $root/rtl/neorv32_soc_dfx.vhd
add_files $root/rtl/dfx_top.v
# tpu_rp = the rm_train RM, now linked as a plain flat module (only tpu_rp source added)
add_files [list $root/rtl/dfx/tpu_rp_rm_train.v $root/rtl/train_unit.v \
                $root/rtl/wb_tpu_accel.v $root/rtl/tpu_accel.v \
                $root/rtl/systolic_array_4x4.v $root/rtl/pe.v]

# --- PS-only block design: verbatim from build_dfx.tcl (incl. HWICAP, for parity) ---
create_bd_design "ps"
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FCLK_CLK0_BUF {TRUE}] $ps7
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_ALL_INPUTS_2 {1}] $gpio
set hwi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_hwicap axi_hwicap_0]
set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property CONFIG.NUM_MI {2} $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0
create_bd_port -dir O fclk_o
create_bd_port -dir O rstn_o
create_bd_port -dir I -from 31 -to 0 mbox_i
create_bd_port -dir I mbox_valid_i
set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_ic_0/M01_ACLK axi_gpio_0/s_axi_aclk \
           axi_hwicap_0/s_axi_aclk axi_hwicap_0/icap_clk rst_0/slowest_sync_clk} {
  connect_bd_net $clk [get_bd_pins $p]
}
connect_bd_net $clk [get_bd_ports fclk_o]
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN axi_ic_0/M01_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_hwicap_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_ports rstn_o]
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M01_AXI] [get_bd_intf_pins axi_hwicap_0/S_AXI_LITE]
connect_bd_net [get_bd_ports mbox_i]       [get_bd_pins axi_gpio_0/gpio_io_i]
connect_bd_net [get_bd_ports mbox_valid_i] [get_bd_pins axi_gpio_0/gpio2_io_i]
assign_bd_address
catch {assign_bd_address -force -offset 0x41200000 -range 64K [get_bd_addr_segs axi_gpio_0/S_AXI/Reg]}
catch {assign_bd_address -force -offset 0x41400000 -range 64K [get_bd_addr_segs axi_hwicap_0/S_AXI_LITE/Reg]}
puts "=== ADDRESS MAP ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7_0/Data]] {
  puts "  $seg -> [get_property OFFSET $seg] range [get_property RANGE $seg]"
}
validate_bd_design
save_bd_design
make_wrapper -files [get_files ps.bd] -top -import

set_property top dfx_top [current_fileset]
update_compile_order -fileset sources_1

# --- three rolls: identical netlist, different place directives (route lottery samples) ---
set flow [get_property FLOW [get_runs impl_1]]
create_run impl_2 -parent_run synth_1 -flow $flow
create_run impl_3 -parent_run synth_1 -flow $flow
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Default               [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE AltSpreadLogic_medium [get_runs impl_2]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high    [get_runs impl_3]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 impl_2 impl_3 -to_step write_bitstream -jobs 12
wait_on_run impl_1
wait_on_run impl_2
wait_on_run impl_3

# --- per-roll: status, timing stats, archive bit+dcp+fingerprint outside .runs ---
file mkdir $adir
foreach r {impl_1 impl_2 impl_3} {
  set run [get_runs $r]
  puts "=== $r: [get_property STATUS $run]  WNS=[get_property STATS.WNS $run]  WHS=[get_property STATS.WHS $run] ==="
  set rd $bdir/$proj.runs/$r
  set out $adir/$r
  file mkdir $out
  foreach f [glob -nocomplain $rd/*.bit] { file copy -force $f $out/ }
  foreach f [glob -nocomplain $rd/dfx_top_routed.dcp] { file copy -force $f $out/ }
  open_run $r
  report_timing_summary -file $out/timing_summary.rpt
  # array fingerprint: every DSP LOC + the array/train cell count (cf. array_fingerprint.tcl)
  set fp [open $out/array_fingerprint.txt w]
  puts $fp "roll $r  place_directive [get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $run]"
  foreach c [lsort [get_cells -hier -filter {PRIMITIVE_TYPE =~ ARITHMETIC.DSP.*}]] {
    puts $fp "DSP  [get_property LOC $c]  $c"
  }
  puts $fp "array leaf cells: [llength [get_cells -hier -filter {NAME =~ u_soc/wb_tpu_inst/*}]]"
  close $fp
  close_design
}
puts "=== FLAT_M72 BUILD COMPLETE ==="
exit
