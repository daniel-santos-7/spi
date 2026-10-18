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
        send_i   : in  std_logic;  -- frame start that sends data_i (the TX buffer word)

        role_i   : in  std_logic;  -- 1 = master: sample miso_i
        miso_i   : in  std_logic;  -- not synchronised: master only, timed by our own SCK
        mosi_i   : in  std_logic;  -- synchronised to clk_i (spi_sync does it)

        data_i   : in  std_logic_vector(WIDTH-1 downto 0);     -- TX buffer word, held while it is sent
        bits_i   : in  std_logic_vector(CNT_BITS-1 downto 0);

        mosi_o   : out std_logic;
        miso_o   : out std_logic;
        done_o   : out std_logic;
        ready_o  : out std_logic;  -- the frame that sent the TX buffer word ends, to the TX buffer
        valid_o  : out std_logic;  -- word received (stop_i), to the receive buffer
        data_o   : out std_logic_vector(WIDTH-1 downto 0);
        bits_o   : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_trx;

architecture rtl of spi_trx is

    signal bit_cnt_reg : unsigned(CNT_BITS-1 downto 0);
    signal rx_sh_reg   : std_logic_vector(WIDTH-1 downto 0);
    signal dout_reg    : std_logic;
    signal tx_en_reg   : std_logic;
    signal din         : std_logic;
    signal done        : std_logic;

begin

    assert WIDTH >= 2 report "SPI transceiver: WIDTH must be at least 2." severity failure;
    assert 2**CNT_BITS > WIDTH report "SPI transceiver: CNT_BITS too small to count WIDTH." severity failure;

    din  <= miso_i when role_i = '1' else mosi_i;
    -- bits_i is the master word's, held in the TX buffer during its frame
    done <= '1' when bit_cnt_reg = unsigned(bits_i) or bit_cnt_reg = WIDTH else '0';

    -- The bit sent comes straight from the TX buffer word, MSB first: the
    -- first one as the frame starts, the next on each shift (after
    -- bit_cnt_reg samples), zeros after WIDTH bits. A frame that sends no
    -- word (a slave frame with no reply) sends zeros, and leaves alone a
    -- word written meanwhile.
    tx_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or stop_i = '1' then
                dout_reg  <= '0';
                tx_en_reg <= '0';
            elsif send_i = '1' then
                dout_reg  <= data_i(WIDTH-1);
                tx_en_reg <= '1';
            elsif shift_i = '1' then
                if tx_en_reg = '1' and bit_cnt_reg /= WIDTH then
                    dout_reg <= data_i(WIDTH-1-to_integer(bit_cnt_reg));
                else
                    dout_reg <= '0';
                end if;
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

    mosi_o  <= dout_reg;
    miso_o  <= dout_reg;
    done_o  <= done;
    -- the word is used once a frame has sent it (an empty slave frame
    -- sent nothing: the reply stays)
    ready_o <= '1' when stop_i = '1' and tx_en_reg = '1' and bit_cnt_reg /= 0 else '0';
    valid_o <= stop_i;
    data_o  <= rx_sh_reg;
    bits_o  <= std_logic_vector(bit_cnt_reg);

end architecture rtl;
