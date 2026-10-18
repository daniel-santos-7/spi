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
        clk_i      : in  std_logic;
        rst_i      : in  std_logic;

        start_i    : in  std_logic;
        stop_i     : in  std_logic;
        sample_i   : in  std_logic;
        shift_i    : in  std_logic;

        role_i     : in  std_logic;  -- 1 = master: sample miso_i
        miso_i     : in  std_logic;  -- not synchronised: master only, timed by our own SCK
        mosi_i     : in  std_logic;  -- synchronised to clk_i (spi_sync does it)

        tx_valid_i : in  std_logic;  -- client word, taken at start_i
        tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);

        mosi_o     : out std_logic;
        miso_o     : out std_logic;
        done_o     : out std_logic;
        tx_ready_o : out std_logic;  -- word taken (start_i), to the client
        rx_valid_o : out std_logic;  -- word received (stop_i), to the receive buffer
        rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_trx;

architecture rtl of spi_trx is

    signal bit_cnt_reg  : unsigned(CNT_BITS-1 downto 0);
    signal rx_sh_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal tx_sh_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal tx_bits_reg  : std_logic_vector(CNT_BITS-1 downto 0);
    signal din          : std_logic;
    signal done         : std_logic;

begin

    assert WIDTH >= 2 report "SPI transceiver: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI transceiver: CNT_BITS too small to count WIDTH." severity failure;

    din  <= miso_i when role_i = '1' else mosi_i;
    -- tx_bits_reg is the master word's, held during its frame
    done <= '1' when bit_cnt_reg = unsigned(tx_bits_reg) or bit_cnt_reg = WIDTH else '0';

    -- TX shift register: the client word is taken at start_i (zeros
    -- with no word, an underrun) and the bit sent is its MSB; it is
    -- shifted up as it is sent, zeros coming in, so bits after the
    -- WIDTH-th are 0. The bit count is the master word's, held during
    -- its frame.
    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                tx_sh_reg   <= (others => '0');
                tx_bits_reg <= (others => '0');
            elsif start_i = '1' then
                if tx_valid_i = '1' then
                    tx_sh_reg   <= tx_data_i;
                    tx_bits_reg <= tx_bits_i;
                else
                    tx_sh_reg   <= (others => '0');
                    tx_bits_reg <= (others => '0');
                end if;
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
            elsif start_i = '1' then
                bit_cnt_reg <= (others => '0');
                rx_sh_reg   <= (others => '0');
            elsif sample_i = '1' and bit_cnt_reg /= WIDTH then
                bit_cnt_reg <= bit_cnt_reg + 1;
                rx_sh_reg   <= rx_sh_reg(WIDTH-2 downto 0) & din;
            end if;
        end if;
    end process rx_proc;

    mosi_o     <= tx_sh_reg(WIDTH-1);
    miso_o     <= tx_sh_reg(WIDTH-1);
    done_o     <= done;
    tx_ready_o <= start_i;
    rx_valid_o <= stop_i;
    rx_data_o  <= rx_sh_reg;
    rx_bits_o  <= std_logic_vector(bit_cnt_reg);

end architecture rtl;
