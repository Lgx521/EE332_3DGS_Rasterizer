----------------------------------------------------------------------------------
-- splat_rom.vhd
-- Splat parameter ROM, initialized from .mem file
-- Each splat is 64 bits:
--   [63:54] center_x (10 bit, 0..319)
--   [53:45] center_y (9 bit,  0..239)
--   [44:38] radius   (7 bit,  0..127)
--   [37:34] R        (4 bit)
--   [33:30] G        (4 bit)
--   [29:26] B        (4 bit)
--   [25:18] alpha    (8 bit)
--   [17:0]  reserved (18 bit)
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity splat_rom is
    Generic (
        NUM_SPLATS : integer := 16;   -- number of splats loaded
        MEM_FILE   : string  := "test_splats.mem"
    );
    Port (
        clk        : in  STD_LOGIC;
        addr       : in  STD_LOGIC_VECTOR(12 downto 0); -- up to 8192
        splat_data : out STD_LOGIC_VECTOR(63 downto 0);
        num_total  : out STD_LOGIC_VECTOR(12 downto 0)   -- total splat count
    );
end splat_rom;

architecture Behavioral of splat_rom is

    constant ROM_DEPTH : integer := 8192;

    type rom_type is array (0 to ROM_DEPTH - 1) of std_logic_vector(63 downto 0);

    -- Reads a hex .mem file at elaboration time (synthesis and simulation).
    -- Vivado synthesis working dir = <project>.runs/synth_1/
    -- so MEM_FILE should be "../../mem/<scene>.mem" relative to that.
    impure function init_rom_hex(filename : string) return rom_type is
        file   f   : text open read_mode is filename;
        variable ln  : line;
        variable val : std_logic_vector(63 downto 0);
        variable mem : rom_type := (others => (others => '0'));
        variable idx : integer  := 0;
    begin
        while (not endfile(f)) and (idx < ROM_DEPTH) loop
            readline(f, ln);
            if ln'length >= 16 then
                hread(ln, val);
                mem(idx) := val;
                idx := idx + 1;
            end if;
        end loop;
        return mem;
    end function;

    signal rom      : rom_type := init_rom_hex(MEM_FILE);
    signal data_reg : std_logic_vector(63 downto 0) := (others => '0');

begin

    num_total <= std_logic_vector(to_unsigned(NUM_SPLATS, 13));

    process(clk)
    begin
        if rising_edge(clk) then
            data_reg <= rom(to_integer(unsigned(addr)));
        end if;
    end process;

    splat_data <= data_reg;

end Behavioral;
