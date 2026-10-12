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
        dbg_i      : in  std_logic;  -- requested role, synchronised
        dbg_o      : out std_logic;  -- role in effect, changed only in IDLE/SLV_IDLE
        role_o     : out std_logic;
        sclk_i     : in  std_logic;  -- sclk_i and cs_n_i must already be
        cs_n_i     : in  std_logic;  -- synchronised to clk_i (spi_sync does it)
        cs_pin_i   : in  std_logic;  -- CS# pin as is, for miso_oe
        sclk_o     : out std_logic;
        sclk_oe    : out std_logic;
        cs_n_o     : out std_logic;
        cs_n_oe    : out std_logic;
        mosi_oe    : out std_logic;
        miso_oe    : out std_logic;
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

    type state_t is (IDLE, SCK_LO, SCK_HI, STOP, SLV_IDLE, SLAVE);

    signal state_reg    : state_t;
    signal cnt_reg      : natural range 0 to SCK_DIV;
    signal sclk_reg     : std_logic;
    signal cs_n_reg     : std_logic;
    signal stop_reg     : std_logic;
    signal ready_reg    : std_logic;
    signal role_reg     : std_logic;
    signal load         : std_logic;
    signal cnt_en_reg   : std_logic;
    signal cnt_end      : std_logic;

    signal sclk_dly_reg : std_logic;
    signal cs_n_dly_reg : std_logic;

    signal m_start      : std_logic;
    signal m_rise       : std_logic;
    signal m_fall       : std_logic;
    signal s_start      : std_logic;
    signal s_stop       : std_logic;
    signal s_rise       : std_logic;
    signal s_fall       : std_logic;

begin

    cnt_end <= '1' when cnt_reg = SCK_DIV-1 else '0';
    load    <= tx_valid_i and ready_reg;
    m_start <= load and not role_reg;

    fsm_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state_reg  <= IDLE;
                sclk_reg   <= '0';
                cs_n_reg   <= '1';
                cnt_en_reg <= '0';
                stop_reg   <= '0';
                ready_reg  <= '1';
                role_reg   <= '0';
            else
                case state_reg is
                    when IDLE =>
                        if m_start = '1' then
                            state_reg  <= SCK_LO;
                            cs_n_reg   <= '0';
                            cnt_en_reg <= '1';
                            ready_reg  <= '0';
                        elsif dbg_i = '1' then
                            state_reg <= SLV_IDLE;
                            role_reg  <= '1';
                        end if;
                    when SCK_LO =>
                        if cnt_end = '1' then
                            state_reg <= SCK_HI;
                            sclk_reg  <= '1';
                        end if;
                    when SCK_HI =>
                        if cnt_end = '1' then
                            sclk_reg <= '0';
                            if done_i = '1' then
                                state_reg  <= STOP;
                                cs_n_reg   <= '1';
                                cnt_en_reg <= '0';
                                stop_reg   <= '1';
                            else
                                state_reg <= SCK_LO;
                            end if;
                        end if;
                    when STOP =>
                        state_reg <= IDLE;
                        stop_reg  <= '0';
                        ready_reg <= '1';
                    when SLV_IDLE =>
                        if s_start = '1' then
                            state_reg <= SLAVE;
                            ready_reg <= '0';
                        elsif dbg_i = '0' then
                            state_reg <= IDLE;
                            role_reg  <= '0';
                        end if;
                    when SLAVE =>
                        if s_stop = '1' then
                            state_reg <= SLV_IDLE;
                            ready_reg <= '1';
                        end if;
                end case;
            end if;
        end if;
    end process fsm_proc;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                cnt_reg <= 0;
            elsif cnt_en_reg = '1' then
                if cnt_end = '1' then
                    cnt_reg <= 0;
                else
                    cnt_reg <= cnt_reg + 1;
                end if;
            end if;
        end if;
    end process cnt_proc;

    m_rise <= '1' when state_reg = SCK_LO and cnt_end = '1' else '0';
    m_fall <= '1' when state_reg = SCK_HI and cnt_end = '1' else '0';

    edge_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                sclk_dly_reg <= '0';
                cs_n_dly_reg <= '1';
            else
                sclk_dly_reg <= sclk_i;
                cs_n_dly_reg <= cs_n_i;
            end if;
        end if;
    end process edge_proc;

    s_start <= cs_n_dly_reg and not cs_n_i;
    s_stop  <= cs_n_i and not cs_n_dly_reg;
    s_rise  <= sclk_i and not sclk_dly_reg and not cs_n_i;
    s_fall  <= sclk_dly_reg and not sclk_i and not cs_n_i;

    dbg_o      <= role_reg;
    role_o     <= role_reg;
    sclk_o     <= sclk_reg;
    sclk_oe    <= not role_reg;
    cs_n_o     <= cs_n_reg;
    cs_n_oe    <= not role_reg;
    mosi_oe    <= not role_reg;
    miso_oe    <= role_reg and not cs_pin_i;
    tx_ready_o <= ready_reg;
    start_o    <= s_start when role_reg = '1' else m_start;
    stop_o     <= s_stop  when role_reg = '1' else stop_reg;
    rise_o     <= s_rise  when role_reg = '1' else m_rise;
    fall_o     <= s_fall  when role_reg = '1' else m_fall;
    load_o     <= load;

end architecture rtl;
