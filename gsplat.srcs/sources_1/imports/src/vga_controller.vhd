----------------------------------------------------------------------------------
-- vga_controller.vhd
-- Reads pixels from framebuffer and outputs VGA signals
-- Maps 320x240 render resolution to 640x480 VGA via 2x2 pixel replication
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity vga_controller is
    Port (
        pix_clk       : in  STD_LOGIC;
        reset         : in  STD_LOGIC;
        -- From VGA timing
        h_count       : in  STD_LOGIC_VECTOR(9 downto 0);
        v_count       : in  STD_LOGIC_VECTOR(9 downto 0);
        video_active  : in  STD_LOGIC;
        h_sync_in     : in  STD_LOGIC;
        v_sync_in     : in  STD_LOGIC;
        -- To framebuffer
        fb_addr       : out STD_LOGIC_VECTOR(16 downto 0);
        fb_data       : in  STD_LOGIC_VECTOR(11 downto 0);
        -- VGA output
        vga_r         : out STD_LOGIC_VECTOR(3 downto 0);
        vga_g         : out STD_LOGIC_VECTOR(3 downto 0);
        vga_b         : out STD_LOGIC_VECTOR(3 downto 0);
        vga_hs        : out STD_LOGIC;
        vga_vs        : out STD_LOGIC
    );
end vga_controller;

architecture Behavioral of vga_controller is

    constant FB_WIDTH  : integer := 320;
    constant FB_HEIGHT : integer := 240;

    signal fb_x : unsigned(8 downto 0);  -- 0..319
    signal fb_y : unsigned(7 downto 0);  -- 0..239
    signal fb_addr_calc : unsigned(16 downto 0);

    -- Pipeline delay registers for sync and active signals
    signal h_sync_d1 : std_logic := '1';
    signal v_sync_d1 : std_logic := '1';
    signal active_d1 : std_logic := '0';

begin

    -- Map 640x480 VGA coordinates to 320x240 framebuffer
    -- Divide by 2 via right shift
    fb_x <= unsigned(h_count(9 downto 1));
    fb_y <= unsigned(v_count(8 downto 1));

    -- Calculate linear address: y * 320 + x
    fb_addr_calc <= resize(fb_y * to_unsigned(FB_WIDTH, 9), 17) + resize(fb_x, 17);

    fb_addr <= std_logic_vector(fb_addr_calc);

    -- One clock pipeline delay for BRAM read latency
    process(pix_clk)
    begin
        if rising_edge(pix_clk) then
            h_sync_d1 <= h_sync_in;
            v_sync_d1 <= v_sync_in;
            active_d1 <= video_active;
        end if;
    end process;

    -- Output VGA signals
    vga_hs <= h_sync_d1;
    vga_vs <= v_sync_d1;

    -- RGB output: show framebuffer data when active, black otherwise
    vga_r <= fb_data(11 downto 8) when active_d1 = '1' else "0000";
    vga_g <= fb_data(7 downto 4)  when active_d1 = '1' else "0000";
    vga_b <= fb_data(3 downto 0)  when active_d1 = '1' else "0000";

end Behavioral;
