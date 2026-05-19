----------------------------------------------------------------------------------
-- camera_controller.vhd
-- Pan / Rotate mode controller with button debounce.
--
-- SW(0) = mode_sel = 0 : Pan mode
--   BTNU/D/L/R  pan viewport; BTNC resets pan
-- SW(0) = mode_sel = 1 : Rotate mode
--   BTNL/R      spin  (in-plane rotation, ±2 steps/frame)
--   BTNU/D      tilt  (Y-axis scale via cos, clamped ±MAX_TILT)
--   BTNC        reset spin, tilt, and pan to identity
--
-- Tilt is clamped to ±MAX_TILT (default 32 ≈ ±45°) so the Y axis
-- never shrinks below ~71%, preventing the scene from collapsing.
-- Rotation uses a 256-entry sin LUT (elaboration-time math_real).
-- cos(x) = sin(x + 64) in the 256-unit circle.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity camera_controller is
    Generic (
        CLK_FREQ_HZ : integer := 100_000_000;
        PAN_STEP    : integer := 4;
        PAN_MAX_X   : integer := 319;
        PAN_MAX_Y   : integer := 239;
        ROT_STEP    : integer := 2;   -- angle increment per frame (units of 1/256 turn)
        MAX_TILT    : integer := 32    -- max tilt angle (32 ≈ ±45°, Y min ~71%)
    );
    Port (
        clk        : in  STD_LOGIC;
        reset      : in  STD_LOGIC;
        btn_u      : in  STD_LOGIC;
        btn_d      : in  STD_LOGIC;
        btn_l      : in  STD_LOGIC;
        btn_r      : in  STD_LOGIC;
        btn_c      : in  STD_LOGIC;
        mode_sel   : in  STD_LOGIC;           -- 0=pan, 1=rotate  (from SW(0))
        frame_tick : in  STD_LOGIC;
        mode       : out STD_LOGIC;           -- mirrors mode_sel for rasterizer
        pan_x      : out STD_LOGIC_VECTOR(10 downto 0);
        pan_y      : out STD_LOGIC_VECTOR(10 downto 0);
        sin_spin   : out STD_LOGIC_VECTOR(7 downto 0);  -- signed 8-bit, scale 127
        cos_spin   : out STD_LOGIC_VECTOR(7 downto 0);
        cos_tilt   : out STD_LOGIC_VECTOR(7 downto 0)
    );
end camera_controller;

architecture Behavioral of camera_controller is

    constant SAMPLE_PERIOD : integer := CLK_FREQ_HZ / 1000;

    signal sample_cnt  : integer range 0 to SAMPLE_PERIOD - 1 := 0;
    signal sample_tick : std_logic := '0';

    signal sr_u, sr_d, sr_l, sr_r, sr_c : std_logic_vector(15 downto 0) := (others => '0');
    signal db_u, db_d, db_l, db_r, db_c : std_logic := '0';

    signal reg_pan_x  : signed(10 downto 0) := (others => '0');
    signal reg_pan_y  : signed(10 downto 0) := (others => '0');
    signal spin_angle : unsigned(7 downto 0) := (others => '0'); -- 0-255 maps 0-360 deg
    signal tilt_angle : signed(7 downto 0)   := (others => '0'); -- clamped ±MAX_TILT

    -- Sin LUT: 256 entries.  value_i = round(127 * sin(2*pi*i/256)),  signed 8-bit.
    -- cos(x) addressed as SIN_LUT(x + 64) because cos(x) = sin(x + 90 deg).
    type sinlut_t is array(0 to 255) of signed(7 downto 0);
    function init_sin_lut return sinlut_t is
        variable lut : sinlut_t;
        variable v   : real;
    begin
        for i in 0 to 255 loop
            v := 127.0 * sin(real(i) * 2.0 * MATH_PI / 256.0);
            if    v >  126.5 then lut(i) := to_signed( 127, 8);
            elsif v < -127.0 then lut(i) := to_signed(-127, 8);
            else               lut(i) := to_signed(integer(round(v)), 8);
            end if;
        end loop;
        return lut;
    end function;
    constant SIN_LUT : sinlut_t := init_sin_lut;

    -- Cos-tilt LUT: unsigned 8-bit, scale 128 (identity = 128 = exact 1.0).
    -- Indexed by unsigned interpretation of signed tilt_angle.
    -- cos(-x) = cos(x), so negative angles give the same scale as positive.
    type costilt_t is array(0 to 255) of unsigned(7 downto 0);
    function init_cos_tilt_lut return costilt_t is
        variable lut : costilt_t;
        variable v   : real;
    begin
        for i in 0 to 255 loop
            v := 128.0 * cos(real(i) * 2.0 * MATH_PI / 256.0);
            if    v >= 128.0 then lut(i) := to_unsigned(128, 8);
            elsif v <=   0.0 then lut(i) := to_unsigned(  0, 8);
            else               lut(i) := to_unsigned(integer(round(v)), 8);
            end if;
        end loop;
        return lut;
    end function;
    constant COS_TILT_LUT : costilt_t := init_cos_tilt_lut;

begin

    mode     <= mode_sel;
    pan_x    <= std_logic_vector(reg_pan_x);
    pan_y    <= std_logic_vector(reg_pan_y);
    sin_spin <= std_logic_vector(SIN_LUT(to_integer(spin_angle)));
    cos_spin <= std_logic_vector(SIN_LUT(to_integer(spin_angle + 64)));
    -- tilt_angle is signed; reinterpret as unsigned for LUT index (cos is even)
    cos_tilt <= std_logic_vector(COS_TILT_LUT(
                    to_integer(unsigned(std_logic_vector(tilt_angle)))));

    -- 1 ms sample tick
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

    -- Shift-register debounce
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sr_u <= (others => '0'); sr_d <= (others => '0');
                sr_l <= (others => '0'); sr_r <= (others => '0');
                sr_c <= (others => '0');
                db_u <= '0'; db_d <= '0'; db_l <= '0'; db_r <= '0'; db_c <= '0';
            elsif sample_tick = '1' then
                sr_u <= sr_u(14 downto 0) & btn_u;
                sr_d <= sr_d(14 downto 0) & btn_d;
                sr_l <= sr_l(14 downto 0) & btn_l;
                sr_r <= sr_r(14 downto 0) & btn_r;
                sr_c <= sr_c(14 downto 0) & btn_c;
                if sr_u = X"FFFF" then db_u <= '1'; elsif sr_u = X"0000" then db_u <= '0'; end if;
                if sr_d = X"FFFF" then db_d <= '1'; elsif sr_d = X"0000" then db_d <= '0'; end if;
                if sr_l = X"FFFF" then db_l <= '1'; elsif sr_l = X"0000" then db_l <= '0'; end if;
                if sr_r = X"FFFF" then db_r <= '1'; elsif sr_r = X"0000" then db_r <= '0'; end if;
                if sr_c = X"FFFF" then db_c <= '1'; elsif sr_c = X"0000" then db_c <= '0'; end if;
            end if;
        end if;
    end process;

    -- Pan / Rotate register update (once per frame)
    process(clk)
        variable nx : signed(10 downto 0);
        variable ny : signed(10 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                reg_pan_x  <= (others => '0');
                reg_pan_y  <= (others => '0');
                spin_angle <= (others => '0');
                tilt_angle <= (others => '0');
            elsif frame_tick = '1' then
                nx := reg_pan_x;
                ny := reg_pan_y;

                if mode_sel = '0' then
                    -- Pan mode: BTNU/D/L/R pan, BTNC reset
                    if db_u = '1' and ny > -PAN_MAX_Y then ny := ny - PAN_STEP; end if;
                    if db_d = '1' and ny <  PAN_MAX_Y then ny := ny + PAN_STEP; end if;
                    if db_l = '1' and nx > -PAN_MAX_X then nx := nx - PAN_STEP; end if;
                    if db_r = '1' and nx <  PAN_MAX_X then nx := nx + PAN_STEP; end if;
                    if db_c = '1' then
                        nx := (others => '0');
                        ny := (others => '0');
                    end if;
                    reg_pan_x <= nx;
                    reg_pan_y <= ny;
                else
                    -- Rotate mode: L/R=spin, U/D=tilt (clamped), C=reset all
                    if db_c = '1' then
                        spin_angle <= (others => '0');
                        tilt_angle <= (others => '0');
                        reg_pan_x  <= (others => '0');
                        reg_pan_y  <= (others => '0');
                    else
                        if db_l = '1' then spin_angle <= spin_angle - ROT_STEP; end if;
                        if db_r = '1' then spin_angle <= spin_angle + ROT_STEP; end if;
                        if db_u = '1' and tilt_angle > -MAX_TILT then
                            tilt_angle <= tilt_angle - ROT_STEP;
                        end if;
                        if db_d = '1' and tilt_angle <  MAX_TILT then
                            tilt_angle <= tilt_angle + ROT_STEP;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;
