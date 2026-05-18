----------------------------------------------------------------------------------
-- camera_controller.vhd
-- Debounces BTNU/D/L/R/C and maintains a 2D viewport pan offset.
-- The pan offset is added to every splat's cx/cy in the rasterizer,
-- producing a real-time panning effect without re-projecting 3D data.
--
--   BTNU : scene pans UP    (pan_y decreases)
--   BTND : scene pans DOWN  (pan_y increases)
--   BTNL : scene pans LEFT  (pan_x decreases)
--   BTNR : scene pans RIGHT (pan_x increases)
--   BTNC : reset pan to center (0, 0)
--
-- Debounce: each button sampled every 1 ms; declared stable after
-- 16 consecutive identical samples (~16 ms total).
-- Pan updates once per frame_tick while the button is held.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity camera_controller is
    Generic (
        CLK_FREQ_HZ : integer := 100_000_000; -- system clock frequency
        PAN_STEP    : integer := 4;            -- pixels moved per frame per button
        PAN_MAX_X   : integer := 319;          -- maximum x pan magnitude
        PAN_MAX_Y   : integer := 239           -- maximum y pan magnitude
    );
    Port (
        clk        : in  STD_LOGIC;
        reset      : in  STD_LOGIC;
        btn_u      : in  STD_LOGIC; -- BTNU, active-high
        btn_d      : in  STD_LOGIC; -- BTND, active-high
        btn_l      : in  STD_LOGIC; -- BTNL, active-high
        btn_r      : in  STD_LOGIC; -- BTNR, active-high
        btn_c      : in  STD_LOGIC; -- BTNC, active-high (reset pan)
        frame_tick : in  STD_LOGIC; -- one-cycle pulse per rendered frame
        pan_x      : out STD_LOGIC_VECTOR(10 downto 0); -- signed, added to cx
        pan_y      : out STD_LOGIC_VECTOR(10 downto 0)  -- signed, added to cy
    );
end camera_controller;

architecture Behavioral of camera_controller is

    -- Sample period: 1 ms
    constant SAMPLE_PERIOD : integer := CLK_FREQ_HZ / 1000;

    signal sample_cnt  : integer range 0 to SAMPLE_PERIOD - 1 := 0;
    signal sample_tick : std_logic := '0';

    -- 16-stage shift registers for each button (one bit shifted in per sample)
    signal sr_u : std_logic_vector(15 downto 0) := (others => '0');
    signal sr_d : std_logic_vector(15 downto 0) := (others => '0');
    signal sr_l : std_logic_vector(15 downto 0) := (others => '0');
    signal sr_r : std_logic_vector(15 downto 0) := (others => '0');
    signal sr_c : std_logic_vector(15 downto 0) := (others => '0');

    -- Debounced button levels
    signal db_u : std_logic := '0';
    signal db_d : std_logic := '0';
    signal db_l : std_logic := '0';
    signal db_r : std_logic := '0';
    signal db_c : std_logic := '0';

    -- Pan registers (signed 11-bit covers -1024 .. +1023, sufficient for ±319/±239)
    signal reg_pan_x : signed(10 downto 0) := (others => '0');
    signal reg_pan_y : signed(10 downto 0) := (others => '0');

begin

    -- -------------------------------------------------------------------------
    -- 1 ms sample tick
    -- -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sample_cnt  <= 0;
                sample_tick <= '0';
            elsif sample_cnt = SAMPLE_PERIOD - 1 then
                sample_cnt  <= 0;
                sample_tick <= '1';
            else
                sample_cnt  <= sample_cnt + 1;
                sample_tick <= '0';
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- Shift-register debounce for all five buttons
    -- -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sr_u <= (others => '0');
                sr_d <= (others => '0');
                sr_l <= (others => '0');
                sr_r <= (others => '0');
                sr_c <= (others => '0');
                db_u <= '0';
                db_d <= '0';
                db_l <= '0';
                db_r <= '0';
                db_c <= '0';
            elsif sample_tick = '1' then
                -- Shift in raw button samples
                sr_u <= sr_u(14 downto 0) & btn_u;
                sr_d <= sr_d(14 downto 0) & btn_d;
                sr_l <= sr_l(14 downto 0) & btn_l;
                sr_r <= sr_r(14 downto 0) & btn_r;
                sr_c <= sr_c(14 downto 0) & btn_c;

                -- Update debounced level: only change when all 16 samples agree
                if sr_u = X"FFFF" then db_u <= '1'; elsif sr_u = X"0000" then db_u <= '0'; end if;
                if sr_d = X"FFFF" then db_d <= '1'; elsif sr_d = X"0000" then db_d <= '0'; end if;
                if sr_l = X"FFFF" then db_l <= '1'; elsif sr_l = X"0000" then db_l <= '0'; end if;
                if sr_r = X"FFFF" then db_r <= '1'; elsif sr_r = X"0000" then db_r <= '0'; end if;
                if sr_c = X"FFFF" then db_c <= '1'; elsif sr_c = X"0000" then db_c <= '0'; end if;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- Pan register update: once per frame while button is held
    -- -------------------------------------------------------------------------
    process(clk)
        variable nx : signed(10 downto 0);
        variable ny : signed(10 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                reg_pan_x <= (others => '0');
                reg_pan_y <= (others => '0');
            elsif frame_tick = '1' then
                nx := reg_pan_x;
                ny := reg_pan_y;

                if db_c = '1' then
                    -- Center: reset both axes
                    nx := (others => '0');
                    ny := (others => '0');
                else
                    if db_u = '1' and ny > -PAN_MAX_Y then
                        ny := ny - PAN_STEP;
                    end if;
                    if db_d = '1' and ny <  PAN_MAX_Y then
                        ny := ny + PAN_STEP;
                    end if;
                    if db_l = '1' and nx > -PAN_MAX_X then
                        nx := nx - PAN_STEP;
                    end if;
                    if db_r = '1' and nx <  PAN_MAX_X then
                        nx := nx + PAN_STEP;
                    end if;
                end if;

                reg_pan_x <= nx;
                reg_pan_y <= ny;
            end if;
        end if;
    end process;

    pan_x <= std_logic_vector(reg_pan_x);
    pan_y <= std_logic_vector(reg_pan_y);

end Behavioral;
