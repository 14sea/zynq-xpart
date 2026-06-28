# Phase 3 DFX (RTL-top structure): PS-only BD + dfx_top (RTL) instantiating
# neorv32_soc_dfx, whose TPU is the reconfigurable partition `tpu_rp`.
# Produces a full bitstream (static + RM1) + partial bitstreams for RM1 and RM2.
#   vivado -mode batch -source build_dfx.tcl

set proj   dfx
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set nhome  $root/rtl_src/neorv32_tpu/neorv32
set bdir   $origin/build

create_project $proj $bdir -part $part -force
set_property PR_FLOW 1 [current_project]

# --- static + RM1 RTL sources ---
set fl [read [open $nhome/rtl/file_list_soc.f r]]
set fl [string map [list NEORV32_RTL_PATH_PLACEHOLDER $nhome/rtl] $fl]
add_files $fl
set_property library neorv32 [get_files $fl]
add_files $root/rtl/neorv32_soc_dfx.vhd
add_files $root/rtl/dfx_top.v
add_files [list $root/rtl/dfx/tpu_rp_rm1_tpu.v $root/rtl/pe.v \
                $root/rtl/systolic_array_4x4.v $root/rtl/tpu_accel.v $root/rtl/wb_tpu_accel.v]

# --- PS-only block design (PS7 + AXI-GPIO mailbox), exposing fclk/rstn/mbox ---
create_bd_design "ps"
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FCLK_CLK0_BUF {TRUE}] $ps7
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
  CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_ALL_INPUTS_2 {1}] $gpio
# M6.5.2: AXI HWICAP in the DFX static so a weight LUT-INIT can be ICAP-edited
# live (icap_clk tied to FCLK0, the T2.1/T2.2-proven wiring).
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
# Pin mailbox GPIO @0x41200000 (M6.3 convention) and HWICAP @0x41400000
# (hwicap-uart.py default). catch -> tolerate seg-path naming differences.
catch {assign_bd_address -force -offset 0x41200000 -range 64K [get_bd_addr_segs axi_gpio_0/S_AXI/Reg]}
catch {assign_bd_address -force -offset 0x41400000 -range 64K [get_bd_addr_segs axi_hwicap_0/S_AXI_LITE/Reg]}
puts "=== ADDRESS MAP ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7_0/Data]] {
  puts "  $seg -> [get_property OFFSET $seg] range [get_property RANGE $seg]"
}
validate_bd_design
save_bd_design
make_wrapper -files [get_files ps.bd] -top -import

# --- top = RTL dfx_top ---
set_property top dfx_top [current_fileset]
update_compile_order -fileset sources_1

# --- DFX: partition def + reconfig modules + configurations ---
set rp_cell u_soc/wb_tpu_inst
create_partition_def -name tpu_pd -module tpu_rp
create_reconfig_module -name rm1_tpu -partition_def [get_partition_defs tpu_pd] -define_from tpu_rp
create_reconfig_module -name rm2_alt -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm2_alt] $root/rtl/dfx/tpu_rp_rm2_alt.v
create_reconfig_module -name rm_lut -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_lut] $root/rtl/dfx/tpu_rp_rm_lut.v
create_reconfig_module -name rm_lut_b -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_lut_b] $root/rtl/dfx/tpu_rp_rm_lut_b.v
# M6: full-version RM = 4x4 TPU + 4-lane VPU. Its fileset needs the wrapper +
# vpu.v AND the shared lower modules (wb_tpu_accel/tpu_accel/systolic/pe) —
# those get pulled into rm1_tpu's fileset by rm1's -define_from, so add them
# explicitly here too (a submodule source may live in multiple RM filesets).
create_reconfig_module -name rm_tpuvpu -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_tpuvpu] \
    [list $root/rtl/dfx/tpu_rp_rm_tpuvpu.v $root/rtl/vpu.v \
          $root/rtl/wb_tpu_accel.v $root/rtl/tpu_accel.v \
          $root/rtl/systolic_array_4x4.v $root/rtl/pe.v]
# M6.4 (Model B): boot-time RoT-marker RM (self-contained, like rm2_alt).
create_reconfig_module -name rm_rot -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_rot] $root/rtl/dfx/tpu_rp_rm_rot.v
# M6.5: LUT-KCM RM = 4x4 baked-weight TPU + VPU. Fully self-contained (own accel
# chain copies) so it shares no submodule fileset with rm1/rm_tpuvpu. vpu.v is
# shared with rm_tpuvpu's fileset (a source may live in multiple RM filesets).
create_reconfig_module -name rm_lutkcm -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_lutkcm] \
    [list $root/rtl/dfx/tpu_rp_rm_lutkcm.v $root/rtl/vpu.v \
          $root/rtl/dfx/wb_tpu_accel_kcm.v $root/rtl/dfx/tpu_accel_kcm.v \
          $root/rtl/dfx/lutkcm_array.v $root/rtl/dfx/lutkcm_pe.v]
# M7.2: TRAINING RM = 4x4 TPU array + train_unit (the tiny-tpu trio in HW). No VPU
# (training uses the raw INT32 acc + a SW requant), so it is the DFX train↔infer
# time-mux counterpart of rm_tpuvpu. Shares the accel chain (added explicitly; a
# submodule source may live in multiple RM filesets).
create_reconfig_module -name rm_train -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_train] \
    [list $root/rtl/dfx/tpu_rp_rm_train.v $root/rtl/train_unit.v \
          $root/rtl/wb_tpu_accel.v $root/rtl/tpu_accel.v \
          $root/rtl/systolic_array_4x4.v $root/rtl/pe.v]
# M7.3+ checkpoint-to-fabric LOCATE variant: rm_lutkcm with PE[0][0] baked = 45
# (learned W1[0][0] INT8) instead of 1. Uses lutkcm_array_w45.v (same module name,
# own fileset) — `lut-surgery.py diff` of the cfg7 vs cfg9 partials reveals the CRAM
# bits that move for 1->45 (bits 2,3,5), i.e. the frames the on-board ICAP write edits.
create_reconfig_module -name rm_lutkcm_w45 -partition_def [get_partition_defs tpu_pd] -top tpu_rp
add_files -norecurse -of_objects [get_reconfig_modules rm_lutkcm_w45] \
    [list $root/rtl/dfx/tpu_rp_rm_lutkcm.v $root/rtl/vpu.v \
          $root/rtl/dfx/wb_tpu_accel_kcm.v $root/rtl/dfx/tpu_accel_kcm.v \
          $root/rtl/dfx/lutkcm_array_w45.v $root/rtl/dfx/lutkcm_pe.v]
create_pr_configuration -name cfg1 -partitions [list $rp_cell:rm1_tpu]
create_pr_configuration -name cfg2 -partitions [list $rp_cell:rm2_alt]
create_pr_configuration -name cfg3 -partitions [list $rp_cell:rm_lut]
create_pr_configuration -name cfg4 -partitions [list $rp_cell:rm_lut_b]
create_pr_configuration -name cfg5 -partitions [list $rp_cell:rm_tpuvpu]
create_pr_configuration -name cfg6 -partitions [list $rp_cell:rm_rot]
create_pr_configuration -name cfg7 -partitions [list $rp_cell:rm_lutkcm]
create_pr_configuration -name cfg8 -partitions [list $rp_cell:rm_train]
create_pr_configuration -name cfg9 -partitions [list $rp_cell:rm_lutkcm_w45]
add_files -fileset constrs_1 -norecurse $origin/pblock_rp.xdc

set_property PR_CONFIGURATION cfg1 [get_runs impl_1]
create_run impl_2 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg2
create_run impl_3 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg3
create_run impl_4 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg4
create_run impl_5 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg5
create_run impl_6 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg6
create_run impl_7 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg7
create_run impl_8 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg8
create_run impl_9 -parent_run impl_1 -flow [get_property FLOW [get_runs impl_1]] -pr_config cfg9

# M6.1: by default build only the static (impl_1, the locked parent) + the new
# TPU+VPU partial (impl_5). rm2/rm_lut/rm_lut_b are unchanged & already
# hardware-verified; set build_all 1 to rebuild them too.
set build_all 0
# M7.3+ locate build: static (impl_1) + rm_lutkcm baseline (impl_7) + rm_lutkcm_w45
# (impl_9). The two LUT-KCM partials share this run's static, so lut-surgery.py diff
# of them is a clean controlled-diff for the PE[0][0] 1->45 weight bits.
set build_m73plus 0
# M7.5.2 single-session loop: ONE impl_1 static (m752_loop.c firmware) + BOTH
# impl_5 (rm_tpuvpu, phase-1 training) and impl_7 (rm_lutkcm, phase-2 infer),
# so a live loadbp can swap rm_tpuvpu->rm_lutkcm under the running NEORV32.
set build_m752 0

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== impl_1 (cfg1 static+rm1): [get_property STATUS [get_runs impl_1]] ==="

if {$build_all} {
  launch_runs impl_2 -to_step write_bitstream -jobs 8
  wait_on_run impl_2
  puts "=== impl_2 (cfg2): [get_property STATUS [get_runs impl_2]] ==="
  launch_runs impl_3 -to_step write_bitstream -jobs 8
  wait_on_run impl_3
  puts "=== impl_3 (cfg3 lut A): [get_property STATUS [get_runs impl_3]] ==="
  launch_runs impl_4 -to_step write_bitstream -jobs 8
  wait_on_run impl_4
  puts "=== impl_4 (cfg4 lut B): [get_property STATUS [get_runs impl_4]] ==="
}

if {!$build_m73plus} {
  launch_runs impl_5 -to_step write_bitstream -jobs 8
  wait_on_run impl_5
  puts "=== impl_5 (cfg5 tpu+vpu): [get_property STATUS [get_runs impl_5]] ==="

  # M6.1 evidence: RP utilization (within pblock?) + DRC on the routed TPU+VPU.
  open_run impl_5
  report_utilization -file $bdir/impl5_util.rpt
  report_drc        -file $bdir/impl5_drc.rpt
  puts "=== impl_5 reports: $bdir/impl5_util.rpt , $bdir/impl5_drc.rpt ==="
}

# M7.5.2: also build impl_7 (rm_lutkcm) on the SAME impl_1 static, so rm_tpuvpu
# (impl_5) <-> rm_lutkcm (impl_7) loadbp-swap live for the train->checkpoint->infer loop.
if {$build_m752} {
  launch_runs impl_7 -to_step write_bitstream -jobs 8
  wait_on_run impl_7
  puts "=== impl_7 (cfg7 rm_lutkcm, m752): [get_property STATUS [get_runs impl_7]] ==="
}

# M7.3+ locate build: static (impl_1) + rm_lutkcm baseline (impl_7) + rm_lutkcm_w45
# (impl_9). Both share impl_1's static, so their partials are a clean controlled-diff.
if {$build_m73plus} {
  launch_runs impl_7 -to_step write_bitstream -jobs 8
  wait_on_run impl_7
  puts "=== impl_7 (cfg7 rm_lutkcm baseline PE00=1): [get_property STATUS [get_runs impl_7]] ==="
  launch_runs impl_9 -to_step write_bitstream -jobs 8
  wait_on_run impl_9
  puts "=== impl_9 (cfg9 rm_lutkcm_w45 PE00=45): [get_property STATUS [get_runs impl_9]] ==="
}

# M7.2: TRAINING partial (rm_train). Built by default (the active milestone). Report
# RP utilization + DRC — this is the real fit confirmation for the M7 LUT-pressure
# concern (train_unit + array, no VPU; expect to sit comfortably in pblock_rp).
set build_train [expr {!$build_m73plus && !$build_m752}]
if {$build_train} {
  launch_runs impl_8 -to_step write_bitstream -jobs 8
  wait_on_run impl_8
  puts "=== impl_8 (cfg8 rm_train): [get_property STATUS [get_runs impl_8]] ==="
  open_run impl_8
  report_utilization -file $bdir/impl8_util.rpt
  report_drc        -file $bdir/impl8_drc.rpt
  puts "=== impl_8 reports: $bdir/impl8_util.rpt , $bdir/impl8_drc.rpt ==="
}

# M6.4/M6.5 stretch RMs (rm_rot, rm_lutkcm) — already hardware-verified, so gate
# them behind build_all like rm2/rm_lut. Default build = static (impl_1) + the
# TPU+VPU partial (impl_5), which is exactly what M7.0b reuses (VPU bypassed).
if {$build_all} {
  # M6.4: boot-time RoT-marker full (static + rm_rot) + its partial.
  launch_runs impl_6 -to_step write_bitstream -jobs 8
  wait_on_run impl_6
  puts "=== impl_6 (cfg6 rm_rot): [get_property STATUS [get_runs impl_6]] ==="

  # M6.5: LUT-KCM full (static + rm_lutkcm) + its partial. This place+route is the
  # REAL fit confirmation (OOC was unconstrained). Report RP utilization + DRC.
  launch_runs impl_7 -to_step write_bitstream -jobs 8
  wait_on_run impl_7
  puts "=== impl_7 (cfg7 rm_lutkcm): [get_property STATUS [get_runs impl_7]] ==="
  open_run impl_7
  report_utilization -file $bdir/impl7_util.rpt
  report_drc        -file $bdir/impl7_drc.rpt
  puts "=== impl_7 reports: $bdir/impl7_util.rpt , $bdir/impl7_drc.rpt ==="
}

puts "=== bitstreams ==="
foreach b [glob -nocomplain $bdir/$proj.runs/impl_*/*.bit] { puts "  $b" }
exit
