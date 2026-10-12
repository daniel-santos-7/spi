----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI control (shift strobes for the master or the slave role)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_ctrl is
    generic (
        SCK_DIV : positive := 1
    );
    port (
        clk_i      : in  std_logic;
        rst_i      : in  std_logic;
        dbg_i      : in  std_logic;
        sclk_i     : in  std_logic;  -- sclk_i and cs_n_i must already be
        cs_n_i     : in  std_logic;  -- synchronised to clk_i (spi_port does it)
        sclk_o     : out std_logic;
        cs_n_o     : out std_logic;
        tx_valid_i : in  std_logic;
        tx_ready_o : out std_logic;
        done_i     : in  std_logic;
        start_o    : out std_logic;
        stop_o     : out std_logic;
        rise_o     : out std_logic;
        fall_o     : out std_logic;
        load_o     : out std_logic
    );
end entity spi_ctrl;

architecture rtl of spi_ctrl is

    type state_t is (IDLE, SCK_LO, SCK_HI, STOP);

    signal state     : state_t;
    signal cnt       : natural range 0 to SCK_DIV;
    signal sclk      : std_logic;
    signal cs_n      : std_logic;
    signal stop_reg  : std_logic;
    signal ready_reg : std_logic;
    signal load      : std_logic;
    signal start_sel : std_logic;
    signal stop_sel  : std_logic;
    signal cnt_en    : std_logic;
    signal cnt_end   : std_logic;

    signal sclk_reg  : std_logic;
    signal cs_n_reg  : std_logic;

    signal m_start   : std_logic;
    signal m_rise    : std_logic;
    signal m_fall    : std_logic;
    signal s_start   : std_logic;
    signal s_stop    : std_logic;
    signal s_rise    : std_logic;
    signal s_fall    : std_logic;

begin

    cnt_end  <= '1' when cnt = SCK_DIV-1 else '0';
    load     <= tx_valid_i and ready_reg;
    m_start  <= load and not dbg_i;

    fsm_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state    <= IDLE;
                sclk     <= '0';
                cs_n     <= '1';
                cnt_en   <= '0';
                stop_reg <= '0';
            else
                case state is
                    when IDLE =>
                        if m_start = '1' then
                            state  <= SCK_LO;
                            cs_n   <= '0';
                            cnt_en <= '1';
                        end if;
                    when SCK_LO =>
                        if cnt_end = '1' then
                            state <= SCK_HI;
                            sclk  <= '1';
                        end if;
                    when SCK_HI =>
                        if cnt_end = '1' then
                            sclk <= '0';
                            if done_i = '1' then
                                state    <= STOP;
                                cs_n     <= '1';
                                cnt_en   <= '0';
                                stop_reg <= '1';
                            else
                                state <= SCK_LO;
                            end if;
                        end if;
                    when STOP =>
                        state    <= IDLE;
                        stop_reg <= '0';
                end case;
            end if;
        end if;
    end process fsm_proc;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                cnt <= 0;
            elsif cnt_en = '1' then
                if cnt_end = '1' then
                    cnt <= 0;
                else
                    cnt <= cnt + 1;
                end if;
            end if;
        end if;
    end process cnt_proc;

    m_rise <= '1' when state = SCK_LO and cnt_end = '1' else '0';
    m_fall <= '1' when state = SCK_HI and cnt_end = '1' else '0';

    edge_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                sclk_reg <= '0';
                cs_n_reg <= '1';
            else
                sclk_reg <= sclk_i;
                cs_n_reg <= cs_n_i;
            end if;
        end if;
    end process edge_proc;

    s_start <= cs_n_reg and not cs_n_i;
    s_stop  <= cs_n_i and not cs_n_reg;
    s_rise  <= sclk_i and not sclk_reg and not cs_n_i;
    s_fall  <= sclk_reg and not sclk_i and not cs_n_i;

    start_sel <= s_start when dbg_i = '1' else m_start;
    stop_sel  <= s_stop  when dbg_i = '1' else stop_reg;

    ready_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                ready_reg <= '1';
            elsif start_sel = '1' then
                ready_reg <= '0';
            elsif stop_sel = '1' then
                ready_reg <= '1';
            end if;
        end if;
    end process ready_proc;

    sclk_o     <= sclk;
    cs_n_o     <= cs_n;
    tx_ready_o <= ready_reg;
    start_o    <= start_sel;
    stop_o     <= stop_sel;
    rise_o     <= s_rise  when dbg_i = '1' else m_rise;
    fall_o     <= s_fall  when dbg_i = '1' else m_fall;
    load_o     <= load;

end architecture rtl;
