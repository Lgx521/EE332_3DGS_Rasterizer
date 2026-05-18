----------------------------------------------------------------------------------
-- framebuffer.vhd
-- Double-buffered framebuffer for 320x240 @ 12-bit RGB
-- True dual-port BRAM inferred
-- Port A: render engine read/write (sys_clk domain)
-- Port B: VGA controller read-only (pix_clk domain)
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity framebuffer is
    Port (
        -- Port A: Render engine (read/write)
        clk_a     : in  STD_LOGIC;
        we_a      : in  STD_LOGIC;
        addr_a    : in  STD_LOGIC_VECTOR(16 downto 0); -- 0..76799
        din_a     : in  STD_LOGIC_VECTOR(11 downto 0); -- 12-bit RGB
        dout_a    : out STD_LOGIC_VECTOR(11 downto 0);

        -- Port B: VGA display (read-only)
        clk_b     : in  STD_LOGIC;
        addr_b    : in  STD_LOGIC_VECTOR(16 downto 0);
        dout_b    : out STD_LOGIC_VECTOR(11 downto 0);

        -- Double buffer control
        swap      : in  STD_LOGIC;  -- pulse to swap buffers
        clk_swap  : in  STD_LOGIC   -- clock domain for swap signal
    );
end framebuffer;

architecture Behavioral of framebuffer is

    -- 320*240 = 76800 pixels per buffer, 2 buffers = 153600 total
    constant FB_SIZE : integer := 76800;
    constant RAM_SIZE : integer := 153600;

    -- Single unified RAM - allows proper Block RAM inference
    type ram_type is array (0 to RAM_SIZE - 1) of std_logic_vector(11 downto 0);
    signal ram : ram_type := (others => (others => '0'));

    -- Xilinx attribute to force Block RAM inference
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";

    -- Buffer select: '0' = render to [0..76799], display [76800..153599]
    --                '1' = render to [76800..153599], display [0..76799]
    signal render_sel : std_logic := '0';

    -- Full addresses with buffer offset
    signal full_addr_a : integer range 0 to RAM_SIZE - 1;
    signal full_addr_b : integer range 0 to RAM_SIZE - 1;

begin

    -- Address computation: render_sel selects which half each port uses
    -- Port A (render): render_sel='0' -> buf0 (offset 0), render_sel='1' -> buf1 (offset 76800)
    -- Port B (display): render_sel='0' -> buf1 (offset 76800), render_sel='1' -> buf0 (offset 0)
    process(addr_a, addr_b, render_sel)
        variable a_base : integer;
        variable b_base : integer;
        variable a_off  : integer;
        variable b_off  : integer;
    begin
        a_off := to_integer(unsigned(addr_a));
        b_off := to_integer(unsigned(addr_b));
        if a_off >= FB_SIZE then a_off := 0; end if;
        if b_off >= FB_SIZE then b_off := 0; end if;

        if render_sel = '0' then
            a_base := 0;
            b_base := FB_SIZE;
        else
            a_base := FB_SIZE;
            b_base := 0;
        end if;

        full_addr_a <= a_base + a_off;
        full_addr_b <= b_base + b_off;
    end process;

    -- Swap control
    process(clk_swap)
    begin
        if rising_edge(clk_swap) then
            if swap = '1' then
                render_sel <= not render_sel;
            end if;
        end if;
    end process;

    -- Port A: render engine read/write (true dual-port BRAM pattern)
    process(clk_a)
    begin
        if rising_edge(clk_a) then
            if we_a = '1' then
                ram(full_addr_a) <= din_a;
            end if;
            dout_a <= ram(full_addr_a);
        end if;
    end process;

    -- Port B: VGA display read-only
    process(clk_b)
    begin
        if rising_edge(clk_b) then
            dout_b <= ram(full_addr_b);
        end if;
    end process;

end Behavioral;
