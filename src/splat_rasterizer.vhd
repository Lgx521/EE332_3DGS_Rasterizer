----------------------------------------------------------------------------------
-- splat_rasterizer.vhd
-- Core rasterizer: iterates pixels within each splat's bounding box,
-- computes normalized squared distance, looks up Gaussian weight,
-- and outputs pixel coordinates + effective alpha to the blender.
--
-- Pipeline (4 stages after pixel generation):
--   P0: generate (cur_x, cur_y), compute dx, dy
--   P1: compute d2 = dx^2 + dy^2, compare with r_sq
--   P2: compute d2_norm via inv_r_sq LUT, send to gaussian LUT
--   P3: read gaussian weight, compute eff_alpha = alpha * weight >> 8
--   P4: output pixel to blender
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity splat_rasterizer is
    Port (
        clk           : in  STD_LOGIC;
        reset         : in  STD_LOGIC;

        -- Control interface
        start         : in  STD_LOGIC;
        done          : out STD_LOGIC;
        busy          : out STD_LOGIC;

        -- Splat input (from splat_rom)
        splat_data    : in  STD_LOGIC_VECTOR(63 downto 0);

        -- Viewport pan offset (from camera_controller, signed)
        pan_x         : in  STD_LOGIC_VECTOR(10 downto 0);
        pan_y         : in  STD_LOGIC_VECTOR(10 downto 0);

        -- Rotation parameters (from camera_controller, signed 8-bit scale-127)
        mode          : in  STD_LOGIC;                    -- 0=pan, 1=rotate
        sin_spin      : in  STD_LOGIC_VECTOR(7 downto 0);
        cos_spin      : in  STD_LOGIC_VECTOR(7 downto 0);
        cos_tilt      : in  STD_LOGIC_VECTOR(7 downto 0);

        -- LUT interface (1-cycle read latency)
        lut_d2_norm   : out STD_LOGIC_VECTOR(7 downto 0);
        lut_weight    : in  STD_LOGIC_VECTOR(7 downto 0);

        -- Pixel output to alpha_blender
        px_valid      : out STD_LOGIC;
        px_x          : out STD_LOGIC_VECTOR(8 downto 0);
        px_y          : out STD_LOGIC_VECTOR(7 downto 0);
        px_r          : out STD_LOGIC_VECTOR(3 downto 0);
        px_g          : out STD_LOGIC_VECTOR(3 downto 0);
        px_b          : out STD_LOGIC_VECTOR(3 downto 0);
        px_eff_alpha  : out STD_LOGIC_VECTOR(7 downto 0)
    );
end splat_rasterizer;

architecture Behavioral of splat_rasterizer is

    constant SCREEN_W : integer := 320;
    constant SCREEN_H : integer := 240;

    -- Splat parameters (decoded)
    signal cx     : signed(10 downto 0);
    signal cy     : signed(10 downto 0);
    signal radius : unsigned(6 downto 0);
    signal s_r    : std_logic_vector(3 downto 0);
    signal s_g    : std_logic_vector(3 downto 0);
    signal s_b    : std_logic_vector(3 downto 0);
    signal s_alpha: unsigned(7 downto 0);

    -- Bounding box
    signal x_min, x_max : signed(10 downto 0);
    signal y_min, y_max : signed(10 downto 0);

    -- Precomputed r_sq
    signal r_sq : unsigned(13 downto 0);

    -- Inverse r_sq LUT: 128 entries, inv_r_sq(r) = min(255*256 / (r*r), 65535)
    -- Used for normalization: d2_norm = (d2 * inv_r_sq_val) >> 8
    type inv_rsq_lut_type is array (0 to 127) of unsigned(15 downto 0);

    function init_inv_rsq_lut return inv_rsq_lut_type is
        variable lut : inv_rsq_lut_type;
        variable rsq : integer;
        variable val : integer;
    begin
        lut(0) := to_unsigned(65535, 16);
        for i in 1 to 127 loop
            rsq := i * i;
            val := (255 * 256) / rsq;
            if val > 65535 then val := 65535; end if;
            lut(i) := to_unsigned(val, 16);
        end loop;
        return lut;
    end function;

    constant INV_RSQ_LUT : inv_rsq_lut_type := init_inv_rsq_lut;
    signal inv_r_sq_val : unsigned(15 downto 0);

    -- Iteration state
    signal cur_x : signed(10 downto 0);
    signal cur_y : signed(10 downto 0);
    signal iterating : std_logic := '0';
    signal last_pixel : std_logic := '0';

    -- Pipeline stage 1 registers (d2 computation)
    signal p1_valid : std_logic := '0';
    signal p1_x     : std_logic_vector(8 downto 0);
    signal p1_y     : std_logic_vector(7 downto 0);
    signal p1_d2    : unsigned(19 downto 0);

    -- Pipeline stage 2 registers (normalization + LUT request)
    signal p2_valid : std_logic := '0';
    signal p2_x     : std_logic_vector(8 downto 0);
    signal p2_y     : std_logic_vector(7 downto 0);

    -- Pipeline stage 3 registers (LUT result + eff_alpha)
    signal p3_valid : std_logic := '0';
    signal p3_x     : std_logic_vector(8 downto 0);
    signal p3_y     : std_logic_vector(7 downto 0);

    -- Drain counter for pipeline flush
    signal drain_cnt : unsigned(2 downto 0) := (others => '0');

    -- FSM
    type state_type is (S_IDLE, S_LOAD, S_CALC_BBOX, S_RASTER, S_RASTER_WAIT, S_DRAIN, S_DONE);
    signal state : state_type := S_IDLE;

    -- Helper: clamp
    function clamp_s(val, lo, hi : signed(10 downto 0)) return signed is
    begin
        if val < lo then return lo;
        elsif val > hi then return hi;
        else return val;
        end if;
    end function;

begin

    busy <= '0' when state = S_IDLE else '1';

    process(clk, reset)
        variable dx_v        : signed(10 downto 0);
        variable dy_v        : signed(10 downto 0);
        variable d2_v        : unsigned(19 downto 0);
        variable d2_norm_v   : unsigned(35 downto 0);
        variable d2_norm_8   : unsigned(7 downto 0);
        variable eff_alpha_v : unsigned(15 downto 0);
        -- Rotation transform temporaries
        variable cx_raw_v    : signed(10 downto 0);
        variable cy_raw_v    : signed(10 downto 0);
        variable cx_c_v      : signed(10 downto 0);
        variable cy_c_v      : signed(10 downto 0);
        variable tilt_prod_v : signed(18 downto 0);  -- 11-bit * 8-bit = 19-bit
        variable cy_tilt_v   : signed(10 downto 0);
        variable prod_ax_v   : signed(18 downto 0);
        variable prod_bx_v   : signed(18 downto 0);
        variable prod_ay_v   : signed(18 downto 0);
        variable prod_by_v   : signed(18 downto 0);
        variable cx_sum_v    : signed(10 downto 0);
        variable cy_sum_v    : signed(10 downto 0);
    begin
        if reset = '1' then
            state     <= S_IDLE;
            done      <= '0';
            px_valid  <= '0';
            p1_valid  <= '0';
            p2_valid  <= '0';
            p3_valid  <= '0';
            iterating <= '0';
            drain_cnt <= (others => '0');

        elsif rising_edge(clk) then

            -- Default: clear single-cycle pulses
            done     <= '0';
            px_valid <= '0';

            -- ========== PIPELINE STAGE 3 -> Output ==========
            -- Read LUT weight (available this cycle from p2's request)
            -- Compute eff_alpha = (s_alpha * weight) >> 8
            if p3_valid = '1' then
                eff_alpha_v := s_alpha * unsigned(lut_weight);
                px_valid     <= '1';
                px_x         <= p3_x;
                px_y         <= p3_y;
                px_r         <= s_r;
                px_g         <= s_g;
                px_b         <= s_b;
                px_eff_alpha <= std_logic_vector(eff_alpha_v(15 downto 8));
            end if;

            -- ========== PIPELINE STAGE 2 -> Stage 3 ==========
            -- LUT was addressed in stage 2; weight arrives next cycle
            p3_valid <= p2_valid;
            p3_x     <= p2_x;
            p3_y     <= p2_y;

            -- ========== PIPELINE STAGE 1 -> Stage 2 ==========
            -- Normalize d2: d2_norm = (d2 * inv_r_sq_val) >> 8, clamp to 255
            -- Also send d2_norm to gaussian LUT
            if p1_valid = '1' then
                d2_norm_v := p1_d2 * inv_r_sq_val;
                -- d2_norm = d2_norm_v >> 8, clamped to 255
                if d2_norm_v(35 downto 16) > 0 or d2_norm_v(15 downto 8) = X"FF" then
                    d2_norm_8 := (others => '1');
                else
                    d2_norm_8 := d2_norm_v(15 downto 8);
                end if;
                lut_d2_norm <= std_logic_vector(d2_norm_8);
                p2_valid <= '1';
                p2_x     <= p1_x;
                p2_y     <= p1_y;
            else
                p2_valid <= '0';
            end if;

            -- ========== PIPELINE STAGE 0 -> Stage 1 ==========
            -- Compute d2 = dx^2 + dy^2 for current pixel
            p1_valid <= '0';
            if iterating = '1' then
                dx_v := cur_x - cx;
                dy_v := cur_y - cy;
                d2_v := unsigned(resize(dx_v * dx_v, 20)) + unsigned(resize(dy_v * dy_v, 20));

                -- Only emit pixel if inside the circle (d2 <= r_sq)
                if d2_v <= resize(r_sq, 20) then
                    p1_valid <= '1';
                    p1_x     <= std_logic_vector(cur_x(8 downto 0));
                    p1_y     <= std_logic_vector(cur_y(7 downto 0));
                    p1_d2    <= d2_v;
                end if;

                -- Advance pixel iterator
                if cur_x < x_max then
                    cur_x <= cur_x + 1;
                else
                    cur_x <= x_min;
                    if cur_y < y_max then
                        cur_y <= cur_y + 1;
                    else
                        iterating <= '0'; -- done generating pixels
                    end if;
                end if;
            end if;

            -- ========== FSM ==========
            case state is

                when S_IDLE =>
                    if start = '1' then
                        state <= S_LOAD;
                    end if;

                when S_LOAD =>
                    -- Decode common splat parameters
                    radius  <= unsigned(splat_data(44 downto 38));
                    s_r     <= splat_data(37 downto 34);
                    s_g     <= splat_data(33 downto 30);
                    s_b     <= splat_data(29 downto 26);
                    s_alpha <= unsigned(splat_data(25 downto 18));
                    state   <= S_CALC_BBOX;
                    -- Decode raw centre position
                    cx_raw_v := signed(resize(unsigned(splat_data(63 downto 54)), 11));
                    cy_raw_v := signed(resize(unsigned(splat_data(53 downto 45)), 11));
                    if mode = '0' then
                        -- Pan mode: simple viewport offset
                        cx <= cx_raw_v + signed(pan_x);
                        cy <= cy_raw_v + signed(pan_y);
                    else
                        -- Rotate mode: tilt (Y-scale) then in-plane spin around (160,120)
                        cx_c_v      := cx_raw_v - to_signed(160, 11);
                        cy_c_v      := cy_raw_v - to_signed(120, 11);
                        -- Tilt: scale cy by cos_tilt  (scale factor 127, right-shift 7)
                        tilt_prod_v := cy_c_v * signed(cos_tilt);
                        cy_tilt_v   := tilt_prod_v(17 downto 7);
                        -- 2-D rotation matrix
                        prod_ax_v   := cx_c_v   * signed(cos_spin);
                        prod_bx_v   := cy_tilt_v * signed(sin_spin);
                        prod_ay_v   := cx_c_v   * signed(sin_spin);
                        prod_by_v   := cy_tilt_v * signed(cos_spin);
                        cx_sum_v    := prod_ax_v(17 downto 7) - prod_bx_v(17 downto 7);
                        cy_sum_v    := prod_ay_v(17 downto 7) + prod_by_v(17 downto 7);
                        cx          <= cx_sum_v + to_signed(160, 11);
                        cy          <= cy_sum_v + to_signed(120, 11);
                    end if;

                when S_CALC_BBOX =>
                    -- Compute bounding box clamped to screen
                    x_min <= clamp_s(cx - signed(resize(radius, 11)),
                                     to_signed(0, 11), to_signed(SCREEN_W-1, 11));
                    x_max <= clamp_s(cx + signed(resize(radius, 11)),
                                     to_signed(0, 11), to_signed(SCREEN_W-1, 11));
                    y_min <= clamp_s(cy - signed(resize(radius, 11)),
                                     to_signed(0, 11), to_signed(SCREEN_H-1, 11));
                    y_max <= clamp_s(cy + signed(resize(radius, 11)),
                                     to_signed(0, 11), to_signed(SCREEN_H-1, 11));
                    -- Precompute
                    r_sq         <= resize(radius * radius, 14);
                    inv_r_sq_val <= INV_RSQ_LUT(to_integer(radius));
                    state <= S_RASTER;

                when S_RASTER =>
                    -- Start iteration on first clock in this state
                    cur_x     <= x_min;
                    cur_y     <= y_min;
                    iterating <= '1';
                    state     <= S_RASTER_WAIT;

                when S_RASTER_WAIT =>
                    -- Wait for pixel iteration to complete
                    if iterating = '0' then
                        state     <= S_DRAIN;
                        drain_cnt <= "101"; -- 5 cycles to drain pipeline
                    end if;

                when S_DRAIN =>
                    if drain_cnt > 0 then
                        drain_cnt <= drain_cnt - 1;
                    else
                        state <= S_DONE;
                    end if;

                when S_DONE =>
                    done  <= '1';
                    state <= S_IDLE;

                when others =>
                    state <= S_IDLE;

            end case;

        end if;
    end process;

end Behavioral;
