----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI port testbench (two ports on one bus, master <-> slave)
-- 2026
----------------------------------------------------------------------
--
-- Two spi_port instances, A and B, share one set of pads modelled as
-- resolved signals with pull resistors (CS# up, SCK/MOSI/MISO down).
-- There is no role input: a port is a master for a frame its client
-- starts on m_tx_* while the bus is free, and a slave for a frame whose
-- CS# fall it sees first. Its slave reply goes in on s_tx_*, and the
-- words it receives come out of one buffer, on m_rx_* or s_rx_* by the
-- role it had.
-- Phase 0 has A as the master of every frame and B as the slave; phase
-- 1 has the roles the other way round; phase 2 picks the master at
-- random frame by frame. In one phase 2 frame the next frame is offered
-- on the other port while the current one is still running: that port
-- is the slave of the current frame, must hold m_tx_ready low until it
-- is over and then start its own frame. In another, the master client
-- leaves its word unread (m_rx_valid high) while the same port is the slave of
-- the next frame: both roles share one receive buffer, so the held word
-- must stay and the slave word must be dropped.
-- Every frame is one word of random data from the master, answered by
-- a random reply word from the slave, with a random tx_bits: mostly 1
-- to WIDTH bits, sometimes 0 or more than WIDTH, which must give WIDTH
-- bits. The master client sometimes starts the next frame as soon as
-- the last one is reported, otherwise it waits a random gap. The slave
-- client writes the reply of a frame once the previous frame in which
-- the same port was a slave has been reported, so a reply often waits
-- through a master frame of its own port and must survive it.
--
-- Phase 3 drives the pins from a software host, both ports slaves, with frames of any length (empty, shorter, equal and
-- longer than WIDTH). Each frame must be reported as one word: the
-- first WIDTH bits, with a count of WIDTH for a longer frame. The host
-- writes one reply word per frame, so any bit after the WIDTH-th must
-- be 0. One host frame, after a shorter one, goes out with no reply
-- written (underrun) and must send zeros, not the reply of the shorter
-- frame; the reply written before the empty frame must go out in the
-- next one; a reply written in the very cycle a frame starts must go
-- out in that frame; a reply offered during a frame must not be taken
-- (s_tx_ready stays low while CS# is low, also after the reset in the
-- middle of a frame, and high between frames).
-- Both slaves get the same reply, so MISO
-- contention is not checked in this phase (every reply bit the host
-- samples is). The host reads every word as it is reported, except
-- once: it leaves one word unread, sends the next frame and checks
-- that the buffer still holds the old word, so the new one is dropped.
-- In one host frame both ports are reset halfway through: with CS#
-- still low after the reset they must stay out of that frame (no word
-- reported, MISO not driven during the reset nor after it) and take the
-- next one normally; A is offered a master frame after the reset and
-- must not take it while CS# is low.
--
-- Checks: every word and bit count the slave reports, the
-- words and bit counts the master receives (the first tx_bits bits of
-- the reply), that no port reports a word it should not (no master word
-- in phase 3, nothing left over at the end of a phase, such as its own
-- master frame seen as a slave frame), CS# high time, SCK phases, MOSI/MISO changing
-- only while SCK is low, frame length, pad contention, that SCK/CS#/MOSI
-- are driven by the master of the frame only and released between
-- frames, MISO by the slave only, and that m_tx_ready and s_tx_ready
-- are low while CS# is low (look before driving, up to the synchroniser
-- latency): no write of either kind is taken during a frame.
--
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity tb_spi_port is
    generic (
        SCK_DIV     : positive := 5;
        NUM_FRAMES  : positive := 60;
        HOST_FRAMES : positive := 30;
        SEED        : positive := 1;
        WIDTH       : positive := 32;
        CNT_BITS    : positive := 7
    );
end entity tb_spi_port;

architecture sim of tb_spi_port is

    constant CLK_PERIOD : time    := 10 ns;
    constant CS_MIN     : integer := 2;
    constant MISO_LAT   : integer := 3;
    constant EARLY_F    : integer := 3;
    constant HOLD_F     : integer := 6;
    constant B2B_HI     : integer := 4;
    constant FRAME_CYC  : integer := 2 * WIDTH * SCK_DIV;
    constant HOST_MAX   : integer := 2 * WIDTH + 8;
    constant HOST_URUN  : integer := 5;
    constant HOST_HOLD  : integer := 6;
    constant HOST_TIE   : integer := 8;
    constant HOST_RST   : integer := 10;
    constant MAX_FRAMES : integer := 3 * NUM_FRAMES + 1;
    constant MAX_WORDS  : integer := MAX_FRAMES;
    constant HOST_WORDS : integer := 4 * HOST_FRAMES;
    constant TIMEOUT    : time    := (3 * NUM_FRAMES * (FRAME_CYC + 100) + HOST_FRAMES * (2 * HOST_MAX * SCK_DIV + 100)) * CLK_PERIOD;

    subtype word_t is std_logic_vector(WIDTH-1 downto 0);
    subtype bits_t is std_logic_vector(CNT_BITS-1 downto 0);
    type word_arr_t is array (natural range <>) of word_t;
    type nat_arr_t is array (natural range <>) of natural;
    type int_arr_t is array (natural range <>) of integer;

    function hex(v : std_logic_vector) return string is
        constant DIGITS : string(1 to 16) := "0123456789ABCDEF";
        constant N      : natural := (v'length + 3) / 4;
        variable p      : std_logic_vector(4*N-1 downto 0) := (others => '0');
        variable r      : string(1 to N);
    begin
        if is_x(v) then
            return "X";
        end if;
        p(v'length-1 downto 0) := v;
        for i in 0 to N-1 loop
            r(i+1) := DIGITS(to_integer(unsigned(p(4*N-1-4*i downto 4*N-4-4*i))) + 1);
        end loop;
        return r;
    end function hex;

    function top_bits(v : std_logic_vector; k : natural) return std_logic_vector is
        variable r : std_logic_vector(v'length-1 downto 0) := (others => '0');
        variable t : std_logic_vector(v'length-1 downto 0);
    begin
        t := v;
        for i in 0 to k-1 loop
            r(k-1-i) := t(v'length-1-i);
        end loop;
        return r;
    end function top_bits;

    -- clock, reset, control
    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal sim_done  : std_logic := '0';
    signal chk_on    : std_logic := '0';
    signal swap      : std_logic := '0';

    -- software host (phase 2)
    signal host_en   : std_logic := '0';
    signal host_sclk : std_logic := '0';
    signal host_cs_n : std_logic := '1';
    signal host_mosi : std_logic := '0';
    signal host_resp : word_t    := (others => '0');
    signal host_wr   : std_logic := '0';
    signal host_rd   : std_logic := '0';
    signal host_mreq : std_logic := '0';
    signal hw_n      : natural   := 0;
    signal hw_data   : word_arr_t(0 to HOST_WORDS-1);
    signal hw_bits   : nat_arr_t(0 to HOST_WORDS-1);

    -- pads and their logic levels
    signal sclk_pad : std_logic;
    signal cs_n_pad : std_logic;
    signal mosi_pad : std_logic;
    signal miso_pad : std_logic;
    signal sclk_in  : std_logic;
    signal cs_n_in  : std_logic;
    signal mosi_in  : std_logic;
    signal miso_in  : std_logic;

    -- port A
    signal a_sclk_o     : std_logic;
    signal a_sclk_oe    : std_logic;
    signal a_cs_n_o     : std_logic;
    signal a_cs_n_oe    : std_logic;
    signal a_mosi_o     : std_logic;
    signal a_mosi_oe    : std_logic;
    signal a_miso_o     : std_logic;
    signal a_miso_oe    : std_logic;
    signal a_m_tx_valid : std_logic;
    signal a_m_tx_ready : std_logic;
    signal a_m_tx_data  : word_t;
    signal a_m_tx_bits  : bits_t;
    signal a_s_tx_valid : std_logic;
    signal a_s_tx_ready : std_logic;
    signal a_s_tx_data  : word_t;
    signal a_m_rx_ready : std_logic;
    signal a_s_rx_ready : std_logic;
    signal a_m_rx_data  : word_t;
    signal a_m_rx_valid : std_logic;
    signal a_s_rx_data  : word_t;
    signal a_s_rx_bits  : bits_t;
    signal a_s_rx_valid : std_logic;

    -- port B
    signal b_sclk_o     : std_logic;
    signal b_sclk_oe    : std_logic;
    signal b_cs_n_o     : std_logic;
    signal b_cs_n_oe    : std_logic;
    signal b_mosi_o     : std_logic;
    signal b_mosi_oe    : std_logic;
    signal b_miso_o     : std_logic;
    signal b_miso_oe    : std_logic;
    signal b_m_tx_valid : std_logic;
    signal b_m_tx_ready : std_logic;
    signal b_m_tx_data  : word_t;
    signal b_m_tx_bits  : bits_t;
    signal b_s_tx_valid : std_logic;
    signal b_s_tx_ready : std_logic;
    signal b_s_tx_data  : word_t;
    signal b_m_rx_ready : std_logic;
    signal b_s_rx_ready : std_logic;
    signal b_m_rx_data  : word_t;
    signal b_m_rx_valid : std_logic;
    signal b_s_rx_data  : word_t;
    signal b_s_rx_bits  : bits_t;
    signal b_s_rx_valid : std_logic;

    -- master client (the master port of the current frame, by swap)
    signal m_tx_valid : std_logic := '0';
    signal m_tx_ready : std_logic;
    signal m_tx_data  : word_t    := (others => '0');
    signal m_tx_bits  : bits_t    := (others => '0');
    signal m_rx_data  : word_t;
    signal m_rx_valid : std_logic;
    signal m_hold     : std_logic := '0';  -- master client leaves its word unread
    signal hold_w     : integer   := -10;  -- the word held, and the one queued behind it
    signal s_skip     : std_logic := '0';  -- the slave word after the held one was dropped
    signal m_rx_wcnt  : natural := 0;
    signal m_rx_fcnt  : natural := 0;

    -- slave client (the slave port of each word, by plan_swap)
    signal s_tx_valid : std_logic;
    signal s_tx_ready : std_logic;
    signal s_tx_data  : word_t;
    signal s_tx_cnt   : natural := 0;
    signal s_rx_data  : word_t;
    signal s_rx_bits  : std_logic_vector(CNT_BITS-1 downto 0);
    signal s_rx_valid : std_logic;
    signal s_rx_wcnt  : natural := 0;
    signal s_rx_fcnt  : natural := 0;
    signal s_wdone    : natural;
    signal n_surv     : natural := 0;
    signal n_wait     : natural := 0;

    -- test plan, per word and per frame
    signal plan_wcnt  : natural := 0;
    signal plan_mtx   : word_arr_t(0 to MAX_WORDS-1);
    signal plan_sresp : word_arr_t(0 to MAX_WORDS-1)        := (others => (others => '0'));
    signal plan_wbits : nat_arr_t(0 to MAX_WORDS-1)         := (others => WIDTH);
    signal plan_wlast : std_logic_vector(0 to MAX_WORDS-1)  := (others => '0');
    signal plan_wfrm  : nat_arr_t(0 to MAX_WORDS-1)         := (others => 0);
    signal plan_flen  : nat_arr_t(0 to MAX_FRAMES-1)        := (others => WIDTH);
    signal plan_b2b   : std_logic_vector(0 to MAX_FRAMES-1) := (others => '0');
    signal plan_swap  : std_logic_vector(0 to MAX_WORDS)    := (others => '0');  -- 1 = B master, A slave
    signal plan_sprev : int_arr_t(0 to MAX_WORDS)           := (others => -1);   -- slave port's previous word

begin

    assert SCK_DIV >= 5 report "TB: the slave needs SCK <= clk/10, so SCK_DIV must be at least 5." severity failure;

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0' else '0';

    ------------------------------------------------------------------
    -- DUTs and bus
    ------------------------------------------------------------------

    tb_spi_port_a: entity work.spi_port generic map (
        SCK_DIV  => SCK_DIV,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i        => clk,
        rst_i        => rst,
        sclk_i       => sclk_in,
        cs_n_i       => cs_n_in,
        mosi_i       => mosi_in,
        miso_i       => miso_in,
        m_tx_valid_i => a_m_tx_valid,
        m_tx_data_i  => a_m_tx_data,
        m_tx_bits_i  => a_m_tx_bits,
        s_tx_valid_i => a_s_tx_valid,
        s_tx_data_i  => a_s_tx_data,
        m_rx_ready_i => a_m_rx_ready,
        s_rx_ready_i => a_s_rx_ready,
        sclk_o       => a_sclk_o,
        sclk_oe      => a_sclk_oe,
        cs_n_o       => a_cs_n_o,
        cs_n_oe      => a_cs_n_oe,
        mosi_o       => a_mosi_o,
        mosi_oe      => a_mosi_oe,
        miso_o       => a_miso_o,
        miso_oe      => a_miso_oe,
        m_tx_ready_o => a_m_tx_ready,
        s_tx_ready_o => a_s_tx_ready,
        m_rx_data_o  => a_m_rx_data,
        m_rx_valid_o => a_m_rx_valid,
        s_rx_data_o  => a_s_rx_data,
        s_rx_bits_o  => a_s_rx_bits,
        s_rx_valid_o => a_s_rx_valid
    );

    tb_spi_port_b: entity work.spi_port generic map (
        SCK_DIV  => SCK_DIV,
        WIDTH    => WIDTH,
        CNT_BITS => CNT_BITS
    ) port map (
        clk_i        => clk,
        rst_i        => rst,
        sclk_i       => sclk_in,
        cs_n_i       => cs_n_in,
        mosi_i       => mosi_in,
        miso_i       => miso_in,
        m_tx_valid_i => b_m_tx_valid,
        m_tx_data_i  => b_m_tx_data,
        m_tx_bits_i  => b_m_tx_bits,
        s_tx_valid_i => b_s_tx_valid,
        s_tx_data_i  => b_s_tx_data,
        m_rx_ready_i => b_m_rx_ready,
        s_rx_ready_i => b_s_rx_ready,
        sclk_o       => b_sclk_o,
        sclk_oe      => b_sclk_oe,
        cs_n_o       => b_cs_n_o,
        cs_n_oe      => b_cs_n_oe,
        mosi_o       => b_mosi_o,
        mosi_oe      => b_mosi_oe,
        miso_o       => b_miso_o,
        miso_oe      => b_miso_oe,
        m_tx_ready_o => b_m_tx_ready,
        s_tx_ready_o => b_s_tx_ready,
        m_rx_data_o  => b_m_rx_data,
        m_rx_valid_o => b_m_rx_valid,
        s_rx_data_o  => b_s_rx_data,
        s_rx_bits_o  => b_s_rx_bits,
        s_rx_valid_o => b_s_rx_valid
    );

    sclk_pad <= a_sclk_o when a_sclk_oe = '1' else 'Z';
    sclk_pad <= b_sclk_o when b_sclk_oe = '1' else 'Z';
    sclk_pad <= host_sclk when host_en = '1' else 'Z';
    sclk_pad <= 'L';
    cs_n_pad <= a_cs_n_o when a_cs_n_oe = '1' else 'Z';
    cs_n_pad <= b_cs_n_o when b_cs_n_oe = '1' else 'Z';
    cs_n_pad <= host_cs_n when host_en = '1' else 'Z';
    cs_n_pad <= 'H';
    mosi_pad <= a_mosi_o when a_mosi_oe = '1' else 'Z';
    mosi_pad <= b_mosi_o when b_mosi_oe = '1' else 'Z';
    mosi_pad <= host_mosi when host_en = '1' else 'Z';
    mosi_pad <= 'L';
    miso_pad <= a_miso_o when a_miso_oe = '1' else 'Z';
    miso_pad <= b_miso_o when b_miso_oe = '1' else 'Z';
    miso_pad <= 'L';

    sclk_in <= to_x01(sclk_pad);
    cs_n_in <= to_x01(cs_n_pad);
    mosi_in <= to_x01(mosi_pad);
    miso_in <= to_x01(miso_pad);

    -- The master client writes to the master port of the current frame
    -- (swap), the slave client to the slave port of the word it is on
    -- (plan_swap); in phase 3 the host writes the reply of both ports and
    -- A also gets host_mreq as a master request.
    a_m_tx_valid <= host_mreq when host_en = '1' else m_tx_valid when swap = '0' else '0';
    b_m_tx_valid <= '0'       when host_en = '1' else m_tx_valid when swap = '1' else '0';
    a_m_tx_data  <= m_tx_data;
    b_m_tx_data  <= m_tx_data;
    a_m_tx_bits  <= m_tx_bits;
    b_m_tx_bits  <= m_tx_bits;
    m_tx_ready   <= a_m_tx_ready when swap = '0' else b_m_tx_ready;

    a_s_tx_valid <= host_wr   when host_en = '1' else s_tx_valid when plan_swap(s_tx_cnt) = '1' else '0';
    b_s_tx_valid <= host_wr   when host_en = '1' else s_tx_valid when plan_swap(s_tx_cnt) = '0' else '0';
    a_s_tx_data  <= host_resp when host_en = '1' else s_tx_data;
    b_s_tx_data  <= host_resp when host_en = '1' else s_tx_data;
    s_tx_ready   <= a_s_tx_ready when plan_swap(s_tx_cnt) = '1' else b_s_tx_ready;

    -- Each checker reads the RX channel of its role on the port planned
    -- for its next word; the other port's channel waits (ready low) until
    -- its turn, and the master client can hold its channel (m_hold). In
    -- phase 3 the host reads the slave channels and no master word may come.
    a_m_rx_ready <= '1' when host_en = '1' else '1' when plan_swap(m_rx_wcnt) = '0' and m_hold = '0' else '0';
    b_m_rx_ready <= '1' when host_en = '1' else '1' when plan_swap(m_rx_wcnt) = '1' and m_hold = '0' else '0';
    a_s_rx_ready <= host_rd when host_en = '1' else '1' when plan_swap(s_rx_wcnt) = '1' else '0';
    b_s_rx_ready <= host_rd when host_en = '1' else '1' when plan_swap(s_rx_wcnt) = '0' else '0';
    m_rx_data    <= a_m_rx_data when plan_swap(m_rx_wcnt) = '0' else b_m_rx_data;
    m_rx_valid   <= (a_m_rx_valid and a_m_rx_ready) or (b_m_rx_valid and b_m_rx_ready);
    s_rx_data    <= a_s_rx_data when plan_swap(s_rx_wcnt) = '1' else b_s_rx_data;
    s_rx_bits    <= a_s_rx_bits when plan_swap(s_rx_wcnt) = '1' else b_s_rx_bits;
    s_rx_valid   <= (a_s_rx_valid and a_s_rx_ready) or (b_s_rx_valid and b_s_rx_ready);

    ------------------------------------------------------------------
    -- Stimulus: test plan, master client and software host
    ------------------------------------------------------------------

    stim_proc: process
        variable s1      : positive := SEED;
        variable s2      : positive := 7919;
        variable r       : real;
        variable v       : integer;
        variable g       : integer;
        variable n       : integer;
        variable k       : integer;
        variable frame   : natural := 0;
        variable word    : natural := 0;
        variable b2b     : boolean := false;
        variable mtx     : word_t;
        variable resp    : word_t;
        variable prev    : word_t := (others => '0');
        variable prev_n  : integer := -1;
        variable hbits   : std_logic_vector(HOST_MAX-1 downto 0);
        variable hrx     : std_logic_vector(HOST_MAX-1 downto 0);
        variable exp_rx  : word_t;
        variable len     : integer;
        variable ew      : integer;
        variable eb      : integer;
        variable hw0     : natural;
        variable sv_rx   : word_t;
        variable sv_k    : integer := 0;
        variable n_b2b   : natural := 0;
        variable n_mshrt : natural := 0;
        variable n_mclip : natural := 0;
        variable n_empty : natural := 0;
        variable n_short : natural := 0;
        variable n_exact : natural := 0;
        variable n_long  : natural := 0;
        variable n_swp   : natural := 0;
        variable early   : boolean := false;
        variable held    : boolean := false;
        variable hx      : std_logic;
        variable sw      : std_logic;
        variable sw_p    : std_logic := '0';  -- master of the last frame planned
        variable nx_mtx  : word_t;
        variable nx_len  : integer;
        variable nx_sw   : std_logic;
        variable last_a  : integer := -1;
        variable last_b  : integer := -1;

        procedure rnd(lo, hi : in integer; x : out integer) is
            variable t : integer;
        begin
            uniform(s1, s2, r);
            t := lo + integer(trunc(r * real(hi - lo + 1)));
            if t > hi then
                t := hi;
            end if;
            x := t;
        end procedure rnd;

        procedure rnd_bits(x : out std_logic_vector) is
            variable t : std_logic_vector(x'range);
            variable b : integer;
        begin
            for i in t'range loop
                rnd(0, 1, b);
                if b = 1 then
                    t(i) := '1';
                else
                    t(i) := '0';
                end if;
            end loop;
            x := t;
        end procedure rnd_bits;

        -- plan frame g of phase ph as word w (one word per frame, so
        -- also frame w): draws its data, reply, length and master
        procedure plan_frame(ph, g, w : in integer; mtx_o : out word_t; len_o : out integer; sw_o : out std_logic) is
            variable m  : word_t;
            variable rs : word_t;
            variable l  : integer;
            variable kk : integer;
            variable x  : integer;
            variable sv : std_logic;
        begin
            rnd_bits(m);
            rnd_bits(rs);
            rnd(0, 7, x);
            if x = 0 then
                l := 0;
            elsif x = 1 and WIDTH < 2**CNT_BITS-1 then
                rnd(WIDTH+1, 2**CNT_BITS-1, l);
            elsif x <= 3 then
                l := WIDTH;
            else
                rnd(1, WIDTH, l);
            end if;
            if ph = 2 and g = EARLY_F then
                l := WIDTH;
            end if;
            if l = 0 or l > WIDTH then
                kk      := WIDTH;
                n_mclip := n_mclip + 1;
            else
                kk := l;
            end if;
            if kk < WIDTH then
                n_mshrt := n_mshrt + 1;
            end if;

            -- master: A in phase 0, B in phase 1, at random in phase 2
            -- (the other port after an early offer or a held word)
            if ph = 0 then
                sv := '0';
            elsif ph = 1 then
                sv := '1';
            elsif (g = EARLY_F + 1 or g = HOLD_F + 1) and g > 1 then
                sv := not sw_p;
            else
                rnd(0, 1, x);
                if x = 1 then
                    sv := '1';
                else
                    sv := '0';
                end if;
            end if;
            if w > 0 and sv /= sw_p then
                n_swp := n_swp + 1;
            end if;
            sw_p := sv;
            plan_swap(w) <= sv;
            if sv = '1' then
                plan_sprev(w) <= last_a;
                last_a        := w;
            else
                plan_sprev(w) <= last_b;
                last_b        := w;
            end if;

            plan_wlast(w) <= '1';
            plan_mtx(w)   <= m;
            plan_sresp(w) <= rs;
            plan_wbits(w) <= kk;
            plan_wfrm(w)  <= w;
            plan_flen(w)  <= kk;
            mtx_o := m;
            len_o := l;
            sw_o  := sv;
        end procedure plan_frame;

        procedure cycles(c : in natural) is
        begin
            for i in 1 to c loop
                wait until rising_edge(clk);
            end loop;
        end procedure cycles;
    begin
        rst <= '1';
        cycles(10);
        rst <= '0';
        cycles(10);
        chk_on <= '1';

        for ph in 0 to 2 loop
            if ph > 0 then
                -- between phases nobody drives the bus and both ports are
                -- ready for either role
                assert sclk_pad = 'L' and cs_n_pad = 'H' and mosi_pad = 'L' and miso_pad = 'L'
                    report "TB: pins still driven between frames" severity error;
                assert a_m_tx_ready = '1' and b_m_tx_ready = '1' and a_s_tx_ready = '1' and b_s_tx_ready = '1'
                    report "TB: ports not ready with the bus idle" severity error;
                if ph = 1 then
                    report "TB: roles swapped, A is slave and B is master" severity note;
                else
                    report "TB: master picked at random frame by frame" severity note;
                end if;
            end if;

            -- frames are planned one ahead, so the reply of the next frame
            -- can go in before this one starts and wait through it
            b2b := false;
            plan_frame(ph, 1, word, nx_mtx, nx_len, nx_sw);
            for f in 1 to NUM_FRAMES loop
                mtx := nx_mtx;
                len := nx_len;
                sw  := nx_sw;
                if f < NUM_FRAMES then
                    plan_frame(ph, f + 1, word + 1, nx_mtx, nx_len, nx_sw);
                    plan_wcnt <= word + 2;
                else
                    plan_wcnt <= word + 1;
                end if;
                if b2b or early then
                    plan_b2b(frame) <= '1';
                end if;

                if ph = 2 and f = HOLD_F and f < NUM_FRAMES then
                    m_hold <= '1';
                    hold_w <= word;
                end if;
                swap       <= sw;
                m_tx_data  <= mtx;
                m_tx_bits  <= std_logic_vector(to_unsigned(len, CNT_BITS));
                m_tx_valid <= '1';
                loop
                    wait until rising_edge(clk);
                    exit when m_tx_ready = '1';
                end loop;
                m_tx_valid <= '0';
                frame := frame + 1;
                word  := word + 1;

                if ph = 2 and f = EARLY_F and f < NUM_FRAMES then
                    -- offer the next frame on the other port in the middle
                    -- of this one: it must wait for the bus
                    early := true;
                    cycles(4 * SCK_DIV);
                elsif ph = 2 and f = HOLD_F and f < NUM_FRAMES then
                    -- leave this master word unread; the port is the slave
                    -- of the next frame, whose word must be dropped (one
                    -- buffer for both roles)
                    held := true;
                    hx   := sw;
                    b2b  := false;
                    loop
                        wait until rising_edge(clk);
                        exit when (hx = '0' and a_m_rx_valid = '1') or (hx = '1' and b_m_rx_valid = '1');
                    end loop;
                else
                    if held then
                        -- the master of this frame buffers its word at the
                        -- CS# rise; the held port's slave stop comes up to
                        -- MISO_LAT cycles later
                        loop
                            wait until rising_edge(clk);
                            exit when (hx = '0' and b_m_rx_valid = '1') or (hx = '1' and a_m_rx_valid = '1');
                        end loop;
                        cycles(MISO_LAT + 2);
                        assert (hx = '0' and a_m_rx_valid = '1' and a_s_rx_valid = '0') or
                               (hx = '1' and b_m_rx_valid = '1' and b_s_rx_valid = '0')
                            report "TB: held master word lost or slave word not dropped behind it" severity error;
                        assert s_rx_wcnt = word - 1
                            report "TB: slave checker not at the dropped word" severity error;
                        s_skip <= '1';
                        m_hold <= '0';
                        cycles(1);
                        s_skip <= '0';
                    end if;
                    early := false;
                    loop
                        wait until rising_edge(clk);
                        exit when m_rx_fcnt = frame;
                    end loop;
                    rnd(0, 3, v);
                    -- not after the held word: the client writes once it is read
                    b2b  := v = 0 and f < NUM_FRAMES and not held;
                    held := false;
                    if b2b then
                        n_b2b := n_b2b + 1;
                    else
                        rnd(1, 30, g);
                        cycles(g);
                    end if;
                end if;
            end loop;

            loop
                wait until rising_edge(clk);
                exit when m_rx_wcnt = word and s_rx_wcnt = word;
            end loop;
            cycles(10);
            assert a_m_rx_valid = '0' and b_m_rx_valid = '0' and a_s_rx_valid = '0' and b_s_rx_valid = '0'
                report "TB: a port holds a word no frame asked for" severity error;
        end loop;

        -- phase 3: both ports slaves, frames of any length from the host
        host_rd <= '1';
        host_en <= '1';
        cycles(10);
        report "TB: both ports are slaves, the software host drives the pins" severity note;

        for f in 1 to HOST_FRAMES loop
            if f = 1 then
                n := 0;
            elsif f = 2 then
                n := WIDTH;
            elsif f = 3 then
                n := HOST_MAX;
            elsif f = 4 then
                n := WIDTH / 2;
            elsif f = HOST_HOLD then
                rnd(1, WIDTH, n);
            elsif f = HOST_RST or f = HOST_TIE then
                n := WIDTH;
            else
                rnd(1, HOST_MAX, n);
            end if;
            rnd_bits(hbits);
            assert a_s_tx_ready = '1' and b_s_tx_ready = '1' and a_m_tx_ready = '1' and b_m_tx_ready = '1'
                report "host: frame " & integer'image(f) & " ports not ready between frames" severity error;
            if f = HOST_URUN then
                resp := (others => '0');
            elsif f = HOST_TIE then
                rnd_bits(resp);  -- written below, as the frame starts
            elsif prev_n = 0 then
                resp := prev;
            else
                rnd_bits(resp);
                host_resp <= resp;
                host_wr   <= '1';
                cycles(1);
                host_wr   <= '0';
                cycles(1);
            end if;
            prev   := resp;
            prev_n := n;
            if f = HOST_HOLD then
                host_rd <= '0';
            end if;
            cycles(2);
            hw0 := hw_n;

            host_cs_n <= '0';
            if f = HOST_TIE then
                -- write the reply on the edge that starts the frame: high
                -- s_tx_ready on that edge, low on the next one (the ports
                -- see CS# low 3 edges after host_cs_n falls); it must go out
                -- in this frame
                cycles(2);
                host_resp <= resp;
                host_wr   <= '1';
                cycles(1);
                assert a_s_tx_ready = '1' and b_s_tx_ready = '1'
                    report "host: frame " & integer'image(f) & " ready dropped before the frame start" severity error;
                host_wr   <= '0';
                cycles(1);
                assert a_s_tx_ready = '0' and b_s_tx_ready = '0'
                    report "host: frame " & integer'image(f) & " reply not taken on the frame start edge" severity error;
                cycles(SCK_DIV - 4);
            else
                cycles(SCK_DIV);
            end if;
            for i in 0 to n-1 loop
                if f = HOST_RST and i = n / 2 then
                    -- reset both ports in the middle of the frame
                    rst <= '1';
                    cycles(2);
                    assert a_miso_oe = '0' and b_miso_oe = '0'
                        report "host: frame " & integer'image(f) & " MISO driven during reset" severity error;
                    cycles(1);
                    rst       <= '0';
                    host_mreq <= '1';  -- A must not start while CS# is low
                end if;
                host_mosi <= hbits(HOST_MAX-1-i);
                if f = 2 and i = 1 then
                    host_resp <= not resp;
                    host_wr   <= '1';
                end if;
                cycles(SCK_DIV);
                host_sclk <= '1';
                hrx(HOST_MAX-1-i) := miso_in;
                assert a_s_tx_ready = '0' and b_s_tx_ready = '0'
                    report "host: frame " & integer'image(f) & " s_tx_ready high during the frame" severity error;
                assert a_m_tx_ready = '0' and b_m_tx_ready = '0'
                    report "host: frame " & integer'image(f) & " m_tx_ready high during the frame" severity error;
                assert (a_miso_oe = '0' and b_miso_oe = '0') or not (f = HOST_RST and i >= n / 2)
                    report "host: frame " & integer'image(f) & " MISO driven after a reset in the frame" severity error;
                cycles(SCK_DIV);
                host_sclk <= '0';
            end loop;
            cycles(SCK_DIV);
            host_wr   <= '0';
            host_mreq <= '0';
            host_cs_n <= '1';
            host_mosi <= '0';

            for i in 0 to n-1 loop
                if f = HOST_RST then
                    null;  -- the reset clears the reply
                elsif i < WIDTH then
                    assert hrx(HOST_MAX-1-i) = resp(WIDTH-1-i)
                        report "host: frame " & integer'image(f) & " reply bit " & integer'image(i) & " wrong" severity error;
                else
                    assert hrx(HOST_MAX-1-i) = '0'
                        report "host: frame " & integer'image(f) & " reply bit " & integer'image(i) & " is not 0" severity error;
                end if;
            end loop;
            cycles(10);

            ew := 1;
            if f = HOST_RST then
                -- the ports came out of reset with CS# low: they must stay
                -- out of this frame and report nothing
                ew := 0;
            end if;
            if f = HOST_HOLD then
                exp_rx := (others => '0');
                for i in 0 to n-1 loop
                    exp_rx(n-1-i) := hbits(HOST_MAX-1-i);
                end loop;
                assert hw_n = hw0 and a_s_rx_valid = '1' and to_integer(unsigned(a_s_rx_bits)) = n and a_s_rx_data = exp_rx
                    report "host: frame " & integer'image(f) & " not held in the buffer" severity error;
                sv_rx := exp_rx;
                sv_k  := n;
            elsif f = HOST_HOLD + 1 then
                assert hw_n = hw0 and a_s_rx_valid = '1' and to_integer(unsigned(a_s_rx_bits)) = sv_k and a_s_rx_data = sv_rx
                    report "host: frame " & integer'image(f) & " overwrote an unread word" severity error;
                host_rd <= '1';
                cycles(3);
                assert hw_n = hw0 + 1 and hw_data(hw0) = sv_rx and hw_bits(hw0) = sv_k
                    report "host: frame " & integer'image(f) & " held word not read back alone" severity error;
            else
                assert hw_n = hw0 + ew
                    report "host: frame " & integer'image(f) & " (" & integer'image(n) & " bits) reported " &
                           integer'image(hw_n - hw0) & " words, expected " & integer'image(ew) severity error;
                for w in 0 to ew-1 loop
                    if n = 0 then
                        eb := 0;
                    elsif n - w*WIDTH < WIDTH then
                        eb := n - w*WIDTH;
                    else
                        eb := WIDTH;
                    end if;
                    exp_rx := (others => '0');
                    for i in 0 to eb-1 loop
                        exp_rx(eb-1-i) := hbits(HOST_MAX-1-w*WIDTH-i);
                    end loop;
                    if hw0 + w < hw_n then
                        assert hw_bits(hw0+w) = eb
                            report "host: frame " & integer'image(f) & " word " & integer'image(w) & " reported " &
                                   integer'image(hw_bits(hw0+w)) & " bits, expected " & integer'image(eb) severity error;
                        assert hw_data(hw0+w) = exp_rx
                            report "host: frame " & integer'image(f) & " word " & integer'image(w) & " is " & hex(hw_data(hw0+w)) &
                                   ", expected " & hex(exp_rx) severity error;
                    end if;
                end loop;
            end if;

            if n = 0 then
                n_empty := n_empty + 1;
            elsif n < WIDTH then
                n_short := n_short + 1;
            elsif n = WIDTH then
                n_exact := n_exact + 1;
            else
                n_long := n_long + 1;
            end if;
            rnd(10, 30, g);
            cycles(g);
        end loop;
        host_en <= '0';

        assert n_b2b > 0 and n_mshrt > 0 and n_mclip > 0 and n_swp > 0 and n_surv > 0 and n_wait > 0
            report "TB: coverage hole (back-to-back, shorter, clipped, role change, reply through a master frame " &
                   "or master waiting for the bus)" severity error;
        report "TB: PASS - " & integer'image(frame) & " master frames, " & integer'image(word) & " words of " &
               integer'image(WIDTH) & " bits (" & integer'image(n_b2b) & " back-to-back, " &
               integer'image(n_mshrt) & " shorter, " & integer'image(n_mclip) &
               " with tx_bits 0 or over WIDTH, " & integer'image(n_swp) & " role changes, " &
               integer'image(n_surv) & " replies kept through an own master frame), " & integer'image(HOST_FRAMES) & " host frames (" &
               integer'image(n_empty) & " empty, " & integer'image(n_short) & " shorter, " &
               integer'image(n_exact) & " exact, " & integer'image(n_long) & " longer)"
            severity note;
        sim_done <= '1';
        wait;
    end process stim_proc;

    ------------------------------------------------------------------
    -- Slave client: writes each reply once, checks each received word
    ------------------------------------------------------------------

    -- a reply may go in once its port's previous slave word is reported
    s_wdone    <= s_rx_wcnt + 1 when s_rx_valid = '1' else s_rx_wcnt;
    s_tx_data  <= plan_sresp(s_tx_cnt);
    s_tx_valid <= '1' when host_en = '0' and s_tx_cnt < plan_wcnt and s_wdone > plan_sprev(s_tx_cnt) else '0';

    slave_tx_proc: process
        variable a_pend : boolean := false;  -- a reply waits for the port's next slave frame
        variable b_pend : boolean := false;
        variable a_oe_p : std_logic := '0';
        variable b_oe_p : std_logic := '0';
    begin
        wait until rising_edge(clk);
        -- coverage: the port starts a master frame with a reply pending
        if (a_pend and a_cs_n_oe = '1' and a_oe_p = '0') or (b_pend and b_cs_n_oe = '1' and b_oe_p = '0') then
            n_surv <= n_surv + 1;
        end if;
        if a_miso_oe = '1' then
            a_pend := false;
        end if;
        if b_miso_oe = '1' then
            b_pend := false;
        end if;
        if s_tx_valid = '1' and s_tx_ready = '1' then
            s_tx_cnt <= s_tx_cnt + 1;
            if plan_swap(s_tx_cnt) = '1' then
                a_pend := true;
            else
                b_pend := true;
            end if;
        end if;
        a_oe_p := a_cs_n_oe;
        b_oe_p := b_cs_n_oe;
    end process slave_tx_proc;

    slave_rx_proc: process
        variable i : natural := 0;
    begin
        wait until rising_edge(clk);
        if s_skip = '1' then
            -- dropped behind the held master word: nothing to check
            i := i + 1;
            s_rx_wcnt <= i;
            s_rx_fcnt <= s_rx_fcnt + 1;
        elsif chk_on = '1' and host_en = '0' and s_rx_valid = '1' then
            assert i < plan_wcnt
                report "slave: unexpected word " & hex(s_rx_data) severity error;
            assert to_integer(unsigned(s_rx_bits)) = plan_wbits(i)
                report "slave: word " & integer'image(i) & " reported " & integer'image(to_integer(unsigned(s_rx_bits))) &
                       " bits, expected " & integer'image(plan_wbits(i)) severity error;
            assert s_rx_data = top_bits(plan_mtx(i), plan_wbits(i))
                report "slave: word " & integer'image(i) & " is " & hex(s_rx_data) &
                       ", expected " & hex(top_bits(plan_mtx(i), plan_wbits(i))) severity error;
            if plan_wlast(i) = '1' then
                s_rx_fcnt <= s_rx_fcnt + 1;
            end if;
            i := i + 1;
            s_rx_wcnt <= i;
        end if;
    end process slave_rx_proc;

    -- a port reports a master word only for its own master frames: none
    -- in phase 3, where both ports are slaves of the host
    rx_role_proc: process
    begin
        wait until rising_edge(clk);
        if chk_on = '1' and host_en = '1' then
            assert a_m_rx_valid = '0' and b_m_rx_valid = '0'
                report "TB: a slave port reported a word on its master channel" severity error;
        end if;
    end process rx_role_proc;

    ------------------------------------------------------------------
    -- Host receive recorder (phase 2): both slaves must report alike
    ------------------------------------------------------------------

    host_rx_proc: process
    begin
        wait until rising_edge(clk);
        if host_en = '1' and host_rd = '1' and a_s_rx_valid = '1' then
            assert b_s_rx_valid = '1' and b_s_rx_data = a_s_rx_data and b_s_rx_bits = a_s_rx_bits
                report "host: the two slaves report different words" severity error;
            hw_data(hw_n) <= a_s_rx_data;
            hw_bits(hw_n) <= to_integer(unsigned(a_s_rx_bits));
            hw_n          <= hw_n + 1;
        end if;
    end process host_rx_proc;

    ------------------------------------------------------------------
    -- Master receive checker
    ------------------------------------------------------------------

    master_rx_proc: process
        variable j  : natural := 0;
        variable hi : natural := 0;
    begin
        wait until rising_edge(clk);
        if chk_on = '1' and host_en = '0' and m_rx_valid = '1' then
            assert j < plan_wcnt
                report "master: unexpected word " & hex(m_rx_data) severity error;
            assert m_rx_data = top_bits(plan_sresp(j), plan_wbits(j))
                report "master: word " & integer'image(j) & " is " & hex(m_rx_data) &
                       ", expected " & hex(top_bits(plan_sresp(j), plan_wbits(j))) severity error;
            if plan_wlast(j) = '1' then
                assert (cs_n_in = '1' and hi = 0) or j = hold_w or j = hold_w + 1
                    report "master: last word " & integer'image(j) & " not reported in the first cycle with CS# high" severity error;
                m_rx_fcnt <= m_rx_fcnt + 1;
            else
                assert cs_n_in = '0'
                    report "master: word " & integer'image(j) & " reported with CS# high but not last" severity error;
            end if;
            j := j + 1;
            m_rx_wcnt <= j;
        end if;
        if cs_n_in = '1' then
            hi := hi + 1;
        else
            hi := 0;
        end if;
    end process master_rx_proc;

    ------------------------------------------------------------------
    -- Bus monitor: protocol, timing, contention, role isolation
    ------------------------------------------------------------------

    bus_mon_proc: process
        variable sclk_p : std_logic;
        variable cs_p   : std_logic;
        variable mosi_p : std_logic;
        variable miso_p : std_logic;
        variable phase  : natural := 0;
        variable lo_cnt : natural := 0;
        variable hi_cnt : natural := CS_MIN;
        variable frame  : natural := 0;
        variable cs_run : natural := 0;
        variable a_mr_p : std_logic := '0';
        variable b_mr_p : std_logic := '0';
        variable a_sr_p : std_logic := '0';
        variable b_sr_p : std_logic := '0';
        variable a_mt_p : boolean   := false;
        variable b_mt_p : boolean   := false;
        variable a_st_p : boolean   := false;
        variable b_st_p : boolean   := false;
    begin
        wait until rising_edge(clk) and chk_on = '1';
        sclk_p := sclk_in;
        cs_p   := cs_n_in;
        mosi_p := mosi_in;
        miso_p := miso_in;
        loop
            wait until rising_edge(clk);

            assert sclk_in /= 'X' and cs_n_in /= 'X' and mosi_in /= 'X' and (miso_in /= 'X' or host_en = '1')
                report "bus: contention on a pad" severity error;

            -- cycles since CS# last changed: the slave follows CS# through
            -- the synchroniser, so MISO is taken and released MISO_LAT late
            -- (3 here, where the synchroniser always takes 2 cycles; 3 to 4
            -- in hardware)
            if cs_n_in /= cs_p then
                cs_run := 0;
            else
                cs_run := cs_run + 1;
            end if;

            if cs_n_in = '1' then
                assert sclk_in = '0'
                    report "bus: SCK high while CS# is high" severity error;
                assert miso_pad = 'L' or cs_run < MISO_LAT
                    report "bus: MISO driven while CS# is high" severity error;
            end if;

            if host_en = '0' then
                -- frame boundaries
                if cs_p = '1' and cs_n_in = '0' then
                    assert sclk_in = '0'
                        report "bus: SCK high when CS# falls" severity error;
                    assert hi_cnt >= CS_MIN
                        report "bus: CS# high for " & integer'image(hi_cnt) & " cycles before frame " &
                               integer'image(frame) severity error;
                    if plan_b2b(frame) = '1' then
                        -- the same for either master: both reach IDLE_FREE
                        -- in the cycle their synchronised CS# is back high
                        assert hi_cnt = B2B_HI
                            report "bus: back-to-back frame " & integer'image(frame) & " waited " &
                                   integer'image(hi_cnt) & " cycles with CS# high" severity error;
                    end if;
                    lo_cnt := 0;
                    phase  := 0;
                elsif cs_p = '0' and cs_n_in = '1' then
                    assert lo_cnt = 2 * plan_flen(frame) * SCK_DIV
                        report "bus: frame " & integer'image(frame) & " had CS# low for " & integer'image(lo_cnt) &
                               " cycles, expected " & integer'image(2 * plan_flen(frame) * SCK_DIV) severity error;
                    if sclk_p = '1' then
                        assert phase = SCK_DIV
                            report "bus: last SCK high phase lasted " & integer'image(phase) & " cycles" severity error;
                    end if;
                    frame  := frame + 1;
                    hi_cnt := 0;
                end if;
                if cs_n_in = '0' then
                    lo_cnt := lo_cnt + 1;
                else
                    hi_cnt := hi_cnt + 1;
                end if;

                -- SCK phases inside a frame
                if cs_n_in = '0' then
                    if sclk_in /= sclk_p and phase > 0 then
                        assert phase = SCK_DIV
                            report "bus: SCK phase lasted " & integer'image(phase) & " cycles" severity error;
                        phase := 1;
                    else
                        phase := phase + 1;
                    end if;
                end if;
            end if;

            -- data changes only while SCK is low
            if cs_n_in = '0' and cs_p = '0' then
                assert mosi_in = mosi_p or sclk_in = '0'
                    report "bus: MOSI changed while SCK is high" severity error;
                assert miso_in = miso_p or sclk_in = '0'
                    report "bus: MISO changed while SCK is high" severity error;
            end if;

            -- SCK, CS# and MOSI are driven together, by the master only;
            -- MISO by the slave while CS# is low
            assert a_sclk_oe = a_cs_n_oe and a_mosi_oe = a_cs_n_oe and
                   b_sclk_oe = b_cs_n_oe and b_mosi_oe = b_cs_n_oe
                report "bus: SCK, CS# and MOSI enables differ" severity error;
            -- one master at a time, never also driving MISO
            assert not (a_cs_n_oe = '1' and b_cs_n_oe = '1')
                report "bus: both ports drive the master pins" severity error;
            assert not (a_cs_n_oe = '1' and a_miso_oe = '1') and not (b_cs_n_oe = '1' and b_miso_oe = '1')
                report "bus: a port drives the master pins and MISO" severity error;
            if host_en = '1' then
                assert a_cs_n_oe = '0' and b_cs_n_oe = '0'
                    report "bus: a port drives the master pins during a host frame" severity error;
            elsif cs_n_in = '0' then
                -- the planned master drives SCK, CS# and MOSI, the slave MISO
                assert (plan_swap(frame) = '0' and a_cs_n_oe = '1' and b_cs_n_oe = '0') or
                       (plan_swap(frame) = '1' and b_cs_n_oe = '1' and a_cs_n_oe = '0')
                    report "bus: frame " & integer'image(frame) & " not driven by its master alone" severity error;
                assert (sclk_pad = '0' or sclk_pad = '1') and (cs_n_pad = '0' or cs_n_pad = '1') and
                       (mosi_pad = '0' or mosi_pad = '1')
                    report "bus: master pins not driven" severity error;
                if cs_run >= MISO_LAT then
                    assert miso_pad = '0' or miso_pad = '1'
                        report "bus: MISO not driven by the slave while CS# is low" severity error;
                end if;
            elsif cs_run > MISO_LAT then
                assert a_cs_n_oe = '0' and b_cs_n_oe = '0'
                    report "bus: master pins not released between frames" severity error;
            end if;

            -- look before driving: no master write is taken while CS# is
            -- low, up to the synchroniser latency
            assert (a_m_tx_ready = '0' and b_m_tx_ready = '0') or cs_n_in = '1' or cs_run < MISO_LAT
                report "bus: m_tx_ready high while CS# is low" severity error;
            -- no reply is taken while a frame runs, master or slave
            assert (a_s_tx_ready = '0' and b_s_tx_ready = '0') or cs_n_in = '1' or cs_run < MISO_LAT
                report "bus: s_tx_ready high while CS# is low" severity error;
            -- a ready only drops when a write is taken or the bus gets busy
            if rst = '0' and cs_n_in = '1' then
                assert (a_mr_p = '0' or a_m_tx_ready = '1' or a_mt_p) and (b_mr_p = '0' or b_m_tx_ready = '1' or b_mt_p)
                    report "bus: m_tx_ready dropped with no write and the bus idle" severity error;
                assert (a_sr_p = '0' or a_s_tx_ready = '1' or a_st_p or a_mt_p) and (b_sr_p = '0' or b_s_tx_ready = '1' or b_st_p or b_mt_p)
                    report "bus: s_tx_ready dropped with the bus idle" severity error;
            end if;
            a_mr_p := a_m_tx_ready;
            b_mr_p := b_m_tx_ready;
            a_sr_p := a_s_tx_ready;
            b_sr_p := b_s_tx_ready;
            a_mt_p := a_m_tx_valid = '1' and a_m_tx_ready = '1';
            b_mt_p := b_m_tx_valid = '1' and b_m_tx_ready = '1';
            a_st_p := a_s_tx_valid = '1' and a_s_tx_ready = '1';
            b_st_p := b_s_tx_valid = '1' and b_s_tx_ready = '1';

            if ((a_m_tx_valid = '1' and a_m_tx_ready = '0' and a_cs_n_oe = '0') or
                (b_m_tx_valid = '1' and b_m_tx_ready = '0' and b_cs_n_oe = '0')) and cs_n_in = '0' then
                n_wait <= n_wait + 1;
            end if;

            sclk_p := sclk_in;
            cs_p   := cs_n_in;
            mosi_p := mosi_in;
            miso_p := miso_in;
        end loop;
    end process bus_mon_proc;

    watchdog_proc: process
    begin
        wait until sim_done = '1' for TIMEOUT;
        assert sim_done = '1' report "TB: timeout" severity failure;
        wait;
    end process watchdog_proc;

end architecture sim;
