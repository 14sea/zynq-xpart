# T2.1 — AXI HWICAP bring-up test for EBAZ4205 (XC7Z010).
#
# Goal: re-integrate AXI HWICAP CORRECTLY (clock/reset wired exactly like the proven
# axi_wtest loopback design) and confirm its register file responds under miner U-Boot.
# T1 proved PS->PL AXI writes land; the prior "HWICAP regs read 0" was therefore an IP
# integration bug (reset/clock), not a dead write path. This bitstream isolates that.
#
# Contents (both on M_AXI_GP0 via a 2-master interconnect):
#   M00 -> axi_gpio_0  : ch1 output -> ch2 input loopback (known-good write sanity)
#   M01 -> axi_hwicap_0: the IP under test
#
# Test from U-Boot after `fpga loadb`:
#   GPIO sanity:  md 0x41200008 1 -> 0 ; mw 0x41200000 0x5a5a5a5a ; md 0x41200008 1 -> 0x5a5a5a5a
#   HWICAP base printed below (expect 0x41400000). Read:
#     SR  @ base+0x120 -> healthy: non-zero (DONE/EOS bits set)
#     WFV @ base+0x124 -> healthy: non-zero (write-FIFO vacancy = FIFO depth)
#   If SR/WFV are sane, HWICAP is alive -> proceed to single-frame write (T2.2).
#
# Run:  source <Vivado>/settings64.sh ; vivado -mode batch -source build_hwicap.tcl

set proj   hwicap_t2
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set bdir   $origin/build

create_project $proj $bdir -part $part -force
create_bd_design "system"

# --- Zynq PS7 (minimal: GP0 master + FCLK0) ---
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
] $ps7

# --- AXI-GPIO loopback (write sanity) : ch1 out active at reset -> ch2 in ---
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list \
  CONFIG.C_GPIO_WIDTH {32} \
  CONFIG.C_ALL_INPUTS {0} \
  CONFIG.C_TRI_DEFAULT {0x00000000} \
  CONFIG.C_DOUT_DEFAULT {0x00000000} \
  CONFIG.C_IS_DUAL {1} \
  CONFIG.C_GPIO2_WIDTH {32} \
  CONFIG.C_ALL_INPUTS_2 {1} \
] $gpio

# --- AXI HWICAP (the IP under test) ---
set hwi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_hwicap axi_hwicap_0]

# --- AXI interconnect: 1 slave (GP0) -> 2 masters + reset ---
set ic  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property -dict [list CONFIG.NUM_MI {2}] $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

# --- clocks (single FCLK0 domain, exactly like axi_wtest) ---
set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK \
           axi_ic_0/M00_ACLK axi_ic_0/M01_ACLK \
           axi_gpio_0/s_axi_aclk axi_hwicap_0/s_axi_aclk axi_hwicap_0/icap_clk \
           rst_0/slowest_sync_clk} {
  connect_bd_net $clk [get_bd_pins $p]
}

# --- resets ---
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN axi_ic_0/M01_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_hwicap_0/s_axi_aresetn]

# --- AXI data path ---
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M01_AXI] [get_bd_intf_pins axi_hwicap_0/S_AXI_LITE]

# --- GPIO internal loopback ---
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins axi_gpio_0/gpio2_io_i]

assign_bd_address
validate_bd_design
save_bd_design
puts "=== ADDRESS MAP ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7_0/Data]] {
  puts "  $seg  ->  [get_property OFFSET $seg]  range [get_property RANGE $seg]"
}

make_wrapper -files [get_files system.bd] -top -import
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "=== IMPL STATUS: [get_property STATUS [get_runs impl_1]] ==="
foreach b [glob -nocomplain $bdir/$proj.runs/impl_1/*.bit] { puts "=== BITSTREAM: $b" }
exit
