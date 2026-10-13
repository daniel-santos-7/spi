----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI transceiver (shift registers, bit count, frame length)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity spi_trx is
    generic (
        WIDTH    : positive := 32;
        CNT_BITS : positive := 6
    );
    port (
        clk_i    : in  std_logic;
        rst_i    : in  std_logic;

        start_i  : in  std_logic;
        stop_i   : in  std_logic;
        sample_i : in  std_logic;
        shift_i  : in  std_logic;
        load_i   : in  std_logic;

        role_i   : in  std_logic;  -- 1 = master: sample miso_i
        miso_i   : in  std_logic;  -- not synchronised: master only, timed by our own SCK
        mosi_i   : in  std_logic;  -- synchronised to clk_i (spi_sync does it)

        data_i   : in  std_logic_vector(WIDTH-1 downto 0);
        bits_i   : in  std_logic_vector(CNT_BITS-1 downto 0);

        mosi_o   : out std_logic;
        miso_o   : out std_logic;
        done_o   : out std_logic;
        load_o   : out std_logic;  -- word received (stop_i), to the receive buffer
        data_o   : out std_logic_vector(WIDTH-1 downto 0);
        bits_o   : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_trx;

architecture rtl of spi_trx is

    signal bit_cnt_reg : unsigned(CNT_BITS-1 downto 0);
    signal wlen_reg    : unsigned(CNT_BITS-1 downto 0);

    signal tx_sh_reg   : std_logic_vector(WIDTH-1 downto 0);
    signal rx_sh_reg   : std_logic_vector(WIDTH-1 downto 0);
    signal din         : std_logic;
    signal dout        : std_logic;
    signal done        : std_logic;

begin

    assert WIDTH >= 2 report "SPI transceiver: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI transceiver: CNT_BITS too small to count WIDTH." severity failure;

    din  <= miso_i when role_i = '1' else mosi_i;
    dout <= tx_sh_reg(WIDTH-1);
    done <= '1' when bit_cnt_reg = wlen_reg or bit_cnt_reg = WIDTH else '0';

    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or (stop_i = '1' and bit_cnt_reg /= 0) then
                tx_sh_reg <= (others => '0');
                wlen_reg  <= (others => '0');
            elsif load_i = '1' then
                tx_sh_reg <= data_i;
                wlen_reg  <= unsigned(bits_i);
            elsif shift_i = '1' then
                tx_sh_reg <= tx_sh_reg(WIDTH-2 downto 0) & '0';
            end if;
        end if;
    end process tx_proc;

    rx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or start_i = '1' then
                bit_cnt_reg <= (others => '0');
                rx_sh_reg   <= (others => '0');
            elsif sample_i = '1' and bit_cnt_reg /= WIDTH then
                bit_cnt_reg <= bit_cnt_reg + 1;
                rx_sh_reg   <= rx_sh_reg(WIDTH-2 downto 0) & din;
            end if;
        end if;
    end process rx_proc;

    mosi_o <= dout;
    miso_o <= dout;
    done_o <= done;
    load_o <= stop_i;
    data_o <= rx_sh_reg;
    bits_o <= std_logic_vector(bit_cnt_reg);

end architecture rtl;
