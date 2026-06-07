-- axil_framebuf.vhd — AXI4-Lite slave backing a 256x32 RAM, with a second read-only
-- port for the NEORV32 soft-core (zynq_xpart T2.3). The PS stages the ICAP frame-write
-- sequence here over AXI; NEORV32 reads it (rd_addr/rd_data, 1-cycle registered) and
-- streams it to the ICAP controller. Single FCLK0 clock domain on both ports.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axil_framebuf is
  port (
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    -- AXI4-Lite slave (PS writes the payload; reads supported for debug)
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
    -- NEORV32 read-only port
    rd_addr       : in  std_logic_vector(7 downto 0);
    rd_data       : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axil_framebuf is
  type ram_t is array(0 to 255) of std_logic_vector(31 downto 0);
  signal ram : ram_t := (others => (others => '0'));

  signal awready_r, wready_r, bvalid_r : std_logic := '0';
  signal arready_r, rvalid_r           : std_logic := '0';
  signal rdata_r                       : std_logic_vector(31 downto 0) := (others => '0');
  signal rd_data_r                     : std_logic_vector(31 downto 0) := (others => '0');
begin
  s_axi_awready <= awready_r;
  s_axi_wready  <= wready_r;
  s_axi_bvalid  <= bvalid_r;
  s_axi_bresp   <= "00";
  s_axi_arready <= arready_r;
  s_axi_rvalid  <= rvalid_r;
  s_axi_rresp   <= "00";
  s_axi_rdata   <= rdata_r;
  rd_data       <= rd_data_r;

  -- write channel: accept aw+w together, write RAM, single bresp
  wr: process(s_axi_aclk)
    variable wi : integer range 0 to 255;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        awready_r <= '0'; wready_r <= '0'; bvalid_r <= '0';
      else
        awready_r <= '0'; wready_r <= '0';
        if (s_axi_awvalid = '1' and s_axi_wvalid = '1' and awready_r = '0'
            and wready_r = '0' and bvalid_r = '0') then
          awready_r <= '1'; wready_r <= '1';
          wi := to_integer(unsigned(s_axi_awaddr(9 downto 2)));
          for b in 0 to 3 loop
            if s_axi_wstrb(b) = '1' then
              ram(wi)(b*8+7 downto b*8) <= s_axi_wdata(b*8+7 downto b*8);
            end if;
          end loop;
          bvalid_r <= '1';
        elsif (bvalid_r = '1' and s_axi_bready = '1') then
          bvalid_r <= '0';
        end if;
      end if;
    end if;
  end process;

  -- read channel (AXI side, for debug)
  rd: process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        arready_r <= '0'; rvalid_r <= '0';
      else
        arready_r <= '0';
        if (s_axi_arvalid = '1' and arready_r = '0' and rvalid_r = '0') then
          arready_r <= '1';
          rdata_r   <= ram(to_integer(unsigned(s_axi_araddr(9 downto 2))));
          rvalid_r  <= '1';
        elsif (rvalid_r = '1' and s_axi_rready = '1') then
          rvalid_r <= '0';
        end if;
      end if;
    end if;
  end process;

  -- NEORV32 read-only port (registered, 1-cycle latency)
  nrd: process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      rd_data_r <= ram(to_integer(unsigned(rd_addr)));
    end if;
  end process;
end architecture;
