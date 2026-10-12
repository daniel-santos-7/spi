----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI datapath (shift registers, bit count, receive buffer)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity spi_datapath is
    generic (
        WIDTH    : positive := 32;
        CNT_BITS : positive := 6
    );
    port (
        clk_i      : in  std_logic;
        rst_i      : in  std_logic;

        start_i    : in  std_logic;
        stop_i     : in  std_logic;
        rise_i     : in  std_logic;
        fall_i     : in  std_logic;
        load_i     : in  std_logic;

        din_i      : in  std_logic;
        dout_o     : out std_logic;

        tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        done_o     : out std_logic;

        rx_ready_i : in  std_logic;
        rx_valid_o : out std_logic;
        rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_datapath;

architecture rtl of spi_datapath is

    signal bit_cnt  : unsigned(CNT_BITS-1 downto 0);
    signal wlen     : unsigned(CNT_BITS-1 downto 0);

    signal tx_sh    : std_logic_vector(WIDTH-1 downto 0);
    signal rx_sh    : std_logic_vector(WIDTH-1 downto 0);

    signal rx_valid : std_logic;
    signal rx_data  : std_logic_vector(WIDTH-1 downto 0);
    signal rx_bits  : std_logic_vector(CNT_BITS-1 downto 0);

begin

    assert WIDTH >= 2 report "SPI datapath: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI datapath: CNT_BITS too small to count WIDTH." severity failure;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                bit_cnt <= (others => '0');
            elsif start_i = '1' then
                bit_cnt <= (others => '0');
            elsif rise_i = '1' and bit_cnt /= WIDTH then
                bit_cnt <= bit_cnt + 1;
            end if;
        end if;
    end process cnt_proc;

    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or (stop_i = '1' and bit_cnt /= 0) then
                tx_sh <= (others => '0');
            elsif load_i = '1' then
                tx_sh <= tx_data_i;
            elsif fall_i = '1' then
                tx_sh <= tx_sh(WIDTH-2 downto 0) & '0';
            end if;
        end if;
    end process tx_proc;

    len_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                wlen <= (others => '0');
            elsif load_i = '1' then
                wlen <= unsigned(tx_bits_i);
            end if;
        end if;
    end process len_proc;

    rx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                rx_sh <= (others => '0');
            elsif start_i = '1' then
                rx_sh <= (others => '0');
            elsif rise_i = '1' and bit_cnt /= WIDTH then
                rx_sh <= rx_sh(WIDTH-2 downto 0) & din_i;
            end if;
        end if;
    end process rx_proc;

    rx_buf_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                rx_valid <= '0';
                rx_data  <= (others => '0');
                rx_bits  <= (others => '0');
            elsif rx_valid = '0' or rx_ready_i = '1' then
                rx_valid <= stop_i;
                rx_data  <= rx_sh;
                rx_bits  <= std_logic_vector(bit_cnt);
            end if;
        end if;
    end process rx_buf_proc;

    dout_o     <= tx_sh(WIDTH-1);
    done_o     <= '1' when bit_cnt = wlen or bit_cnt = WIDTH else '0';
    rx_valid_o <= rx_valid;
    rx_data_o  <= rx_data;
    rx_bits_o  <= rx_bits;

end architecture rtl;
