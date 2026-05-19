----------------------------------------------------------------------------------
-- clk_gen.vhd
-- Clock generator: 100 MHz -> 25 MHz pixel clock using MMCME2_BASE
-- Target: Artix-7 (Nexys4 DDR)
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity clk_gen is
    Port (
        clk_100m  : in  STD_LOGIC;
        resetn    : in  STD_LOGIC;
        clk_25m   : out STD_LOGIC;
        locked    : out STD_LOGIC
    );
end clk_gen;

architecture Behavioral of clk_gen is
    signal clkfbout   : std_logic;
    signal clkfbin    : std_logic;
    signal clk_25m_buf: std_logic;
    signal clk_25m_unbuf : std_logic;
begin

    -- MMCME2_BASE: 100 MHz in -> 25 MHz out
    -- VCO = 100 * 10.0 / 1 = 1000 MHz
    -- CLKOUT0 = 1000 / 40.0 = 25 MHz
    MMCME2_inst : MMCME2_BASE
    generic map (
        BANDWIDTH          => "OPTIMIZED",
        CLKFBOUT_MULT_F    => 10.0,       -- VCO = 100 * 10 = 1000 MHz
        CLKFBOUT_PHASE     => 0.0,
        CLKIN1_PERIOD      => 10.0,        -- 100 MHz input
        CLKOUT0_DIVIDE_F   => 40.0,        -- 1000 / 40 = 25 MHz
        CLKOUT0_DUTY_CYCLE => 0.5,
        CLKOUT0_PHASE      => 0.0,
        DIVCLK_DIVIDE      => 1,
        REF_JITTER1        => 0.010,
        STARTUP_WAIT       => FALSE
    )
    port map (
        CLKOUT0  => clk_25m_unbuf,
        CLKOUT0B => open,
        CLKOUT1  => open,
        CLKOUT1B => open,
        CLKOUT2  => open,
        CLKOUT2B => open,
        CLKOUT3  => open,
        CLKOUT3B => open,
        CLKOUT4  => open,
        CLKOUT5  => open,
        CLKOUT6  => open,
        CLKFBOUT => clkfbout,
        CLKFBOUTB=> open,
        LOCKED   => locked,
        CLKIN1   => clk_100m,
        PWRDWN   => '0',
        RST      => not resetn,
        CLKFBIN  => clkfbin
    );

    -- Feedback buffer
    BUFG_fb : BUFG
    port map (
        I => clkfbout,
        O => clkfbin
    );

    -- Output buffer
    BUFG_out : BUFG
    port map (
        I => clk_25m_unbuf,
        O => clk_25m_buf
    );

    clk_25m <= clk_25m_buf;

end Behavioral;
