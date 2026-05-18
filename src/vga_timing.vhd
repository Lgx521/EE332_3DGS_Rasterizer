----------------------------------------------------------------------------------
-- vga_timing.vhd
-- VGA timing generator for 640x480 @ 60Hz
-- Pixel clock: 25 MHz
-- H: 640 visible + 16 FP + 96 sync + 48 BP = 800 total
-- V: 480 visible + 10 FP + 2 sync + 33 BP = 525 total
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity vga_timing is
    Port (
        pix_clk      : in  STD_LOGIC;
        reset         : in  STD_LOGIC;
        h_count       : out STD_LOGIC_VECTOR(9 downto 0);
        v_count       : out STD_LOGIC_VECTOR(9 downto 0);
        h_sync        : out STD_LOGIC;
        v_sync        : out STD_LOGIC;
        video_active  : out STD_LOGIC;
        frame_start   : out STD_LOGIC
    );
end vga_timing;

architecture Behavioral of vga_timing is

    -- Horizontal timing constants
    constant H_VISIBLE  : integer := 640;
    constant H_FP       : integer := 16;
    constant H_SYNC_PW  : integer := 96;
    constant H_BP       : integer := 48;
    constant H_TOTAL    : integer := 800;

    -- Vertical timing constants
    constant V_VISIBLE  : integer := 480;
    constant V_FP       : integer := 10;
    constant V_SYNC_PW  : integer := 2;
    constant V_BP       : integer := 33;
    constant V_TOTAL    : integer := 525;

    signal h_cnt : unsigned(9 downto 0) := (others => '0');
    signal v_cnt : unsigned(9 downto 0) := (others => '0');

begin

    -- Horizontal and vertical counters
    process(pix_clk, reset)
    begin
        if reset = '1' then
            h_cnt <= (others => '0');
            v_cnt <= (others => '0');
        elsif rising_edge(pix_clk) then
            if h_cnt = H_TOTAL - 1 then
                h_cnt <= (others => '0');
                if v_cnt = V_TOTAL - 1 then
                    v_cnt <= (others => '0');
                else
                    v_cnt <= v_cnt + 1;
                end if;
            else
                h_cnt <= h_cnt + 1;
            end if;
        end if;
    end process;

    -- Output assignments
    h_count <= std_logic_vector(h_cnt);
    v_count <= std_logic_vector(v_cnt);

    -- Sync signals (active low for standard VGA)
    h_sync <= '0' when (h_cnt >= H_VISIBLE + H_FP) and (h_cnt < H_VISIBLE + H_FP + H_SYNC_PW) else '1';
    v_sync <= '0' when (v_cnt >= V_VISIBLE + V_FP) and (v_cnt < V_VISIBLE + V_FP + V_SYNC_PW) else '1';

    -- Video active region
    video_active <= '1' when (h_cnt < H_VISIBLE) and (v_cnt < V_VISIBLE) else '0';

    -- Frame start pulse: first pixel of first visible line
    frame_start <= '1' when (h_cnt = 0) and (v_cnt = 0) else '0';

end Behavioral;
