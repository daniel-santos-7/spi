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
        role_req_i : in  std_logic;  -- synchronous to clk_i
        role_ack_o : out std_logic;
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

    signal role     : std_logic;
    signal s_sclk   : std_logic;
    signal s_cs_n   : std_logic;
    signal s_mosi   : std_logic;

    signal sh_start : std_logic;
    signal sh_stop  : std_logic;
    signal sh_rise  : std_logic;
    signal sh_fall  : std_logic;
    signal sh_load  : std_logic;
    signal sh_done  : std_logic;

begin

    spi_port_sync: entity work.spi_sync port map (
        clk_i  => clk_i,
        rst_i  => rst_i,
        sclk_i => sclk_i,
        cs_n_i => cs_n_i,
        mosi_i => mosi_i,
        sclk_o => s_sclk,
        cs_n_o => s_cs_n,
        mosi_o => s_mosi
    );

    spi_port_ctrl: entity work.spi_ctrl generic map (
        SCK_DIV => SCK_DIV
    ) port map (
        clk_i      => clk_i,
        rst_i      => rst_i,
        role_req_i => role_req_i,
        role_ack_o => role_ack_o,
        role_o     => role,
        sclk_i     => s_sclk,
        cs_n_i     => s_cs_n,
        cs_pin_i   => cs_n_i,
        sclk_o     => sclk_o,
        sclk_oe    => sclk_oe,
        cs_n_o     => cs_n_o,
        cs_n_oe    => cs_n_oe,
        mosi_oe    => mosi_oe,
        miso_oe    => miso_oe,
        tx_valid_i => tx_valid_i,
        tx_ready_o => tx_ready_o,
        done_i     => sh_done,
        start_o    => sh_start,
        stop_o     => sh_stop,
        rise_o     => sh_rise,
        fall_o     => sh_fall,
        load_o     => sh_load
    );

    spi_port_datapath: entity work.spi_datapath generic map (
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i      => clk_i,
        rst_i      => rst_i,
        start_i    => sh_start,
        stop_i     => sh_stop,
        rise_i     => sh_rise,
        fall_i     => sh_fall,
        load_i     => sh_load,
        role_i     => role,
        miso_i     => miso_i,
        mosi_i     => s_mosi,
        mosi_o     => mosi_o,
        miso_o     => miso_o,
        tx_data_i  => tx_data_i,
        tx_bits_i  => tx_bits_i,
        done_o     => sh_done,
        rx_ready_i => rx_ready_i,
        rx_valid_o => rx_valid_o,
        rx_data_o  => rx_data_o,
        rx_bits_o  => rx_bits_o
    );

end architecture rtl;
