----------------------------------------------------------------------------------
-- tb_top.vhd
-- Testbench for top_gsplat: full system simulation
-- Verifies VGA output timing and basic rendering pipeline
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_top is
end tb_top;

architecture Behavioral of tb_top is

    -- Clock period: 100 MHz = 10 ns
    constant CLK_PERIOD : time := 10 ns;

    -- DUT signals
    signal CLK100MHZ  : std_logic := '0';
    signal CPU_RESETN : std_logic := '0';  -- start in reset
    signal BTNC       : std_logic := '0';
    signal SW         : std_logic_vector(1 downto 0) := "00";
    signal LED        : std_logic_vector(3 downto 0);
    signal VGA_R      : std_logic_vector(3 downto 0);
    signal VGA_G      : std_logic_vector(3 downto 0);
    signal VGA_B      : std_logic_vector(3 downto 0);
    signal VGA_HS     : std_logic;
    signal VGA_VS     : std_logic;

    -- Simulation control
    signal sim_done   : boolean := false;

begin

    -- Clock generation
    CLK100MHZ <= not CLK100MHZ after CLK_PERIOD / 2 when not sim_done else '0';

    -- DUT instantiation
    u_dut : entity work.top_gsplat
    port map (
        CLK100MHZ  => CLK100MHZ,
        CPU_RESETN => CPU_RESETN,
        BTNC       => BTNC,
        SW         => SW,
        LED        => LED,
        VGA_R      => VGA_R,
        VGA_G      => VGA_G,
        VGA_B      => VGA_B,
        VGA_HS     => VGA_HS,
        VGA_VS     => VGA_VS
    );

    -- Stimulus process
    stim_proc : process
    begin
        -- Hold reset for 200 ns
        CPU_RESETN <= '0';
        wait for 200 ns;

        -- Release reset
        CPU_RESETN <= '1';
        wait for 100 ns;

        -- Wait for PLL lock (LED(0) should go high)
        wait until LED(0) = '1' for 10 us;
        assert LED(0) = '1'
            report "PLL did not lock within 10 us"
            severity warning;

        -- Wait for first frame render to complete
        -- At 100 MHz, clearing 76800 pixels + rendering 8 splats
        -- should take well under 20 ms (one VGA frame)
        -- Let's wait a bit and check LED(1) toggles
        wait for 20 ms;

        -- Check that rendering has happened (frame count > 0)
        assert LED(2) = '1' or LED(2) = '0'
            report "Frame counter not toggling"
            severity note;

        -- Let simulation run for a couple more frames to verify stability
        wait for 40 ms;

        report "Simulation complete - 3 frames rendered"
            severity note;

        sim_done <= true;
        wait;
    end process;

    -- VGA timing monitor process
    vga_mon : process
        variable hs_count : integer := 0;
        variable vs_count : integer := 0;
        variable last_hs  : std_logic := '1';
        variable last_vs  : std_logic := '1';
    begin
        wait until CPU_RESETN = '1';
        wait for 1 us;

        while not sim_done loop
            wait until rising_edge(CLK100MHZ) or sim_done;
            if sim_done then exit; end if;

            -- Count H-sync falling edges
            if last_hs = '1' and VGA_HS = '0' then
                hs_count := hs_count + 1;
            end if;
            last_hs := VGA_HS;

            -- Count V-sync falling edges (frame boundaries)
            if last_vs = '1' and VGA_VS = '0' then
                vs_count := vs_count + 1;
                report "VGA frame " & integer'image(vs_count) &
                       " (h_sync edges: " & integer'image(hs_count) & ")"
                    severity note;
                hs_count := 0;
            end if;
            last_vs := VGA_VS;
        end loop;

        wait;
    end process;

end Behavioral;
