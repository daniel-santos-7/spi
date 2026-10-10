----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI port (shared pins, master or slave)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_port is
    generic (
        SCK_DIV  : positive := 1;
        WIDTH    : positive := 64;
        CNT_BITS : positive := 7
    );
    port (
        clk_i        : in  std_logic;
        rst_i        : in  std_logic;
        dbg_i        : in  std_logic;
        dbg_o        : out std_logic;
        sclk_i       : in  std_logic;
        sclk_o       : out std_logic;
        sclk_oe      : out std_logic;
        cs_n_i       : in  std_logic;
        cs_n_o       : out std_logic;
        cs_n_oe      : out std_logic;
        mosi_i       : in  std_logic;
        mosi_o       : out std_logic;
        mosi_oe      : out std_logic;
        miso_i       : in  std_logic;
        miso_o       : out std_logic;
        miso_oe      : out std_logic;
        m_start_i    : in  std_logic;
        m_ready_o    : out std_logic;
        m_tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        m_rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        m_rx_valid_o : out std_logic;
        s_rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        s_rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0);
        s_rx_valid_o : out std_logic;
        s_tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0)
    );
end entity spi_port;

architecture rtl of spi_port is

    signal dbg      : std_logic;
    signal m_start  : std_logic;
    signal s_cs_n   : std_logic;
    signal s_sclk   : std_logic;
    signal s_cs_n_s : std_logic;
    signal s_mosi   : std_logic;

    signal m_sh_start : std_logic;
    signal m_sh_stop  : std_logic;
    signal m_sh_rise  : std_logic;
    signal m_sh_fall  : std_logic;
    signal s_sh_start : std_logic;
    signal s_sh_stop  : std_logic;
    signal s_sh_rise  : std_logic;
    signal s_sh_fall  : std_logic;

    signal sh_start : std_logic;
    signal sh_stop  : std_logic;
    signal sh_rise  : std_logic;
    signal sh_fall  : std_logic;
    signal sh_din   : std_logic;
    signal sh_dout  : std_logic;
    signal sh_tx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_rx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal sh_valid : std_logic;

begin

    spi_port_sync: entity work.spi_sync port map (
        clk_i  => clk_i,
        rst_i  => rst_i,
        dbg_i  => dbg_i,
        sclk_i => sclk_i,
        cs_n_i => s_cs_n,
        mosi_i => mosi_i,
        dbg_o  => dbg,
        sclk_o => s_sclk,
        cs_n_o => s_cs_n_s,
        mosi_o => s_mosi
    );

    m_start <= m_start_i and not dbg;
    s_cs_n  <= cs_n_i or not dbg;

    spi_port_master: entity work.spi_master generic map (
        SCK_DIV  => SCK_DIV,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i   => clk_i,
        rst_i   => rst_i,
        sclk_o  => sclk_o,
        cs_n_o  => cs_n_o,
        start_i => m_start,
        ready_o => m_ready_o,
        bits_i  => sh_bits,
        start_o => m_sh_start,
        stop_o  => m_sh_stop,
        rise_o  => m_sh_rise,
        fall_o  => m_sh_fall
    );

    spi_port_slave: entity work.spi_slave port map (
        clk_i   => clk_i,
        rst_i   => rst_i,
        sclk_i  => s_sclk,
        cs_n_i  => s_cs_n_s,
        start_o => s_sh_start,
        stop_o  => s_sh_stop,
        rise_o  => s_sh_rise,
        fall_o  => s_sh_fall
    );

    sh_start <= s_sh_start  when dbg = '1' else m_sh_start;
    sh_stop  <= s_sh_stop   when dbg = '1' else m_sh_stop;
    sh_rise  <= s_sh_rise   when dbg = '1' else m_sh_rise;
    sh_fall  <= s_sh_fall   when dbg = '1' else m_sh_fall;
    sh_din   <= s_mosi      when dbg = '1' else miso_i;
    sh_tx    <= s_tx_data_i when dbg = '1' else m_tx_data_i;

    spi_port_shift: entity work.spi_shift generic map (
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i      => clk_i,
        rst_i      => rst_i,
        start_i    => sh_start,
        stop_i     => sh_stop,
        rise_i     => sh_rise,
        fall_i     => sh_fall,
        din_i      => sh_din,
        dout_o     => sh_dout,
        tx_data_i  => sh_tx,
        rx_data_o  => sh_rx,
        rx_bits_o  => sh_bits,
        rx_valid_o => sh_valid
    );

    mosi_o       <= sh_dout;
    miso_o       <= sh_dout;
    m_rx_data_o  <= sh_rx;
    m_rx_valid_o <= sh_valid and not dbg;
    s_rx_data_o  <= sh_rx;
    s_rx_bits_o  <= sh_bits;
    s_rx_valid_o <= sh_valid and dbg;

    sclk_oe <= not dbg;
    cs_n_oe <= not dbg;
    mosi_oe <= not dbg;
    miso_oe <= dbg and not cs_n_i;
    dbg_o   <= dbg;

end architecture rtl;
