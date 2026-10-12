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
        clk_i      : in  std_logic;
        rst_i      : in  std_logic;
        dbg_i      : in  std_logic;
        dbg_o      : out std_logic;
        sclk_i     : in  std_logic;
        sclk_o     : out std_logic;
        sclk_oe    : out std_logic;
        cs_n_i     : in  std_logic;
        cs_n_o     : out std_logic;
        cs_n_oe    : out std_logic;
        mosi_i     : in  std_logic;
        mosi_o     : out std_logic;
        mosi_oe    : out std_logic;
        miso_i     : in  std_logic;
        miso_o     : out std_logic;
        miso_oe    : out std_logic;
        tx_valid_i : in  std_logic;
        tx_ready_o : out std_logic;
        tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        rx_ready_i : in  std_logic;
        rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0);
        rx_valid_o : out std_logic
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
    signal sh_rx    : std_logic_vector(WIDTH-1 downto 0);
    signal sh_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal sh_put   : std_logic;

    signal rx_valid : std_logic;
    signal rx_data  : std_logic_vector(WIDTH-1 downto 0);
    signal rx_bits  : std_logic_vector(CNT_BITS-1 downto 0);

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
        SCK_DIV  => SCK_DIV,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i      => clk_i,
        rst_i      => rst_i,
        dbg_i      => dbg,
        sclk_i     => s_sclk,
        cs_n_i     => s_cs_n_s,
        sclk_o     => sclk_o,
        cs_n_o     => cs_n_o,
        tx_valid_i => tx_valid_i,
        tx_bits_i  => tx_bits_i,
        start_o    => sh_start,
        stop_o     => sh_stop,
        rise_o     => sh_rise,
        fall_o     => sh_fall
    );

    sh_din <= s_mosi when dbg = '1' else miso_i;

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
        tx_valid_i => tx_valid_i,
        tx_data_i  => tx_data_i,
        tx_ready_o => tx_ready_o,
        rx_data_o  => sh_rx,
        rx_bits_o  => sh_bits,
        rx_valid_o => sh_put
    );

    rx_buf_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                rx_valid <= '0';
                rx_data  <= (others => '0');
                rx_bits  <= (others => '0');
            elsif rx_valid = '0' or rx_ready_i = '1' then
                rx_valid <= sh_put;
                rx_data  <= sh_rx;
                rx_bits  <= sh_bits;
            end if;
        end if;
    end process rx_buf_proc;

    mosi_o     <= sh_dout;
    miso_o     <= sh_dout;
    rx_valid_o <= rx_valid;
    rx_data_o  <= rx_data;
    rx_bits_o  <= rx_bits;

    sclk_oe <= not dbg;
    cs_n_oe <= not dbg;
    mosi_oe <= not dbg;
    miso_oe <= dbg and not cs_n_i;
    dbg_o   <= dbg;

end architecture rtl;
