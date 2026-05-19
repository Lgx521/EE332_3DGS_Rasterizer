----------------------------------------------------------------------------------
-- alpha_blender.vhd
-- Alpha blending module: reads old pixel from framebuffer, blends with
-- incoming splat color, writes back.
-- Back-to-front (over) blending:
--   C_new = C_old * (1 - eff_alpha/256) + color * (eff_alpha/256)
-- Per channel, 4-bit storage, 8-bit intermediate precision.
--
-- 3-cycle pipeline:
--   Cycle 0: request read from framebuffer (addr)
--   Cycle 1: framebuffer data available, compute blend
--   Cycle 2: write blended result back to framebuffer
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity alpha_blender is
    Port (
        clk          : in  STD_LOGIC;
        reset        : in  STD_LOGIC;

        -- Pixel input from rasterizer
        px_valid     : in  STD_LOGIC;
        px_x         : in  STD_LOGIC_VECTOR(8 downto 0);
        px_y         : in  STD_LOGIC_VECTOR(7 downto 0);
        px_r         : in  STD_LOGIC_VECTOR(3 downto 0);
        px_g         : in  STD_LOGIC_VECTOR(3 downto 0);
        px_b         : in  STD_LOGIC_VECTOR(3 downto 0);
        px_eff_alpha : in  STD_LOGIC_VECTOR(7 downto 0);

        -- Framebuffer interface
        fb_addr      : out STD_LOGIC_VECTOR(16 downto 0);
        fb_din       : out STD_LOGIC_VECTOR(11 downto 0);
        fb_dout      : in  STD_LOGIC_VECTOR(11 downto 0);
        fb_we        : out STD_LOGIC;

        -- Status
        busy         : out STD_LOGIC
    );
end alpha_blender;

architecture Behavioral of alpha_blender is

    constant FB_WIDTH : integer := 320;

    -- Pipeline stage 0: read request
    signal s0_valid   : std_logic := '0';
    signal s0_addr    : unsigned(16 downto 0);
    signal s0_r, s0_g, s0_b : unsigned(3 downto 0);
    signal s0_alpha   : unsigned(7 downto 0);

    -- Pipeline stage 1: blend computation
    signal s1_valid   : std_logic := '0';
    signal s1_addr    : unsigned(16 downto 0);
    signal s1_r, s1_g, s1_b : unsigned(3 downto 0);
    signal s1_alpha   : unsigned(7 downto 0);

    -- Pipeline stage 2: write back
    signal s2_valid   : std_logic := '0';
    signal s2_addr    : unsigned(16 downto 0);
    signal s2_data    : std_logic_vector(11 downto 0);

    -- Helper: blend one 4-bit channel
    -- result = (old * (256 - alpha) + new * alpha) >> 8
    -- old_c, new_c: 4-bit; alpha: 8-bit
    -- Max value: 15*256 + 15*255 = 7665, needs 13 bits
    function blend_ch(old_c, new_c : unsigned(3 downto 0);
                      alpha : unsigned(7 downto 0)) return unsigned is
        variable inv_a   : unsigned(8 downto 0);  -- 256 - alpha (9 bits)
        variable term_a  : unsigned(12 downto 0); -- old_c * inv_a (4+9=13 bits)
        variable term_b  : unsigned(11 downto 0); -- new_c * alpha (4+8=12 bits)
        variable blend   : unsigned(12 downto 0);
    begin
        inv_a  := to_unsigned(256, 9) - resize(alpha, 9);
        term_a := old_c * inv_a;           -- 4-bit * 9-bit = 13-bit
        term_b := new_c * alpha;           -- 4-bit * 8-bit = 12-bit
        blend  := term_a + resize(term_b, 13);
        -- >> 8 to get 4-bit result
        return blend(11 downto 8);
    end function;

begin

    busy <= s0_valid or s1_valid or s2_valid;

    process(clk, reset)
        variable addr_v : unsigned(16 downto 0);
        variable old_r, old_g, old_b : unsigned(3 downto 0);
        variable blend_r, blend_g, blend_b : unsigned(3 downto 0);
    begin
        if reset = '1' then
            s0_valid <= '0';
            s1_valid <= '0';
            s2_valid <= '0';
            fb_we    <= '0';

        elsif rising_edge(clk) then

            fb_we <= '0';

            -- ===== Stage 2: Write blended pixel to framebuffer =====
            if s2_valid = '1' then
                fb_addr <= std_logic_vector(s2_addr);
                fb_din  <= s2_data;
                fb_we   <= '1';
                s2_valid <= '0';
            end if;

            -- ===== Stage 1: Compute blend =====
            if s1_valid = '1' then
                -- fb_dout is now valid (read in stage 0)
                old_r := unsigned(fb_dout(11 downto 8));
                old_g := unsigned(fb_dout(7 downto 4));
                old_b := unsigned(fb_dout(3 downto 0));

                blend_r := blend_ch(old_r, s1_r, s1_alpha);
                blend_g := blend_ch(old_g, s1_g, s1_alpha);
                blend_b := blend_ch(old_b, s1_b, s1_alpha);

                s2_data  <= std_logic_vector(blend_r) &
                            std_logic_vector(blend_g) &
                            std_logic_vector(blend_b);
                s2_addr  <= s1_addr;
                s2_valid <= '1';
                s1_valid <= '0';
            end if;

            -- ===== Stage 0: Request framebuffer read =====
            if s0_valid = '1' then
                fb_addr <= std_logic_vector(s0_addr);
                -- Data will be available next cycle
                s1_valid <= '1';
                s1_addr  <= s0_addr;
                s1_r     <= s0_r;
                s1_g     <= s0_g;
                s1_b     <= s0_b;
                s1_alpha <= s0_alpha;
                s0_valid <= '0';
            end if;

            -- ===== Input latch =====
            if px_valid = '1' then
                -- Compute linear address: y * 320 + x
                addr_v := resize(unsigned(px_y) * to_unsigned(FB_WIDTH, 9), 17)
                        + resize(unsigned(px_x), 17);
                s0_addr  <= addr_v;
                s0_r     <= unsigned(px_r);
                s0_g     <= unsigned(px_g);
                s0_b     <= unsigned(px_b);
                s0_alpha <= unsigned(px_eff_alpha);
                s0_valid <= '1';
            end if;

        end if;
    end process;

end Behavioral;
