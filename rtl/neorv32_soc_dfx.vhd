-- neorv32_soc_dfx.vhd — NEORV32 + 4x4 INT8 TPU SoC for the Zynq-7010 PL (zynq_xpart, M2).
--
-- Ported from ax301_top.vhd (EP4CE6). Changes for Zynq:
--   * SDRAM controller removed (no PL SDRAM; firmware runs from internal IMEM).
--   * Added a "mailbox" register so firmware results are visible to the PS: the
--     PS reads mbox_o over AXI via an AXI-GPIO(input) in the block design
--     (the same trick proven in Phase-1 M1).
--
-- XBUS (Wishbone) memory map seen by NEORV32:
--   0xF0000xxx : TPU (tpu_rp — systolic regs + LUT mem), unchanged from EP4CE6
--   0xF1000xxx : MBOX result register (write) -> mbox_o / mbox_valid_o
--   others     : default ACK, reads 0 (so the CPU never hangs on stray accesses)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_soc_dfx is
  port (
    clk_i        : in  std_ulogic;                      -- PS FCLK_CLK0
    rstn_i       : in  std_ulogic;                      -- active-low reset (PS)
    uart0_txd_o  : out std_ulogic;
    uart0_rxd_i  : in  std_ulogic;
    gpio_o       : out std_ulogic_vector(3 downto 0);   -- debug LEDs
    mbox_o       : out std_ulogic_vector(31 downto 0);  -- firmware result -> PS
    mbox_valid_o : out std_ulogic
  );
end entity neorv32_soc_dfx;

architecture rtl of neorv32_soc_dfx is

  signal rstn_int : std_ulogic;
  signal por_cnt  : std_ulogic_vector(3 downto 0) := (others => '0');
  signal gpio_out : std_ulogic_vector(31 downto 0);

  -- XBUS from NEORV32
  signal xbus_adr   : std_ulogic_vector(31 downto 0);
  signal xbus_dat_o : std_ulogic_vector(31 downto 0);
  signal xbus_dat_i : std_ulogic_vector(31 downto 0);
  signal xbus_we    : std_ulogic;
  signal xbus_sel   : std_ulogic_vector(3 downto 0);
  signal xbus_stb   : std_ulogic;
  signal xbus_cyc   : std_ulogic;
  signal xbus_ack   : std_ulogic;
  signal xbus_err   : std_ulogic;

  -- decode
  signal tpu_selected  : std_ulogic;
  signal mbox_selected : std_ulogic;
  signal def_selected  : std_ulogic;

  -- TPU
  signal tpu_dat_r : std_ulogic_vector(31 downto 0);
  signal tpu_ack   : std_ulogic;
  signal tpu_err   : std_ulogic;
  signal tpu_stb   : std_ulogic;
  signal tpu_dbg   : std_ulogic_vector(3 downto 0);

  -- mailbox + default slave
  signal mbox_reg  : std_ulogic_vector(31 downto 0) := (others => '0');
  signal mbox_vld  : std_ulogic := '0';
  signal mbox_ack  : std_ulogic := '0';
  signal def_ack   : std_ulogic := '0';

  component tpu_rp is
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
      xbus_err   : out std_ulogic;
      dbg_leds   : out std_ulogic_vector(3 downto 0)
    );
  end component;

begin

  -- power-on reset, held by external reset
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

  -- address decode (4 KB granularity)
  tpu_selected  <= '1' when xbus_adr(31 downto 12) = x"F0000" else '0';
  mbox_selected <= '1' when xbus_adr(31 downto 12) = x"F1000" else '0';
  def_selected  <= '1' when (tpu_selected = '0' and mbox_selected = '0') else '0';

  tpu_stb <= xbus_stb when tpu_selected = '1' else '0';

  -- mailbox: latch firmware writes; ack any access
  mbox: process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rstn_int = '0' then
        mbox_reg <= (others => '0');
        mbox_vld <= '0';
        mbox_ack <= '0';
      else
        mbox_ack <= xbus_cyc and xbus_stb and mbox_selected;
        if (xbus_cyc and xbus_stb and mbox_selected and xbus_we) = '1' then
          mbox_reg <= xbus_dat_o;
          mbox_vld <= '1';
        end if;
      end if;
    end if;
  end process;

  -- default slave: ack stray accesses so the CPU never times out
  defslv: process(clk_i)
  begin
    if rising_edge(clk_i) then
      def_ack <= xbus_cyc and xbus_stb and def_selected;
    end if;
  end process;

  -- XBUS response
  xbus_dat_i <= tpu_dat_r when tpu_ack = '1' else
                mbox_reg  when mbox_ack = '1' else
                (others => '0');
  xbus_ack   <= tpu_ack or mbox_ack or def_ack;
  xbus_err   <= tpu_err;

  mbox_o       <= mbox_reg;
  mbox_valid_o <= mbox_vld;
  gpio_o       <= gpio_out(3 downto 0);

  -- NEORV32 core (config from the validated EP4CE6 ax301_top, IMEM enlarged for
  -- a self-contained firmware image, SPI dropped)
  neorv32_inst: neorv32_top
  generic map (
    CLOCK_FREQUENCY  => 50_000_000,
    BOOT_MODE_SELECT => 2,            -- execute from pre-initialized IMEM image
    RISCV_ISA_C      => true,
    RISCV_ISA_M      => true,
    RISCV_ISA_U      => true,
    RISCV_ISA_Zaamo  => true,
    RISCV_ISA_Zalrsc => true,
    RISCV_ISA_Zicntr => true,
    IMEM_EN          => true,
    IMEM_SIZE        => 32*1024,
    DMEM_EN          => true,
    DMEM_SIZE        => 16*1024,
    XBUS_EN          => true,
    XBUS_TIMEOUT     => 4096,
    XBUS_REGSTAGE_EN => false,
    ICACHE_EN        => true,
    CACHE_BLOCK_SIZE => 64,
    DCACHE_EN        => false,
    IO_GPIO_NUM      => 4,
    IO_CLINT_EN      => true,
    IO_UART0_EN      => true,
    IO_UART0_RX_FIFO => 4,
    IO_UART0_TX_FIFO => 4,
    IO_SPI_EN        => false,
    OCD_EN           => false,
    DUAL_CORE_EN     => false
  )
  port map (
    clk_i        => clk_i,
    rstn_i       => rstn_int,
    xbus_adr_o   => xbus_adr,
    xbus_dat_o   => xbus_dat_o,
    xbus_cti_o   => open,
    xbus_tag_o   => open,
    xbus_dat_i   => xbus_dat_i,
    xbus_we_o    => xbus_we,
    xbus_sel_o   => xbus_sel,
    xbus_stb_o   => xbus_stb,
    xbus_cyc_o   => xbus_cyc,
    xbus_ack_i   => xbus_ack,
    xbus_err_i   => xbus_err,
    gpio_o       => gpio_out,
    uart0_txd_o  => uart0_txd_o,
    uart0_rxd_i  => uart0_rxd_i
  );

  wb_tpu_inst: tpu_rp
  port map (
    clk        => clk_i,
    rst_n      => rstn_int,
    xbus_adr   => xbus_adr,
    xbus_dat_w => xbus_dat_o,
    xbus_sel   => xbus_sel,
    xbus_we    => xbus_we,
    xbus_stb   => tpu_stb,
    xbus_cyc   => xbus_cyc,
    xbus_dat_r => tpu_dat_r,
    xbus_ack   => tpu_ack,
    xbus_err   => tpu_err,
    dbg_leds   => tpu_dbg
  );

end architecture rtl;
