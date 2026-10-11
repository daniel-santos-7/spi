----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI buffer (one word, ready/valid)
-- 2026
----------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;

entity spi_buf is
    generic (
        WIDTH : positive := 32
    );
    port (
        clk_i       : in  std_logic;
        rst_i       : in  std_logic;

        in_valid_i  : in  std_logic;
        in_data_i   : in  std_logic_vector(WIDTH-1 downto 0);

        out_ready_i : in  std_logic;
        out_valid_o : out std_logic;
        out_data_o  : out std_logic_vector(WIDTH-1 downto 0)
    );
end entity spi_buf;

architecture rtl of spi_buf is

    signal valid_reg : std_logic;
    signal data_reg  : std_logic_vector(WIDTH-1 downto 0);

begin

    buf_proc: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                valid_reg <= '0';
                data_reg  <= (others => '0');
            elsif valid_reg = '1' then
                if out_ready_i = '1' then
                    valid_reg <= in_valid_i;
                    data_reg  <= in_data_i;
                end if;
            else
                valid_reg <= in_valid_i;
                data_reg  <= in_data_i;
            end if;
        end if;
    end process buf_proc;

    out_valid_o <= valid_reg;
    out_data_o  <= data_reg;

end architecture rtl;
