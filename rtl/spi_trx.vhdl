----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI transceiver (TX word buffer and shift register, RX shift register, bit count)
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
        flush_i    : in  std_logic;  -- role change: drop the TX word held

        role_i     : in  std_logic;  -- 1 = master: sample miso_i
        miso_i     : in  std_logic;  -- not synchronised: master only, timed by our own SCK
        mosi_i     : in  std_logic;  -- synchronised to clk_i (spi_sync does it)

        tx_valid_i : in  std_logic;  -- client write
        tx_data_i  : in  std_logic_vector(WIDTH-1 downto 0);
        tx_bits_i  : in  std_logic_vector(CNT_BITS-1 downto 0);

        mosi_o     : out std_logic;
        miso_o     : out std_logic;
        done_o     : out std_logic;
        tx_ready_o : out std_logic;
        tx_valid_o : out std_logic;  -- a TX word is held, to spi_ctrl
        rx_valid_o : out std_logic;  -- word received (stop_i), to the receive buffer
        rx_data_o  : out std_logic_vector(WIDTH-1 downto 0);
        rx_bits_o  : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_trx;

architecture rtl of spi_trx is

    signal bit_cnt_reg  : unsigned(CNT_BITS-1 downto 0);
    signal rx_sh_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal tx_valid_reg : std_logic;
    signal tx_sh_reg    : std_logic_vector(WIDTH-1 downto 0);
    signal tx_bits_reg  : std_logic_vector(CNT_BITS-1 downto 0);
    signal busy_reg     : std_logic;
    signal din          : std_logic;
    signal done         : std_logic;
    signal tx_used      : std_logic;
    signal tx_clr       : std_logic;

begin

    assert WIDTH >= 2 report "SPI transceiver: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI transceiver: CNT_BITS too small to count WIDTH." severity failure;

    din  <= miso_i when role_i = '1' else mosi_i;
    -- tx_bits_reg is the master word's, held during its frame
    done <= '1' when bit_cnt_reg = unsigned(tx_bits_reg) or bit_cnt_reg = WIDTH else '0';

    -- the TX word is used once a frame has sent it (an empty slave frame
    -- sent nothing: the reply stays), and dropped by a flush unless a
    -- write comes in that cycle (a flush only comes between frames, and a
    -- stop never takes a write)
    tx_used <= '1' when stop_i = '1' and tx_valid_reg = '1' and bit_cnt_reg /= 0 else '0';
    tx_clr  <= tx_used or (flush_i and not tx_valid_i);

    -- 1 during a frame: no TX word is taken then
    busy_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or stop_i = '1' then
                busy_reg <= '0';
            elsif start_i = '1' then
                busy_reg <= '1';
            end if;
        end if;
    end process busy_proc;

    -- One-word TX buffer, ready/valid, which is also the TX shift
    -- register: the bit sent is its MSB. A word is shifted up as it is
    -- sent, zeros coming in, and cleared once used or flushed, so with no
    -- word the buffer is all zeros and a frame without a reply sends
    -- zeros. A word taken in a flush state belongs to the new role and
    -- stays. The clear comes first, so it maps onto the flip-flops'
    -- synchronous reset.
    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or tx_clr = '1' then
                tx_valid_reg <= '0';
                tx_sh_reg    <= (others => '0');
                tx_bits_reg  <= (others => '0');
            elsif busy_reg = '0' and tx_valid_i = '1' then
                -- a write between frames replaces the word held: the last
                -- write wins
                tx_valid_reg <= '1';
                tx_sh_reg    <= tx_data_i;
                tx_bits_reg  <= tx_bits_i;
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

    mosi_o     <= tx_sh_reg(WIDTH-1);
    miso_o     <= tx_sh_reg(WIDTH-1);
    done_o     <= done;
    tx_ready_o <= not busy_reg;
    tx_valid_o <= tx_valid_reg;
    rx_valid_o <= stop_i;
    rx_data_o  <= rx_sh_reg;
    rx_bits_o  <= std_logic_vector(bit_cnt_reg);

end architecture rtl;
