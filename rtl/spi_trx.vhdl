----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI transceiver (TX and RX shift registers, bit count)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.spi_pkg.all;

entity spi_trx is
    generic (
        WIDTH    : positive := DEF_WIDTH;
        CNT_BITS : positive := DEF_CNT_BITS
    );
    port (
        clk_i     : in  std_logic;
        rst_i     : in  std_logic;
        start_i   : in  std_logic;
        stop_i    : in  std_logic;
        sample_i  : in  std_logic;
        shift_i   : in  std_logic;
        role_i    : in  std_logic;
        miso_i    : in  std_logic;
        mosi_i    : in  std_logic;
        tx_data_i : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i : in  std_logic_vector(CNT_BITS-1 downto 0);
        mosi_o    : out std_logic;
        miso_o    : out std_logic;
        done_o    : out std_logic;
        rx_data_o : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_trx;

architecture rtl of spi_trx is

    signal bit_cnt_reg : unsigned(CNT_BITS-1 downto 0);
    signal rx_sh_reg   : std_logic_vector(WIDTH-1 downto 0);
    signal tx_sh_reg   : std_logic_vector(WIDTH-1 downto 0);
    signal tx_bits_reg : std_logic_vector(CNT_BITS-1 downto 0);
    signal din         : std_logic;
    signal cnt_full    : std_logic;
    signal cnt_len     : std_logic;

begin

    assert WIDTH >= 2 report "SPI transceiver: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI transceiver: CNT_BITS too small to count WIDTH." severity failure;

    din      <= miso_i when role_i = '1' else mosi_i;
    cnt_full <= '1' when bit_cnt_reg = WIDTH else '0';
    cnt_len  <= '1' when bit_cnt_reg = unsigned(tx_bits_reg) else '0';

    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                tx_sh_reg   <= (others => '0');
                tx_bits_reg <= (others => '0');
            elsif start_i = '1' then
                tx_sh_reg   <= tx_data_i;
                tx_bits_reg <= tx_bits_i;
            elsif shift_i = '1' then
                tx_sh_reg <= tx_sh_reg(WIDTH-2 downto 0) & '0';
            end if;
        end if;
    end process tx_proc;

    rx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                bit_cnt_reg <= (others => '0');
                rx_sh_reg   <= (others => '0');
            elsif stop_i = '1' then
                bit_cnt_reg <= (others => '0');
                rx_sh_reg   <= (others => '0');
            elsif sample_i = '1' and cnt_full = '0' then
                bit_cnt_reg <= bit_cnt_reg + 1;
                rx_sh_reg   <= rx_sh_reg(WIDTH-2 downto 0) & din;
            end if;
        end if;
    end process rx_proc;

    mosi_o    <= tx_sh_reg(WIDTH-1);
    miso_o    <= tx_sh_reg(WIDTH-1);
    done_o    <= cnt_len or cnt_full;
    rx_data_o <= rx_sh_reg;
    rx_bits_o <= std_logic_vector(bit_cnt_reg);

end architecture rtl;
