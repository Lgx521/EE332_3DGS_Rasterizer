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

    -- Function to initialize ROM from a hex memory file
    -- For synthesis, use attribute to point to .mem file
    -- For simulation/initial testing, provide default test data
    function init_rom return rom_type is
        variable rom_v : rom_type := (others => (others => '0'));
    begin
        -- Default test splats (overridden by .mem file in synthesis)
        -- Splat 0: Red circle at (160, 120), radius=30, R=15, G=0, B=0, alpha=200
        -- center_x=160 (0xA0), center_y=120 (0x78), radius=30 (0x1E)
        -- R=15, G=0, B=0, alpha=200 (0xC8)
        rom_v(0) := "0010100000" & "001111000" & "0011110" & "1111" & "0000" & "0000" & "11001000" & "000000000000000000";

        -- Splat 1: Green circle at (100, 80), radius=25, R=0, G=15, B=0, alpha=180
        rom_v(1) := "0001100100" & "001010000" & "0011001" & "0000" & "1111" & "0000" & "10110100" & "000000000000000000";

        -- Splat 2: Blue circle at (220, 160), radius=35, R=0, G=0, B=15, alpha=160
        rom_v(2) := "0011011100" & "010100000" & "0100011" & "0000" & "0000" & "1111" & "10100000" & "000000000000000000";

        -- Splat 3: Yellow circle at (140, 180), radius=20, R=15, G=15, B=0, alpha=150
        rom_v(3) := "0010001100" & "010110100" & "0010100" & "1111" & "1111" & "0000" & "10010110" & "000000000000000000";

        -- Splat 4: White circle at (200, 60), radius=15, R=15, G=15, B=15, alpha=220
        rom_v(4) := "0011001000" & "000111100" & "0001111" & "1111" & "1111" & "1111" & "11011100" & "000000000000000000";

        return rom_v;
    end function;

    signal rom : rom_type := init_rom;
    signal data_reg : std_logic_vector(63 downto 0) := (others => '0');

    -- Synthesis attribute: initialize from memory file
    attribute ram_init_file : string;
    attribute ram_init_file of rom : signal is MEM_FILE;

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
