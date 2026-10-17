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
        m_stop_i : in  std_logic;  -- master frame ends
        s_stop_i : in  std_logic;  -- slave frame ends
        sample_i : in  std_logic;
        shift_i  : in  std_logic;
        load_i   : in  std_logic;  -- master word (data_i, bits_i) into tx_sh_reg
        put_i    : in  std_logic;  -- slave reply (reply_i) into reply_reg
        arm_i    : in  std_logic;  -- slave frame start: reply_reg into tx_sh_reg

        role_i   : in  std_logic;  -- 1 = master: sample miso_i
        miso_i   : in  std_logic;  -- not synchronised: master only, timed by our own SCK
        mosi_i   : in  std_logic;  -- synchronised to clk_i (spi_sync does it)

        data_i   : in  std_logic_vector(WIDTH-1 downto 0);
        bits_i   : in  std_logic_vector(CNT_BITS-1 downto 0);
        reply_i  : in  std_logic_vector(WIDTH-1 downto 0);

        mosi_o   : out std_logic;
        miso_o   : out std_logic;
        done_o   : out std_logic;
        m_load_o : out std_logic;  -- word received as master (m_stop_i), to the receive buffer
        s_load_o : out std_logic;  -- word received as slave (s_stop_i), to the receive buffer
        data_o   : out std_logic_vector(WIDTH-1 downto 0);
        bits_o   : out std_logic_vector(CNT_BITS-1 downto 0)
    );
end entity spi_trx;

architecture rtl of spi_trx is

    signal bit_cnt_reg : unsigned(CNT_BITS-1 downto 0);
    signal wlen_reg    : unsigned(CNT_BITS-1 downto 0);

    signal tx_sh_reg   : std_logic_vector(WIDTH-1 downto 0);
    signal reply_reg   : std_logic_vector(WIDTH-1 downto 0);
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
            if rst_i = '1' then
                tx_sh_reg <= (others => '0');
                wlen_reg  <= (others => '0');
            elsif load_i = '1' then
                tx_sh_reg <= data_i;
                wlen_reg  <= unsigned(bits_i);
            elsif arm_i = '1' and put_i = '1' then
                tx_sh_reg <= reply_i;  -- reply written as the frame starts
            elsif arm_i = '1' then
                tx_sh_reg <= reply_reg;
            elsif shift_i = '1' then
                tx_sh_reg <= tx_sh_reg(WIDTH-2 downto 0) & '0';
            end if;
        end if;
    end process tx_proc;

    -- a slave frame with bits uses the reply up: underrun sends zeros
    reply_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or (s_stop_i = '1' and bit_cnt_reg /= 0) then
                reply_reg <= (others => '0');
            elsif put_i = '1' then
                reply_reg <= reply_i;
            end if;
        end if;
    end process reply_proc;

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
    m_load_o <= m_stop_i;
    s_load_o <= s_stop_i;
    data_o <= rx_sh_reg;
    bits_o <= std_logic_vector(bit_cnt_reg);

end architecture rtl;
