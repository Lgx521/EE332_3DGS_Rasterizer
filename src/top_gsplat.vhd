----------------------------------------------------------------------------------
-- top_gsplat.vhd
-- Top-level module for FPGA Gaussian Splatting renderer
-- Target: Nexys4 DDR (Artix-7 XC7A100T)
-- Connects: clk_gen, vga_timing, vga_controller, framebuffer,
--           splat_rom, splat_rasterizer, gaussian_lut, alpha_blender,
--           render_controller
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top_gsplat is
    Port (
        CLK100MHZ  : in  STD_LOGIC;
        CPU_RESETN : in  STD_LOGIC;
        BTNC       : in  STD_LOGIC;
        BTNU       : in  STD_LOGIC;
        BTND       : in  STD_LOGIC;
        BTNL       : in  STD_LOGIC;
        BTNR       : in  STD_LOGIC;
        SW         : in  STD_LOGIC_VECTOR(1 downto 0);
        LED        : out STD_LOGIC_VECTOR(3 downto 0);
        VGA_R      : out STD_LOGIC_VECTOR(3 downto 0);
        VGA_G      : out STD_LOGIC_VECTOR(3 downto 0);
        VGA_B      : out STD_LOGIC_VECTOR(3 downto 0);
        VGA_HS     : out STD_LOGIC;
        VGA_VS     : out STD_LOGIC
    );
end top_gsplat;

architecture Behavioral of top_gsplat is

    -- Clock and reset
    signal clk_sys    : std_logic; -- 100 MHz (same as CLK100MHZ, after BUFG)
    signal clk_pix    : std_logic; -- 25 MHz
    signal pll_locked : std_logic;
    signal reset_sys  : std_logic; -- active-high synchronous reset (sys clk domain)
    signal reset_pix  : std_logic; -- active-high synchronous reset (pix clk domain)

    -- Reset synchronizer
    signal reset_sync_sys : std_logic_vector(2 downto 0) := "111";
    signal reset_sync_pix : std_logic_vector(2 downto 0) := "111";

    -- VGA timing signals
    signal h_count      : std_logic_vector(9 downto 0);
    signal v_count      : std_logic_vector(9 downto 0);
    signal h_sync       : std_logic;
    signal v_sync       : std_logic;
    signal video_active : std_logic;
    signal frame_start  : std_logic;

    -- Framebuffer Port A (render engine, sys_clk domain)
    signal fb_a_we   : std_logic;
    signal fb_a_addr : std_logic_vector(16 downto 0);
    signal fb_a_din  : std_logic_vector(11 downto 0);
    signal fb_a_dout : std_logic_vector(11 downto 0);

    -- Framebuffer Port B (VGA display, pix_clk domain)
    signal fb_b_addr : std_logic_vector(16 downto 0);
    signal fb_b_dout : std_logic_vector(11 downto 0);

    -- Framebuffer swap
    signal fb_swap : std_logic;

    -- Render controller signals
    signal rc_fb_clear_addr : std_logic_vector(16 downto 0);
    signal rc_fb_clear_data : std_logic_vector(11 downto 0);
    signal rc_fb_clear_we   : std_logic;
    signal rc_render_active : std_logic;
    signal rc_rendering     : std_logic;
    signal rc_frame_count   : std_logic_vector(7 downto 0);
    signal rc_rast_start    : std_logic;
    signal rc_rast_splat    : std_logic_vector(63 downto 0);

    -- Splat ROM signals
    signal splat_addr : std_logic_vector(12 downto 0);
    signal splat_data : std_logic_vector(63 downto 0);
    signal num_splats : std_logic_vector(12 downto 0);

    -- Rasterizer signals
    signal rast_done     : std_logic;
    signal rast_busy     : std_logic;
    signal rast_px_valid : std_logic;
    signal rast_px_x     : std_logic_vector(8 downto 0);
    signal rast_px_y     : std_logic_vector(7 downto 0);
    signal rast_px_r     : std_logic_vector(3 downto 0);
    signal rast_px_g     : std_logic_vector(3 downto 0);
    signal rast_px_b     : std_logic_vector(3 downto 0);
    signal rast_px_alpha : std_logic_vector(7 downto 0);
    signal lut_d2_norm   : std_logic_vector(7 downto 0);
    signal lut_weight    : std_logic_vector(7 downto 0);

    -- Blender signals
    signal blend_fb_addr : std_logic_vector(16 downto 0);
    signal blend_fb_din  : std_logic_vector(11 downto 0);
    signal blend_fb_we   : std_logic;
    signal blend_busy    : std_logic;

    -- Frame trigger (cross-domain sync from pix_clk to sys_clk)
    signal frame_start_sync : std_logic_vector(2 downto 0) := "000";
    signal frame_trigger    : std_logic;

    -- Viewport pan offset from camera_controller
    signal pan_x : std_logic_vector(10 downto 0);
    signal pan_y : std_logic_vector(10 downto 0);

begin

    -- Use CLK100MHZ directly as sys clock
    clk_sys <= CLK100MHZ;

    --=========================================================================
    -- Clock Generation
    --=========================================================================
    u_clk_gen : entity work.clk_gen
    port map (
        clk_100m => CLK100MHZ,
        resetn   => CPU_RESETN,
        clk_25m  => clk_pix,
        locked   => pll_locked
    );

    --=========================================================================
    -- Reset synchronizers
    --=========================================================================
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            reset_sync_sys <= reset_sync_sys(1 downto 0) & (not CPU_RESETN or not pll_locked);
        end if;
    end process;
    reset_sys <= reset_sync_sys(2);

    process(clk_pix)
    begin
        if rising_edge(clk_pix) then
            reset_sync_pix <= reset_sync_pix(1 downto 0) & (not CPU_RESETN or not pll_locked);
        end if;
    end process;
    reset_pix <= reset_sync_pix(2);

    --=========================================================================
    -- VGA Timing Generator (25 MHz domain)
    --=========================================================================
    u_vga_timing : entity work.vga_timing
    port map (
        pix_clk     => clk_pix,
        reset       => reset_pix,
        h_count     => h_count,
        v_count     => v_count,
        h_sync      => h_sync,
        v_sync      => v_sync,
        video_active=> video_active,
        frame_start => frame_start
    );

    --=========================================================================
    -- Frame start synchronizer (pix_clk -> sys_clk)
    --=========================================================================
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            frame_start_sync <= frame_start_sync(1 downto 0) & frame_start;
        end if;
    end process;
    -- Rising edge detect
    frame_trigger <= frame_start_sync(1) and not frame_start_sync(2);

    --=========================================================================
    -- Framebuffer (dual-port, dual-clock)
    --=========================================================================
    u_framebuffer : entity work.framebuffer
    port map (
        clk_a    => clk_sys,
        we_a     => fb_a_we,
        addr_a   => fb_a_addr,
        din_a    => fb_a_din,
        dout_a   => fb_a_dout,
        clk_b    => clk_pix,
        addr_b   => fb_b_addr,
        dout_b   => fb_b_dout,
        swap     => fb_swap,
        clk_swap => clk_sys
    );

    --=========================================================================
    -- VGA Controller (25 MHz domain)
    --=========================================================================
    u_vga_ctrl : entity work.vga_controller
    port map (
        pix_clk      => clk_pix,
        reset        => reset_pix,
        h_count      => h_count,
        v_count      => v_count,
        video_active => video_active,
        h_sync_in    => h_sync,
        v_sync_in    => v_sync,
        fb_addr      => fb_b_addr,
        fb_data      => fb_b_dout,
        vga_r        => VGA_R,
        vga_g        => VGA_G,
        vga_b        => VGA_B,
        vga_hs       => VGA_HS,
        vga_vs       => VGA_VS
    );

    --=========================================================================
    -- Splat ROM
    --=========================================================================
    u_splat_rom : entity work.splat_rom
    generic map (
        NUM_SPLATS => 5,
        MEM_FILE   => "test_splats.mem"
    )
    port map (
        clk        => clk_sys,
        addr       => splat_addr,
        splat_data => splat_data,
        num_total  => num_splats
    );

    --=========================================================================
    -- Gaussian Weight LUT
    --=========================================================================
    u_gaussian_lut : entity work.gaussian_lut
    port map (
        clk     => clk_sys,
        d2_norm => lut_d2_norm,
        weight  => lut_weight
    );

    --=========================================================================
    -- Camera Controller (button debounce + pan offset)
    --=========================================================================
    u_cam_ctrl : entity work.camera_controller
    port map (
        clk        => clk_sys,
        reset      => reset_sys,
        btn_u      => BTNU,
        btn_d      => BTND,
        btn_l      => BTNL,
        btn_r      => BTNR,
        btn_c      => BTNC,
        frame_tick => frame_trigger,
        pan_x      => pan_x,
        pan_y      => pan_y
    );

    --=========================================================================
    -- Splat Rasterizer
    --=========================================================================
    u_rasterizer : entity work.splat_rasterizer
    port map (
        clk          => clk_sys,
        reset        => reset_sys,
        start        => rc_rast_start,
        done         => rast_done,
        busy         => rast_busy,
        splat_data   => rc_rast_splat,
        pan_x        => pan_x,
        pan_y        => pan_y,
        lut_d2_norm  => lut_d2_norm,
        lut_weight   => lut_weight,
        px_valid     => rast_px_valid,
        px_x         => rast_px_x,
        px_y         => rast_px_y,
        px_r         => rast_px_r,
        px_g         => rast_px_g,
        px_b         => rast_px_b,
        px_eff_alpha => rast_px_alpha
    );

    --=========================================================================
    -- Alpha Blender
    --=========================================================================
    u_blender : entity work.alpha_blender
    port map (
        clk          => clk_sys,
        reset        => reset_sys,
        px_valid     => rast_px_valid,
        px_x         => rast_px_x,
        px_y         => rast_px_y,
        px_r         => rast_px_r,
        px_g         => rast_px_g,
        px_b         => rast_px_b,
        px_eff_alpha => rast_px_alpha,
        fb_addr      => blend_fb_addr,
        fb_din       => blend_fb_din,
        fb_dout      => fb_a_dout,
        fb_we        => blend_fb_we,
        busy         => blend_busy
    );

    --=========================================================================
    -- Render Controller
    --=========================================================================
    u_render_ctrl : entity work.render_controller
    port map (
        clk           => clk_sys,
        reset         => reset_sys,
        frame_trigger => frame_trigger,
        splat_addr    => splat_addr,
        splat_data    => splat_data,
        num_splats    => num_splats,
        rast_start    => rc_rast_start,
        rast_done     => rast_done,
        rast_busy     => rast_busy,
        rast_splat    => rc_rast_splat,
        fb_clear_addr => rc_fb_clear_addr,
        fb_clear_data => rc_fb_clear_data,
        fb_clear_we   => rc_fb_clear_we,
        fb_swap       => fb_swap,
        render_active => rc_render_active,
        rendering     => rc_rendering,
        frame_count   => rc_frame_count
    );

    --=========================================================================
    -- Framebuffer Port A Mux
    -- When render_active='0': render controller clears the framebuffer
    -- When render_active='1': alpha blender reads/writes the framebuffer
    --=========================================================================
    fb_a_addr <= blend_fb_addr when rc_render_active = '1' else rc_fb_clear_addr;
    fb_a_din  <= blend_fb_din  when rc_render_active = '1' else rc_fb_clear_data;
    fb_a_we   <= blend_fb_we   when rc_render_active = '1' else rc_fb_clear_we;

    --=========================================================================
    -- LED Status
    --=========================================================================
    LED(0) <= pll_locked;
    LED(1) <= rc_rendering;
    LED(2) <= rc_frame_count(0);  -- toggles each frame
    LED(3) <= SW(0);              -- echo switch for debug

end Behavioral;
