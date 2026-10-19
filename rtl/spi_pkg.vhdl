----------------------------------------------------------------------
-- Leaf project
-- developed by: Daniel Santos
-- module: SPI package (shared function and generic defaults)
-- 2026
----------------------------------------------------------------------

package spi_pkg is

    -- bits needed to hold n (at least 1)
    function bits_for(n : natural) return positive;

    -- generic defaults
    constant DEF_DIV_BITS : positive := 8;
    constant DEF_WIDTH    : positive := 32;
    constant DEF_CNT_BITS : positive;  -- holds 0 to DEF_WIDTH

end package spi_pkg;

package body spi_pkg is

    function bits_for(n : natural) return positive is
        variable r : positive := 1;
    begin
        while 2**r <= n loop
            r := r + 1;
        end loop;
        return r;
    end function bits_for;

    constant DEF_CNT_BITS : positive := bits_for(DEF_WIDTH);

end package body spi_pkg;
