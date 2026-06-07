-- neorv32_soc_icap.vhd — NEORV32 SoC that drives ICAP from inside the fabric (T2.3).
--
-- "Fabric self-modifies": NEORV32 streams a single-frame config-write sequence to the
-- custom XBUS->ICAPE2 controller (rtl/xbus_icap.v), rewriting one CRAM frame (a LUT6
-- truth table) live. The reconfiguration EXECUTION path is 100% in-fabric (NEORV32 ->
-- xbus_icap -> ICAPE2). The PS only (a) stages the frame payload once into a shared
-- dual-port BRAM and (b) grants ICAP the config engine (devcfg PCAP_PR=0) and observes
-- -- it is never in the reconfiguration loop itself (cf. the external-review DDR-staging
-- pattern). Payload-in-BRAM (not baked in IMEM) also decouples the frame from the build,
-- avoiding the IMEM-baked-frame non-convergence (the LUT frame shares the column's
-- routing bits, which shift every build).
--
-- XBUS (Wishbone) memory map seen by NEORV32:
--   0xF1000xxx : MBOX status register (write) -> mbox_o (PS reads over AXI-GPIO)
--   0xF3000xxx : xbus_icap controller (custom XBUS->ICAPE2)
--   0xF4000xxx : LUT readback (read) -> lut_probe output bit0 (NEORV32 sees its edit)
--   0xF5000xxx : frame payload BRAM (read) -> staged by the PS via an AXI BRAM Ctrl
--   others     : default ACK, reads 0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_soc_icap is
  port (
    clk_i        : in  std_ulogic;                      -- PS FCLK_CLK0
    rstn_i       : in  std_ulogic;                      -- active-low reset (PS)
    uart0_txd_o  : out std_ulogic;
    uart0_rxd_i  : in  std_ulogic;
    mbox_o       : out std_ulogic_vector(31 downto 0);  -- NEORV32 status -> PS
    mbox_valid_o : out std_ulogic;
    lut_o        : out std_ulogic_vector(31 downto 0);  -- lut_probe output -> PS GPIO
    -- AXI4-Lite slave: PS stages the ICAP frame payload into the shared framebuf
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(9 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(9 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic
  );
end entity neorv32_soc_icap;

architecture rtl of neorv32_soc_icap is

  signal rstn_int : std_ulogic;
  signal por_cnt  : std_ulogic_vector(3 downto 0) := (others => '0');

  signal xbus_adr   : std_ulogic_vector(31 downto 0);
  signal xbus_dat_o : std_ulogic_vector(31 downto 0);
  signal xbus_dat_i : std_ulogic_vector(31 downto 0);
  signal xbus_we    : std_ulogic;
  signal xbus_sel   : std_ulogic_vector(3 downto 0);
  signal xbus_stb   : std_ulogic;
  signal xbus_cyc   : std_ulogic;
  signal xbus_ack   : std_ulogic;
  signal xbus_err   : std_ulogic;

  signal mbox_selected : std_ulogic;
  signal icap_selected : std_ulogic;
  signal lut_selected  : std_ulogic;
  signal fb_selected   : std_ulogic;
  signal def_selected  : std_ulogic;

  signal icap_dat_r : std_ulogic_vector(31 downto 0);
  signal icap_ack   : std_ulogic;
  signal icap_err   : std_ulogic;
  signal icap_stb   : std_ulogic;

  signal mbox_reg  : std_ulogic_vector(31 downto 0) := (others => '0');
  signal mbox_vld  : std_ulogic := '0';
  signal mbox_ack  : std_ulogic := '0';
  signal lut_ack   : std_ulogic := '0';
  signal def_ack   : std_ulogic := '0';
  signal lut_q     : std_ulogic_vector(31 downto 0);

  -- frame-BRAM read port (1-cycle registered ack)
  signal fb_ack    : std_ulogic := '0';
  signal fb_rddata : std_logic_vector(31 downto 0);

  component axil_framebuf is
    port (
      s_axi_aclk    : in  std_logic;
      s_axi_aresetn : in  std_logic;
      s_axi_awaddr  : in  std_logic_vector(9 downto 0);
      s_axi_awvalid : in  std_logic;
      s_axi_awready : out std_logic;
      s_axi_wdata   : in  std_logic_vector(31 downto 0);
      s_axi_wstrb   : in  std_logic_vector(3 downto 0);
      s_axi_wvalid  : in  std_logic;
      s_axi_wready  : out std_logic;
      s_axi_bresp   : out std_logic_vector(1 downto 0);
      s_axi_bvalid  : out std_logic;
      s_axi_bready  : in  std_logic;
      s_axi_araddr  : in  std_logic_vector(9 downto 0);
      s_axi_arvalid : in  std_logic;
      s_axi_arready : out std_logic;
      s_axi_rdata   : out std_logic_vector(31 downto 0);
      s_axi_rresp   : out std_logic_vector(1 downto 0);
      s_axi_rvalid  : out std_logic;
      s_axi_rready  : in  std_logic;
      rd_addr       : in  std_logic_vector(7 downto 0);
      rd_data       : out std_logic_vector(31 downto 0)
    );
  end component;

  component xbus_icap is
    port (
      clk        : in  std_ulogic;
      rst_n      : in  std_ulogic;
      xbus_adr   : in  std_ulogic_vector(31 downto 0);
      xbus_dat_w : in  std_ulogic_vector(31 downto 0);
      xbus_sel   : in  std_ulogic_vector(3 downto 0);
      xbus_we    : in  std_ulogic;
      xbus_stb   : in  std_ulogic;
      xbus_cyc   : in  std_ulogic;
      xbus_dat_r : out std_ulogic_vector(31 downto 0);
      xbus_ack   : out std_ulogic;
      xbus_err   : out std_ulogic
    );
  end component;

  component lut_probe is
    port ( q : out std_ulogic_vector(31 downto 0) );
  end component;

begin

  por: process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        por_cnt <= (others => '0');
      elsif por_cnt /= x"F" then
        por_cnt <= std_ulogic_vector(unsigned(por_cnt) + 1);
      end if;
    end if;
  end process;
  rstn_int <= '1' when (por_cnt = x"F") else '0';

  mbox_selected <= '1' when xbus_adr(31 downto 12) = x"F1000" else '0';
  icap_selected <= '1' when xbus_adr(31 downto 12) = x"F3000" else '0';
  lut_selected  <= '1' when xbus_adr(31 downto 12) = x"F4000" else '0';
  fb_selected   <= '1' when xbus_adr(31 downto 12) = x"F5000" else '0';
  def_selected  <= '1' when (mbox_selected = '0' and icap_selected = '0'
                             and lut_selected = '0' and fb_selected = '0') else '0';

  icap_stb <= xbus_stb when icap_selected = '1' else '0';

  mbox: process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_int = '0' then
        mbox_reg <= (others => '0'); mbox_vld <= '0'; mbox_ack <= '0';
      else
        mbox_ack <= xbus_cyc and xbus_stb and mbox_selected;
        if (xbus_cyc and xbus_stb and mbox_selected and xbus_we) = '1' then
          mbox_reg <= xbus_dat_o; mbox_vld <= '1';
        end if;
      end if;
    end if;
  end process;

  lutslv: process(clk_i)
  begin
    if rising_edge(clk_i) then
      lut_ack <= xbus_cyc and xbus_stb and lut_selected;
    end if;
  end process;

  defslv: process(clk_i)
  begin
    if rising_edge(clk_i) then
      def_ack <= xbus_cyc and xbus_stb and def_selected;
    end if;
  end process;

  -- frame-BRAM read: 1-cycle registered ack. The framebuf read port (rd_data) is
  -- registered (valid 1 cycle after rd_addr, which tracks xbus_adr combinationally), so
  -- a 1-cycle ack aligns data with ack. Must be 1-cycle like the proven mailbox/default
  -- slaves: NEORV32 XBUS deasserts stb on acceptance, so a multi-cycle ack never fires.
  fbproc: process(clk_i)
  begin
    if rising_edge(clk_i) then
      fb_ack <= xbus_cyc and xbus_stb and fb_selected;
    end if;
  end process;
  xbus_dat_i <= icap_dat_r              when icap_ack = '1' else
                mbox_reg                when mbox_ack = '1' else
                lut_q                   when lut_ack  = '1' else
                std_ulogic_vector(fb_rddata) when fb_ack = '1' else
                (others => '0');
  xbus_ack   <= icap_ack or mbox_ack or lut_ack or fb_ack or def_ack;
  xbus_err   <= icap_err;

  mbox_o       <= mbox_reg;
  mbox_valid_o <= mbox_vld;
  lut_o        <= lut_q;

  neorv32_inst: neorv32_top
  generic map (
    CLOCK_FREQUENCY  => 50_000_000, BOOT_MODE_SELECT => 2,
    RISCV_ISA_C => true, RISCV_ISA_M => true, RISCV_ISA_U => true,
    RISCV_ISA_Zaamo => true, RISCV_ISA_Zalrsc => true, RISCV_ISA_Zicntr => true,
    IMEM_EN => true, IMEM_SIZE => 32*1024, DMEM_EN => true, DMEM_SIZE => 16*1024,
    XBUS_EN => true, XBUS_TIMEOUT => 4096, XBUS_REGSTAGE_EN => false,
    ICACHE_EN => true, CACHE_BLOCK_SIZE => 64, DCACHE_EN => false,
    IO_GPIO_NUM => 4, IO_CLINT_EN => true, IO_UART0_EN => true,
    IO_UART0_RX_FIFO => 4, IO_UART0_TX_FIFO => 4, IO_SPI_EN => false,
    OCD_EN => false, DUAL_CORE_EN => false
  )
  port map (
    clk_i => clk_i, rstn_i => rstn_int,
    xbus_adr_o => xbus_adr, xbus_dat_o => xbus_dat_o, xbus_cti_o => open,
    xbus_tag_o => open, xbus_dat_i => xbus_dat_i, xbus_we_o => xbus_we,
    xbus_sel_o => xbus_sel, xbus_stb_o => xbus_stb, xbus_cyc_o => xbus_cyc,
    xbus_ack_i => xbus_ack, xbus_err_i => xbus_err,
    gpio_o => open, uart0_txd_o => uart0_txd_o, uart0_rxd_i => uart0_rxd_i
  );

  icap_inst: xbus_icap
  port map (
    clk => clk_i, rst_n => rstn_int, xbus_adr => xbus_adr, xbus_dat_w => xbus_dat_o,
    xbus_sel => xbus_sel, xbus_we => xbus_we, xbus_stb => icap_stb, xbus_cyc => xbus_cyc,
    xbus_dat_r => icap_dat_r, xbus_ack => icap_ack, xbus_err => icap_err
  );

  lut_inst: lut_probe port map ( q => lut_q );

  -- shared frame payload: PS writes via AXI-Lite; NEORV32 reads word index xbus_adr[9:2]
  framebuf_inst: axil_framebuf
  port map (
    s_axi_aclk => s_axi_aclk, s_axi_aresetn => s_axi_aresetn,
    s_axi_awaddr => s_axi_awaddr, s_axi_awvalid => s_axi_awvalid, s_axi_awready => s_axi_awready,
    s_axi_wdata => s_axi_wdata, s_axi_wstrb => s_axi_wstrb, s_axi_wvalid => s_axi_wvalid,
    s_axi_wready => s_axi_wready, s_axi_bresp => s_axi_bresp, s_axi_bvalid => s_axi_bvalid,
    s_axi_bready => s_axi_bready, s_axi_araddr => s_axi_araddr, s_axi_arvalid => s_axi_arvalid,
    s_axi_arready => s_axi_arready, s_axi_rdata => s_axi_rdata, s_axi_rresp => s_axi_rresp,
    s_axi_rvalid => s_axi_rvalid, s_axi_rready => s_axi_rready,
    rd_addr => std_logic_vector(xbus_adr(9 downto 2)), rd_data => fb_rddata
  );

end architecture rtl;

