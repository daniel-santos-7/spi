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
    signal sh_stop  : std_logic;
    signal sh_rise  : std_logic;
    signal sh_fall  : std_logic;
    signal sh_din   : std_logic;
    signal sh_dout  : std_logic;
    signal sh_busy  : std_logic;
    signal sh_tx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_txb   : std_logic_vector(CNT_BITS-1 downto 0);
    signal sh_chain : std_logic;
    signal sh_pop   : std_logic;
    signal sh_open  : std_logic;
    signal sh_end   : std_logic;
    signal sh_rx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal sh_last  : std_logic;
    signal sh_put   : std_logic;

    signal tx_valid : std_logic;
    signal tx_ready : std_logic;
    signal tx_push  : std_logic;
    signal tx_data  : std_logic_vector(WIDTH-1 downto 0);
    signal tx_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal tx_in    : std_logic_vector(WIDTH+CNT_BITS downto 0);
    signal tx_out   : std_logic_vector(WIDTH+CNT_BITS downto 0);
    signal tx_pend  : std_logic;

    signal rx_ready : std_logic;
    signal rx_in    : std_logic_vector(WIDTH+CNT_BITS downto 0);
    signal rx_out   : std_logic_vector(WIDTH+CNT_BITS downto 0);
    signal rx_valid : std_logic;

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
        tx_valid_i => tx_pend,
        tx_end_i   => sh_end,
        start_o    => sh_start,
        stop_o     => sh_stop,
        rise_o     => sh_rise,
        fall_o     => sh_fall
    );

    sh_din   <= s_mosi       when dbg = '1' else miso_i;
    tx_valid <= s_tx_valid_i when dbg = '1' else m_tx_valid_i;
    tx_data  <= s_tx_data_i  when dbg = '1' else m_tx_data_i;
    tx_bits  <= (others => '0') when dbg = '1' else m_tx_bits_i;
    rx_ready <= s_rx_ready_i when dbg = '1' else m_rx_ready_i;

    tx_ready <= not tx_pend and sh_open;
    tx_push  <= tx_valid and tx_ready;
    tx_in    <= sh_busy & tx_bits & tx_data;
    sh_chain <= tx_out(WIDTH+CNT_BITS);
    sh_txb   <= tx_out(WIDTH+CNT_BITS-1 downto WIDTH);
    sh_tx    <= tx_out(WIDTH-1 downto 0);

    spi_port_tx_buf: entity work.spi_buf generic map (
        WIDTH => WIDTH + CNT_BITS + 1
    ) port map (
        clk_i       => clk_i,
        rst_i       => rst_i,
        in_valid_i  => tx_push,
        in_data_i   => tx_in,
        out_ready_i => sh_pop,
        out_valid_o => tx_pend,
        out_data_o  => tx_out
    );

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
        busy_o     => sh_busy,
        tx_valid_i => tx_pend,
        tx_data_i  => sh_tx,
        tx_bits_i  => sh_txb,
        tx_chain_i => sh_chain,
        tx_pop_o   => sh_pop,
        tx_open_o  => sh_open,
        tx_end_o   => sh_end,
        rx_data_o  => sh_rx,
        rx_bits_o  => sh_bits,
        rx_last_o  => sh_last,
        rx_valid_o => sh_put
    );

    rx_in <= sh_last & sh_bits & sh_rx;

    spi_port_rx_buf: entity work.spi_buf generic map (
        WIDTH => WIDTH + CNT_BITS + 1
    ) port map (
        clk_i       => clk_i,
        rst_i       => rst_i,
        in_valid_i  => sh_put,
        in_data_i   => rx_in,
        out_ready_i => rx_ready,
        out_valid_o => rx_valid,
        out_data_o  => rx_out
    );

    mosi_o       <= sh_dout;
    miso_o       <= sh_dout;
    m_rx_data_o  <= rx_out(WIDTH-1 downto 0);
    m_rx_last_o  <= rx_out(WIDTH+CNT_BITS);
    m_rx_valid_o <= rx_valid and not dbg;
    s_rx_data_o  <= rx_out(WIDTH-1 downto 0);
    s_rx_bits_o  <= rx_out(WIDTH+CNT_BITS-1 downto WIDTH);
    s_rx_last_o  <= rx_out(WIDTH+CNT_BITS);
    s_rx_valid_o <= rx_valid and dbg;
    m_tx_ready_o <= tx_ready and not dbg;
    s_tx_ready_o <= tx_ready and dbg;

    sclk_oe <= not dbg;
    cs_n_oe <= not dbg;
    mosi_oe <= not dbg;
    miso_oe <= dbg and not cs_n_i;
    dbg_o   <= dbg;

end architecture rtl;
