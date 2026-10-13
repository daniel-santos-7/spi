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
        sclk_i     : in  std_logic;
        cs_n_i     : in  std_logic;
        mosi_i     : in  std_logic;
        miso_i     : in  std_logic;
        tx_valid_i : in  std_logic;
        tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        rx_ready_i : in  std_logic;
        role_ack_o : out std_logic;
        sclk_o     : out std_logic;
        sclk_oe    : out std_logic;
        cs_n_o     : out std_logic;
        cs_n_oe    : out std_logic;
        mosi_o     : out std_logic;
        mosi_oe    : out std_logic;
        miso_o     : out std_logic;
        miso_oe    : out std_logic;
        tx_ready_o : out std_logic;
        rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0);
        rx_valid_o : out std_logic
    );
end entity spi_port;

architecture rtl of spi_port is

    signal spi_port_sync_sclk      : std_logic;
    signal spi_port_sync_cs_n      : std_logic;
    signal spi_port_sync_mosi      : std_logic;

    signal spi_port_edge_cs_n_fall : std_logic;
    signal spi_port_edge_cs_n_rise : std_logic;
    signal spi_port_edge_sclk_rise : std_logic;
    signal spi_port_edge_sclk_fall : std_logic;

    signal spi_port_ctrl_role_ack  : std_logic;
    signal spi_port_ctrl_role      : std_logic;
    signal spi_port_ctrl_sclk      : std_logic;
    signal spi_port_ctrl_sclk_oe   : std_logic;
    signal spi_port_ctrl_cs_n      : std_logic;
    signal spi_port_ctrl_cs_n_oe   : std_logic;
    signal spi_port_ctrl_mosi_oe   : std_logic;
    signal spi_port_ctrl_miso_oe   : std_logic;
    signal spi_port_ctrl_tx_ready  : std_logic;
    signal spi_port_ctrl_start     : std_logic;
    signal spi_port_ctrl_stop      : std_logic;
    signal spi_port_ctrl_sample    : std_logic;
    signal spi_port_ctrl_shift     : std_logic;
    signal spi_port_ctrl_load      : std_logic;

    signal spi_port_trx_mosi       : std_logic;
    signal spi_port_trx_miso       : std_logic;
    signal spi_port_trx_done       : std_logic;
    signal spi_port_trx_load       : std_logic;
    signal spi_port_trx_data       : std_logic_vector(WIDTH-1 downto 0);
    signal spi_port_trx_bits       : std_logic_vector(CNT_BITS-1 downto 0);

    signal spi_port_rx_buf_valid   : std_logic;
    signal spi_port_rx_buf_data    : std_logic_vector(WIDTH-1 downto 0);
    signal spi_port_rx_buf_bits    : std_logic_vector(CNT_BITS-1 downto 0);

begin

    spi_port_sync: entity work.spi_sync port map (
        clk_i  => clk_i,
        rst_i  => rst_i,
        sclk_i => sclk_i,
        cs_n_i => cs_n_i,
        mosi_i => mosi_i,
        sclk_o => spi_port_sync_sclk,
        cs_n_o => spi_port_sync_cs_n,
        mosi_o => spi_port_sync_mosi
    );

    spi_port_edge: entity work.spi_edge port map (
        clk_i       => clk_i,
        rst_i       => rst_i,
        sclk_i      => spi_port_sync_sclk,
        cs_n_i      => spi_port_sync_cs_n,
        cs_n_fall_o => spi_port_edge_cs_n_fall,
        cs_n_rise_o => spi_port_edge_cs_n_rise,
        sclk_rise_o => spi_port_edge_sclk_rise,
        sclk_fall_o => spi_port_edge_sclk_fall
    );

    spi_port_ctrl: entity work.spi_ctrl generic map (
        SCK_DIV => SCK_DIV
    ) port map (
        clk_i       => clk_i,
        rst_i       => rst_i,
        role_req_i  => role_req_i,
        cs_n_fall_i => spi_port_edge_cs_n_fall,
        cs_n_rise_i => spi_port_edge_cs_n_rise,
        sclk_rise_i => spi_port_edge_sclk_rise,
        sclk_fall_i => spi_port_edge_sclk_fall,
        tx_valid_i  => tx_valid_i,
        done_i      => spi_port_trx_done,
        role_ack_o  => spi_port_ctrl_role_ack,
        role_o      => spi_port_ctrl_role,
        sclk_o      => spi_port_ctrl_sclk,
        sclk_oe     => spi_port_ctrl_sclk_oe,
        cs_n_o      => spi_port_ctrl_cs_n,
        cs_n_oe     => spi_port_ctrl_cs_n_oe,
        mosi_oe     => spi_port_ctrl_mosi_oe,
        miso_oe     => spi_port_ctrl_miso_oe,
        tx_ready_o  => spi_port_ctrl_tx_ready,
        start_o     => spi_port_ctrl_start,
        stop_o      => spi_port_ctrl_stop,
        sample_o    => spi_port_ctrl_sample,
        shift_o     => spi_port_ctrl_shift,
        load_o      => spi_port_ctrl_load
    );

    spi_port_trx: entity work.spi_trx generic map (
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i    => clk_i,
        rst_i    => rst_i,
        start_i  => spi_port_ctrl_start,
        stop_i   => spi_port_ctrl_stop,
        sample_i => spi_port_ctrl_sample,
        shift_i  => spi_port_ctrl_shift,
        load_i   => spi_port_ctrl_load,
        role_i   => spi_port_ctrl_role,
        miso_i   => miso_i,
        mosi_i   => spi_port_sync_mosi,
        data_i   => tx_data_i,
        bits_i   => tx_bits_i,
        mosi_o   => spi_port_trx_mosi,
        miso_o   => spi_port_trx_miso,
        done_o   => spi_port_trx_done,
        load_o   => spi_port_trx_load,
        data_o   => spi_port_trx_data,
        bits_o   => spi_port_trx_bits
    );

    spi_port_rx_buf: entity work.spi_rx_buf generic map (
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i   => clk_i,
        rst_i   => rst_i,
        load_i  => spi_port_trx_load,
        data_i  => spi_port_trx_data,
        bits_i  => spi_port_trx_bits,
        ready_i => rx_ready_i,
        valid_o => spi_port_rx_buf_valid,
        data_o  => spi_port_rx_buf_data,
        bits_o  => spi_port_rx_buf_bits
    );

    role_ack_o <= spi_port_ctrl_role_ack;
    sclk_o     <= spi_port_ctrl_sclk;
    sclk_oe    <= spi_port_ctrl_sclk_oe;
    cs_n_o     <= spi_port_ctrl_cs_n;
    cs_n_oe    <= spi_port_ctrl_cs_n_oe;
    mosi_o     <= spi_port_trx_mosi;
    mosi_oe    <= spi_port_ctrl_mosi_oe;
    miso_o     <= spi_port_trx_miso;
    miso_oe    <= spi_port_ctrl_miso_oe;
    tx_ready_o <= spi_port_ctrl_tx_ready;
    rx_data_o  <= spi_port_rx_buf_data;
    rx_bits_o  <= spi_port_rx_buf_bits;
    rx_valid_o <= spi_port_rx_buf_valid;

end architecture rtl;
