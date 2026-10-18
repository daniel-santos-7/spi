----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI control (shift strobes for the master or the slave role)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity spi_ctrl is
    generic (
        SCK_DIV : positive := 1
    );
    port (
        clk_i        : in  std_logic;
        rst_i        : in  std_logic;
        cs_n_i       : in  std_logic;  -- synchronised CS# (spi_sync): bus busy while low
        sclk_i       : in  std_logic;  -- synchronised SCK (spi_sync), followed by the slave
        tx_valid_i   : in  std_logic;  -- the TX buffer holds a word
        tx_role_i    : in  std_logic;  -- of the master (start a frame) or a slave reply
        done_i       : in  std_logic;
        role_o       : out std_logic;  -- 1 during an own master frame, to spi_trx
        sclk_o       : out std_logic;
        sclk_oe      : out std_logic;
        cs_n_o       : out std_logic;
        cs_n_oe      : out std_logic;
        mosi_oe      : out std_logic;
        miso_oe      : out std_logic;
        start_o      : out std_logic;
        m_stop_o     : out std_logic;  -- master frame ends (last SCK fall)
        s_stop_o     : out std_logic;  -- slave frame ends (CS# back high)
        sample_o     : out std_logic;
        shift_o      : out std_logic;
        load_o       : out std_logic;  -- master word from the TX buffer into the shift register
        arm_o        : out std_logic;  -- slave reply from the TX buffer into the shift register
        tx_ready_o   : out std_logic   -- the TX buffer word is used (load or arm)
    );
end entity spi_ctrl;

architecture rtl of spi_ctrl is

    type state_t is (IDLE_BUSY, IDLE_FREE, S_SCK_LO, S_SCK_HI, M_SCK_LO, M_SCK_HI, M_END);

    -- bits needed to hold n (at least 1)
    function bits_for(n : natural) return positive is
        variable r : positive := 1;
    begin
        while 2**r <= n loop
            r := r + 1;
        end loop;
        return r;
    end function bits_for;

    -- the SCK divider counts 0 to SCK_DIV-1
    constant CNT_W : positive := bits_for(SCK_DIV-1);

    signal state_reg    : state_t;
    signal cnt_reg      : unsigned(CNT_W-1 downto 0);
    signal sclk_reg     : std_logic;
    signal cs_n_reg     : std_logic;
    signal m_drv_en_reg : std_logic;
    signal s_drv_en_reg : std_logic;
    signal cnt_en_reg   : std_logic;
    signal cnt_end      : std_logic;

    signal m_start      : std_logic;
    signal m_stop       : std_logic;
    signal m_rise       : std_logic;
    signal m_fall       : std_logic;
    signal s_start      : std_logic;
    signal s_stop       : std_logic;
    signal s_rise       : std_logic;
    signal s_fall       : std_logic;
    signal s_arm        : std_logic;

begin

    cnt_end <= '1' when cnt_reg = SCK_DIV-1 else '0';

    fsm_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                state_reg    <= IDLE_BUSY;  -- as spi_sync: busy until CS# is seen high
                sclk_reg     <= '0';
                cs_n_reg     <= '1';
                cnt_en_reg   <= '0';
                m_drv_en_reg <= '0';
                s_drv_en_reg <= '0';
            else
                case state_reg is
                    when IDLE_BUSY =>
                        if cs_n_i = '1' then
                            state_reg <= IDLE_FREE;
                        end if;
                    when IDLE_FREE =>
                        -- the slave goes first: a master word waits in the
                        -- TX buffer until the bus is free again
                        if cs_n_i = '0' then
                            -- start from the SCK level seen now, so an SCK
                            -- already high gives no rise
                            if sclk_i = '1' then
                                state_reg <= S_SCK_HI;
                            else
                                state_reg <= S_SCK_LO;
                            end if;
                            s_drv_en_reg <= '1';
                        elsif tx_valid_i = '1' and tx_role_i = '1' then
                            state_reg    <= M_SCK_LO;
                            cs_n_reg     <= '0';
                            cnt_en_reg   <= '1';
                            m_drv_en_reg <= '1';
                        end if;
                    -- the slave follows the synchronised SCK level; CS# high
                    -- ends the frame first, so SCK edges with CS# high are ignored
                    when S_SCK_LO =>
                        if cs_n_i = '1' then
                            state_reg    <= IDLE_FREE;
                            s_drv_en_reg <= '0';
                        elsif sclk_i = '1' then
                            state_reg <= S_SCK_HI;
                        end if;
                    when S_SCK_HI =>
                        if cs_n_i = '1' then
                            state_reg    <= IDLE_FREE;
                            s_drv_en_reg <= '0';
                        elsif sclk_i = '0' then
                            state_reg <= S_SCK_LO;
                        end if;
                    when M_SCK_LO =>
                        if cnt_end = '1' then
                            state_reg <= M_SCK_HI;
                            sclk_reg  <= '1';
                        end if;
                    when M_SCK_HI =>
                        if cnt_end = '1' then
                            sclk_reg <= '0';
                            if done_i = '1' then
                                state_reg  <= M_END;
                                cs_n_reg   <= '1';
                                cnt_en_reg <= '0';
                            else
                                state_reg <= M_SCK_LO;
                            end if;
                        end if;
                    when M_END =>
                        -- one cycle driving CS# high, then release it: by
                        -- IDLE_BUSY our own CS# fall is already through spi_sync
                        -- (2 or 3 cycles), so the CS# high it waits for is ours
                        state_reg    <= IDLE_BUSY;
                        m_drv_en_reg <= '0';
                end case;
            end if;
        end if;
    end process fsm_proc;

    cnt_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                cnt_reg <= (others => '0');
            elsif cnt_en_reg = '1' then
                if cnt_end = '1' then
                    cnt_reg <= (others => '0');
                else
                    cnt_reg <= cnt_reg + 1;
                end if;
            end if;
        end if;
    end process cnt_proc;

    -- master strobes, qualified by state
    m_start <= '1' when state_reg = IDLE_FREE and cs_n_i  = '1' and tx_valid_i = '1' and tx_role_i = '1' else '0';
    m_stop  <= '1' when state_reg = M_SCK_HI  and cnt_end = '1' and done_i     = '1' else '0';
    m_rise  <= '1' when state_reg = M_SCK_LO  and cnt_end = '1' else '0';
    m_fall  <= '1' when state_reg = M_SCK_HI  and cnt_end = '1' else '0';

    -- slave strobes, qualified by state the same way
    s_start <= '1' when state_reg = IDLE_FREE and cs_n_i = '0' else '0';
    s_stop  <= '1' when (state_reg = S_SCK_LO or state_reg = S_SCK_HI) and cs_n_i = '1' else '0';
    s_rise  <= '1' when state_reg = S_SCK_LO  and cs_n_i = '0' and sclk_i = '1' else '0';
    s_fall  <= '1' when state_reg = S_SCK_HI  and cs_n_i = '0' and sclk_i = '0' else '0';
    -- a slave frame takes the reply, if the TX buffer holds one (a master
    -- word stays there); with none the shift register sends the zeros the
    -- last stop left
    s_arm   <= s_start and tx_valid_i and not tx_role_i;

    role_o       <= m_drv_en_reg;
    sclk_o       <= sclk_reg;
    sclk_oe      <= m_drv_en_reg;
    cs_n_o       <= cs_n_reg;
    cs_n_oe      <= m_drv_en_reg;
    mosi_oe      <= m_drv_en_reg;
    miso_oe      <= s_drv_en_reg;  -- exactly in S_SCK_LO and S_SCK_HI
    start_o      <= m_start or s_start;
    m_stop_o     <= m_stop;
    s_stop_o     <= s_stop;
    sample_o     <= m_rise or s_rise;  -- mode 0: sample on SCK rise
    shift_o      <= m_fall or s_fall;  -- and shift on SCK fall
    load_o       <= m_start;
    arm_o        <= s_arm;
    tx_ready_o   <= m_start or s_arm;

end architecture rtl;
