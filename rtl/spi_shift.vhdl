----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI shift core (words chained in a frame)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity spi_shift is
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

        din_i      : in  std_logic;
        dout_o     : out std_logic;

        busy_o     : out std_logic;

        tx_valid_i : in  std_logic;
        tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);
        tx_chain_i : in  std_logic;
        tx_pop_o   : out std_logic;
        tx_open_o  : out std_logic;
        tx_end_o   : out std_logic;

        rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0);
        rx_last_o  : out std_logic;
        rx_valid_o : out std_logic
    );
end entity spi_shift;

architecture rtl of spi_shift is

    signal bit_cnt  : unsigned(CNT_BITS-1 downto 0);
    signal word_end : std_logic;
    signal load     : std_logic;
    signal busy_reg : std_logic;

    signal tx_sh    : std_logic_vector(WIDTH-1 downto 0);
    signal tx_len   : unsigned(CNT_BITS-1 downto 0);
    signal send_reg : std_logic;
    signal tx_end   : std_logic;

    signal rx_sh    : std_logic_vector(WIDTH-1 downto 0);

begin

    assert WIDTH >= 2 report "SPI shift: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI shift: CNT_BITS too small to count WIDTH." severity failure;

    word_end <= '1' when rise_i = '1' and bit_cnt = WIDTH else '0';
    load     <= '1' when start_i = '1' or (fall_i = '1' and bit_cnt = WIDTH) else '0';
    tx_end   <= '1' when (bit_cnt = WIDTH and tx_valid_i = '0') or (bit_cnt /= WIDTH and bit_cnt = tx_len) else '0';

    busy_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                busy_reg <= '0';
            elsif start_i = '1' then
                busy_reg <= '1';
            elsif stop_i = '1' then
                busy_reg <= '0';
            end if;
        end if;
    end process busy_proc;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                bit_cnt <= (others => '0');
            elsif start_i = '1' then
                bit_cnt <= (others => '0');
            elsif word_end = '1' then
                bit_cnt <= to_unsigned(1, CNT_BITS);
            elsif rise_i = '1' then
                bit_cnt <= bit_cnt + 1;
            end if;
        end if;
    end process cnt_proc;

    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                tx_sh <= (others => '0');
            elsif load = '1' then
                tx_sh <= tx_data_i;
            elsif fall_i = '1' then
                tx_sh <= tx_sh(WIDTH-2 downto 0) & '0';
            end if;
        end if;
    end process tx_proc;

    load_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                send_reg <= '0';
                tx_len   <= (others => '0');
            elsif load = '1' then
                send_reg <= tx_valid_i;
                tx_len   <= unsigned(tx_bits_i);
            end if;
        end if;
    end process load_proc;

    rx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                rx_sh <= (others => '0');
            elsif start_i = '1' then
                rx_sh <= (others => '0');
            elsif word_end = '1' then
                rx_sh <= (WIDTH-1 downto 1 => '0') & din_i;
            elsif rise_i = '1' then
                rx_sh <= rx_sh(WIDTH-2 downto 0) & din_i;
            end if;
        end if;
    end process rx_proc;

    dout_o     <= tx_sh(WIDTH-1) and send_reg;
    busy_o     <= busy_reg;
    tx_pop_o   <= '1' when (stop_i = '1' and tx_chain_i = '1') or
                           (rise_i = '1' and send_reg = '1' and (bit_cnt = 0 or bit_cnt = WIDTH)) else '0';
    tx_open_o  <= not busy_reg or (send_reg and not tx_end);
    tx_end_o   <= tx_end;
    rx_data_o  <= rx_sh;
    rx_bits_o  <= std_logic_vector(bit_cnt);
    rx_last_o  <= stop_i;
    rx_valid_o <= stop_i or word_end;

end architecture rtl;
