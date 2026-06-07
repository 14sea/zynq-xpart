# T2.2b — observable LUT-INIT write proof via AXI HWICAP, EBAZ4205 (XC7Z010).
#
#   PS7 --GP0--> AXI HWICAP @0x41400000   (the ICAP write engine, icap_clk tied to FCLK0)
#            \-> AXI-GPIO(input) @0x41200000 <- lut_probe.q  (PS reads LUT6 output bit0)
#
# Flow (mirrors the M4 controlled-diff LUT surgery, but delivered via ICAP/HWICAP not PCAP):
#   1. build to routed, write bitstream A with LUT INIT[0]=0  (GPIO bit0 reads 0)
#   2. on the SAME routed design, set the LUT INIT[0]=1, write bitstream B
#      (B differs from A by exactly that one CRAM bit -> diff locates the frame)
#   3. host: diff A/B -> frame; build a single-frame HWICAP write of B's frame;
#      load A on board; HWICAP-write the frame; GPIO bit0 flips 0->1 = ICAP write landed.
#
# Run:  source <Vivado>/settings64.sh ; vivado -mode batch -source build_hwicap_lut.tcl

set proj   hwicap_lut
set part   xc7z010clg400-1
set origin [file normalize [file dirname [info script]]]
set root   [file normalize $origin/../..]
set bdir   $origin/build

create_project $proj $bdir -part $part -force
add_files -norecurse $root/rtl/lut_probe.v
update_compile_order -fileset sources_1

create_bd_design "system"

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7_0]
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
] $ps7

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1}] $gpio

set hwi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_hwicap axi_hwicap_0]
create_bd_cell -type module -reference lut_probe lut_probe_0

set ic  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_0]
set_property -dict [list CONFIG.NUM_MI {2}] $ic
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0

set clk [get_bd_pins ps7_0/FCLK_CLK0]
foreach p {ps7_0/M_AXI_GP0_ACLK axi_ic_0/ACLK axi_ic_0/S00_ACLK axi_ic_0/M00_ACLK \
           axi_ic_0/M01_ACLK axi_gpio_0/s_axi_aclk axi_hwicap_0/s_axi_aclk \
           axi_hwicap_0/icap_clk rst_0/slowest_sync_clk} {
  connect_bd_net $clk [get_bd_pins $p]
}

connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
foreach p {axi_ic_0/ARESETN axi_ic_0/S00_ARESETN axi_ic_0/M00_ARESETN axi_ic_0/M01_ARESETN} {
  connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_hwicap_0/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0]  [get_bd_intf_pins axi_ic_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M00_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_0/M01_AXI] [get_bd_intf_pins axi_hwicap_0/S_AXI_LITE]
connect_bd_net [get_bd_pins lut_probe_0/q] [get_bd_pins axi_gpio_0/gpio_io_i]

assign_bd_address
validate_bd_design
save_bd_design
puts "=== ADDRESS MAP ==="
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7_0/Data]] {
  puts "  $seg -> [get_property OFFSET $seg]"
}

make_wrapper -files [get_files system.bd] -top -import
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
puts "=== IMPL STATUS: [get_property STATUS [get_runs impl_1]] ==="

open_run impl_1
# CRC disable so a hand-built single-frame write needs no CRC recompute (M4 trick)
set_property BITSTREAM.GENERAL.CRC Disable [current_design]
set lut [get_cells -hier -filter {REF_NAME == LUT6 && NAME =~ *l_probe*}]
puts "=== LUT cell: $lut  INIT=[get_property INIT $lut]  LOC=[get_property LOC $lut]  BEL=[get_property BEL $lut] ==="

# bitstream A : INIT[0]=0
set_property INIT 64'h0000000000000000 $lut
write_bitstream -force $bdir/lut_A.bit
# bitstream B : INIT[0]=1  (only that CRAM bit differs from A)
set_property INIT 64'h0000000000000001 $lut
write_bitstream -force $bdir/lut_B.bit
puts "=== A: $bdir/lut_A.bit  B: $bdir/lut_B.bit ==="
exit
