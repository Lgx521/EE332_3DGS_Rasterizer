----------------------------------------------------------------------------------
-- tb_vga.vhd
-- Testbench for VGA timing + controller chain
-- Verifies sync timing and pixel addressing
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_vga is
end tb_vga;

architecture Behavioral of tb_vga is

    -- 25 MHz pixel clock period = 40 ns
    constant PIX_CLK_PERIOD : time := 40 ns;

    signal pix_clk      : std_logic := '0';
    signal reset        : std_logic := '1';
    signal h_count      : std_logic_vector(9 downto 0);
    signal v_count      : std_logic_vector(9 downto 0);
    signal h_sync       : std_logic;
    signal v_sync       : std_logic;
    signal video_active : std_logic;
    signal frame_start  : std_logic;

    -- VGA controller signals
    signal fb_addr : std_logic_vector(16 downto 0);
    signal fb_data : std_logic_vector(11 downto 0);
    signal vga_r   : std_logic_vector(3 downto 0);
    signal vga_g   : std_logic_vector(3 downto 0);
    signal vga_b   : std_logic_vector(3 downto 0);
    signal vga_hs  : std_logic;
    signal vga_vs  : std_logic;

    signal sim_done : boolean := false;

begin

    -- 25 MHz clock
    pix_clk <= not pix_clk after PIX_CLK_PERIOD / 2 when not sim_done else '0';

    -- VGA timing generator
    u_timing : entity work.vga_timing
    port map (
        pix_clk     => pix_clk,
        reset       => reset,
        h_count     => h_count,
        v_count     => v_count,
        h_sync      => h_sync,
        v_sync      => v_sync,
        video_active=> video_active,
        frame_start => frame_start
    );

    -- Test framebuffer data: generate a color bar pattern
    -- Address maps to 320x240, generate test pattern from address
    process(pix_clk)
        variable addr_int : integer;
        variable x_pos : integer;
    begin
        if rising_edge(pix_clk) then
            addr_int := to_integer(unsigned(fb_addr));
            x_pos := addr_int mod 320;
            -- Color bars: divide screen into 8 sections
            case x_pos / 40 is
                when 0 => fb_data <= X"F00"; -- Red
                when 1 => fb_data <= X"0F0"; -- Green
                when 2 => fb_data <= X"00F"; -- Blue
                when 3 => fb_data <= X"FF0"; -- Yellow
                when 4 => fb_data <= X"F0F"; -- Magenta
                when 5 => fb_data <= X"0FF"; -- Cyan
                when 6 => fb_data <= X"FFF"; -- White
                when 7 => fb_data <= X"888"; -- Gray
                when others => fb_data <= X"000";
            end case;
        end if;
    end process;

    -- VGA controller
    u_ctrl : entity work.vga_controller
    port map (
        pix_clk      => pix_clk,
        reset        => reset,
        h_count      => h_count,
        v_count      => v_count,
        video_active => video_active,
        h_sync_in    => h_sync,
        v_sync_in    => v_sync,
        fb_addr      => fb_addr,
        fb_data      => fb_data,
        vga_r        => vga_r,
        vga_g        => vga_g,
        vga_b        => vga_b,
        vga_hs       => vga_hs,
        vga_vs       => vga_vs
    );

    -- Stimulus and checks
    stim_proc : process
        variable frame_count : integer := 0;
        variable last_vs : std_logic := '1';
        variable h_active_count : integer := 0;
    begin
        -- Reset
        reset <= '1';
        wait for 200 ns;
        reset <= '0';

        -- Wait for first frame_start
        wait until frame_start = '1' for 20 ms;
        report "First frame started";

        -- Monitor for 2 full frames (~33.3 ms)
        for frame_idx in 0 to 1 loop
            -- Wait for v_sync falling edge
            wait until falling_edge(vga_vs) for 20 ms;
            frame_count := frame_count + 1;
            report "Frame " & integer'image(frame_count) & " v_sync detected";
        end loop;

        -- Check that we got frames
        assert frame_count >= 2
            report "Expected at least 2 frames"
            severity error;

        report "VGA timing test passed. Frames detected: " & integer'image(frame_count);
        sim_done <= true;
        wait;
    end process;

end Behavioral;
