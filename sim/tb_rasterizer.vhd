----------------------------------------------------------------------------------
-- tb_rasterizer.vhd
-- Testbench for splat_rasterizer + gaussian_lut + alpha_blender
-- Tests individual splat rendering with known parameters
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rasterizer is
end tb_rasterizer;

architecture Behavioral of tb_rasterizer is

    constant CLK_PERIOD : time := 10 ns;

    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Rasterizer signals
    signal rast_start      : std_logic := '0';
    signal rast_done       : std_logic;
    signal rast_busy       : std_logic;
    signal rast_splat_data : std_logic_vector(63 downto 0) := (others => '0');
    signal lut_d2_norm     : std_logic_vector(7 downto 0);
    signal lut_weight      : std_logic_vector(7 downto 0);
    signal px_valid        : std_logic;
    signal px_x            : std_logic_vector(8 downto 0);
    signal px_y            : std_logic_vector(7 downto 0);
    signal px_r            : std_logic_vector(3 downto 0);
    signal px_g            : std_logic_vector(3 downto 0);
    signal px_b            : std_logic_vector(3 downto 0);
    signal px_eff_alpha    : std_logic_vector(7 downto 0);

    -- Blender signals
    signal blend_fb_addr : std_logic_vector(16 downto 0);
    signal blend_fb_din  : std_logic_vector(11 downto 0);
    signal blend_fb_dout : std_logic_vector(11 downto 0) := (others => '0');
    signal blend_fb_we   : std_logic;
    signal blend_busy    : std_logic;

    -- Simple framebuffer model for testing
    type fb_model_type is array (0 to 76799) of std_logic_vector(11 downto 0);
    signal fb_model : fb_model_type := (others => (others => '0'));

    -- Test control
    signal sim_done : boolean := false;
    signal pixel_count : integer := 0;
    signal px_count_reset : std_logic := '0';

    -- Helper: pack splat data
    function pack_splat(cx, cy, rad, r, g, b, alpha : integer) return std_logic_vector is
        variable result : std_logic_vector(63 downto 0) := (others => '0');
    begin
        result(63 downto 54) := std_logic_vector(to_unsigned(cx, 10));
        result(53 downto 45) := std_logic_vector(to_unsigned(cy, 9));
        result(44 downto 38) := std_logic_vector(to_unsigned(rad, 7));
        result(37 downto 34) := std_logic_vector(to_unsigned(r, 4));
        result(33 downto 30) := std_logic_vector(to_unsigned(g, 4));
        result(29 downto 26) := std_logic_vector(to_unsigned(b, 4));
        result(25 downto 18) := std_logic_vector(to_unsigned(alpha, 8));
        return result;
    end function;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    -- Gaussian LUT instance
    u_lut : entity work.gaussian_lut
    port map (
        clk     => clk,
        d2_norm => lut_d2_norm,
        weight  => lut_weight
    );

    -- Rasterizer instance
    u_rast : entity work.splat_rasterizer
    port map (
        clk          => clk,
        reset        => reset,
        start        => rast_start,
        done         => rast_done,
        busy         => rast_busy,
        splat_data   => rast_splat_data,
        lut_d2_norm  => lut_d2_norm,
        lut_weight   => lut_weight,
        px_valid     => px_valid,
        px_x         => px_x,
        px_y         => px_y,
        px_r         => px_r,
        px_g         => px_g,
        px_b         => px_b,
        px_eff_alpha => px_eff_alpha
    );

    -- Alpha blender instance
    u_blend : entity work.alpha_blender
    port map (
        clk          => clk,
        reset        => reset,
        px_valid     => px_valid,
        px_x         => px_x,
        px_y         => px_y,
        px_r         => px_r,
        px_g         => px_g,
        px_b         => px_b,
        px_eff_alpha => px_eff_alpha,
        fb_addr      => blend_fb_addr,
        fb_din       => blend_fb_din,
        fb_dout      => blend_fb_dout,
        fb_we        => blend_fb_we,
        busy         => blend_busy
    );

    -- Simple framebuffer model
    process(clk)
        variable addr_int : integer;
    begin
        if rising_edge(clk) then
            addr_int := to_integer(unsigned(blend_fb_addr));
            if addr_int < 76800 then
                blend_fb_dout <= fb_model(addr_int);
                if blend_fb_we = '1' then
                    fb_model(addr_int) <= blend_fb_din;
                end if;
            end if;
        end if;
    end process;

    -- Pixel counter
    process(clk)
    begin
        if rising_edge(clk) then
            if px_count_reset = '1' then
                pixel_count <= 0;
            elsif px_valid = '1' then
                pixel_count <= pixel_count + 1;
            end if;
        end if;
    end process;

    -- Stimulus
    stim_proc : process
    begin
        -- Reset
        reset <= '1';
        wait for 100 ns;
        reset <= '0';
        wait for 50 ns;

        -------------------------------------------------
        -- Test 1: Small red circle at center (160, 120), radius=10
        -------------------------------------------------
        report "Test 1: Red circle r=10 at (160,120)";
        rast_splat_data <= pack_splat(160, 120, 10, 15, 0, 0, 200);
        wait for CLK_PERIOD;
        rast_start <= '1';
        wait for CLK_PERIOD;
        rast_start <= '0';

        -- Wait for done
        wait until rast_done = '1' for 100 us;
        assert rast_done = '1'
            report "Test 1: rasterizer did not finish"
            severity error;

        -- Wait for blender to drain
        wait for 100 ns;
        report "Test 1 done. Pixels emitted: " & integer'image(pixel_count);

        -- Expected pixels: ~pi * 10^2 = ~314 (inside circle)
        assert pixel_count > 200 and pixel_count < 400
            report "Test 1: unexpected pixel count"
            severity warning;

        px_count_reset <= '1'; wait for CLK_PERIOD; px_count_reset <= '0';
        wait for 200 ns;

        -------------------------------------------------
        -- Test 2: Green circle overlapping (170, 125), radius=10
        -------------------------------------------------
        report "Test 2: Green circle r=10 at (170,125) overlapping";
        rast_splat_data <= pack_splat(170, 125, 10, 0, 15, 0, 180);
        wait for CLK_PERIOD;
        rast_start <= '1';
        wait for CLK_PERIOD;
        rast_start <= '0';

        wait until rast_done = '1' for 100 us;
        assert rast_done = '1'
            report "Test 2: rasterizer did not finish"
            severity error;

        wait for 100 ns;
        report "Test 2 done. Pixels emitted: " & integer'image(pixel_count);

        -------------------------------------------------
        -- Test 3: Large blue circle at edge (0, 0), radius=30
        -- Tests boundary clamping
        -------------------------------------------------
        px_count_reset <= '1'; wait for CLK_PERIOD; px_count_reset <= '0';
        wait for 200 ns;

        report "Test 3: Blue circle r=30 at (0,0) - boundary test";
        rast_splat_data <= pack_splat(0, 0, 30, 0, 0, 15, 255);
        wait for CLK_PERIOD;
        rast_start <= '1';
        wait for CLK_PERIOD;
        rast_start <= '0';

        wait until rast_done = '1' for 500 us;
        assert rast_done = '1'
            report "Test 3: rasterizer did not finish"
            severity error;

        wait for 100 ns;
        report "Test 3 done. Pixels emitted: " & integer'image(pixel_count);

        -- Quarter circle at corner: ~pi*30^2/4 = ~707
        assert pixel_count > 500 and pixel_count < 900
            report "Test 3: unexpected pixel count (boundary)"
            severity warning;

        wait for 500 ns;
        report "All tests passed.";
        sim_done <= true;
        wait;
    end process;

end Behavioral;
