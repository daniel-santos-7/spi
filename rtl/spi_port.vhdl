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
        WIDTH    : positive := 32;
        CNT_BITS : positive := 6
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
        m_tx_valid_i : in  std_logic;
        m_tx_ready_o : out std_logic;
        m_tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        m_tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        m_rx_ready_i : in  std_logic;
        m_rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        m_rx_last_o  : out std_logic;
        m_rx_valid_o : out std_logic;
        s_tx_valid_i : in  std_logic;
        s_tx_ready_o : out std_logic;
        s_tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        s_rx_ready_i : in  std_logic;
        s_rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        s_rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0);
        s_rx_last_o  : out std_logic;
        s_rx_valid_o : out std_logic
    );
end entity spi_port;

architecture rtl of spi_port is

    signal dbg      : std_logic;
    signal s_cs_n   : std_logic;
    signal s_sclk   : std_logic;
    signal s_cs_n_s : std_logic;
    signal s_mosi   : std_logic;

    signal sh_start : std_logic;
    signal sh_txv   : std_logic;
    signal sh_txr   : std_logic;
    signal sh_stop  : std_logic;
    signal sh_rise  : std_logic;
    signal sh_fall  : std_logic;
    signal sh_din   : std_logic;
    signal sh_dout  : std_logic;
    signal sh_tx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_txb   : std_logic_vector(CNT_BITS-1 downto 0);
    signal sh_rx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal sh_pend  : std_logic;
    signal sh_end   : std_logic;
    signal sh_last  : std_logic;
    signal sh_rxr   : std_logic;
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

    s_cs_n <= cs_n_i or not dbg;

    spi_port_ctrl: entity work.spi_ctrl generic map (
        SCK_DIV => SCK_DIV
    ) port map (
        clk_i      => clk_i,
        rst_i      => rst_i,
        dbg_i      => dbg,
        sclk_i     => s_sclk,
        cs_n_i     => s_cs_n_s,
        sclk_o     => sclk_o,
        cs_n_o     => cs_n_o,
        tx_valid_i => sh_pend,
        tx_end_i   => sh_end,
        start_o    => sh_start,
        stop_o     => sh_stop,
        rise_o     => sh_rise,
        fall_o     => sh_fall
    );

    sh_txv <= s_tx_valid_i when dbg = '1' else m_tx_valid_i;
    sh_din <= s_mosi       when dbg = '1' else miso_i;
    sh_tx  <= s_tx_data_i  when dbg = '1' else m_tx_data_i;
    sh_txb <= (others => '0') when dbg = '1' else m_tx_bits_i;
    sh_rxr <= s_rx_ready_i when dbg = '1' else m_rx_ready_i;

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
        tx_valid_i => sh_txv,
        tx_ready_o => sh_txr,
        tx_data_i  => sh_tx,
        tx_bits_i  => sh_txb,
        tx_pend_o  => sh_pend,
        tx_end_o   => sh_end,
        rx_ready_i => sh_rxr,
        rx_data_o  => sh_rx,
        rx_bits_o  => sh_bits,
        rx_last_o  => sh_last,
        rx_valid_o => sh_valid
    );

    mosi_o       <= sh_dout;
    miso_o       <= sh_dout;
    m_rx_data_o  <= sh_rx;
    m_rx_last_o  <= sh_last;
    m_rx_valid_o <= sh_valid and not dbg;
    s_rx_data_o  <= sh_rx;
    s_rx_bits_o  <= sh_bits;
    s_rx_last_o  <= sh_last;
    s_rx_valid_o <= sh_valid and dbg;
    m_tx_ready_o <= sh_txr and not dbg;
    s_tx_ready_o <= sh_txr and dbg;

    sclk_oe <= not dbg;
    cs_n_oe <= not dbg;
    mosi_oe <= not dbg;
    miso_oe <= dbg and not cs_n_i;
    dbg_o   <= dbg;

end architecture rtl;
