----------------------------------------------------------------------------------
-- render_controller.vhd
-- Master render state machine controlling the per-frame rendering pipeline.
-- FSM: IDLE -> CLEAR_FB -> RENDER_SPLATS -> WAIT_DONE -> SWAP -> IDLE
-- Drives splat_rom addressing and rasterizer start signals.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity render_controller is
    Port (
        clk           : in  STD_LOGIC;
        reset         : in  STD_LOGIC;

        -- Trigger new frame (e.g., from vsync)
        frame_trigger : in  STD_LOGIC;

        -- Splat ROM interface
        splat_addr    : out STD_LOGIC_VECTOR(12 downto 0);
        splat_data    : in  STD_LOGIC_VECTOR(63 downto 0);
        num_splats    : in  STD_LOGIC_VECTOR(12 downto 0);

        -- Rasterizer control
        rast_start    : out STD_LOGIC;
        rast_done     : in  STD_LOGIC;
        rast_busy     : in  STD_LOGIC;
        rast_splat    : out STD_LOGIC_VECTOR(63 downto 0);

        -- Framebuffer clear interface
        fb_clear_addr : out STD_LOGIC_VECTOR(16 downto 0);
        fb_clear_data : out STD_LOGIC_VECTOR(11 downto 0);
        fb_clear_we   : out STD_LOGIC;

        -- Buffer swap
        fb_swap       : out STD_LOGIC;

        -- Mux control: '0' = clear/render uses FB, '1' = blender uses FB
        render_active : out STD_LOGIC;

        -- Status
        rendering     : out STD_LOGIC;
        frame_count   : out STD_LOGIC_VECTOR(7 downto 0)
    );
end render_controller;

architecture Behavioral of render_controller is

    constant FB_SIZE : integer := 76800; -- 320 * 240

    type state_type is (S_IDLE, S_CLEAR, S_LOAD_SPLAT, S_WAIT_ROM,
                        S_START_RAST, S_WAIT_RAST, S_NEXT_SPLAT,
                        S_SWAP, S_DONE);
    signal state : state_type := S_IDLE;

    signal clear_addr_cnt : unsigned(16 downto 0) := (others => '0');
    signal splat_idx      : unsigned(12 downto 0) := (others => '0');
    signal num_splats_reg : unsigned(12 downto 0) := (others => '0');
    signal frame_cnt      : unsigned(7 downto 0) := (others => '0');

begin

    rendering   <= '0' when state = S_IDLE or state = S_DONE else '1';
    frame_count <= std_logic_vector(frame_cnt);

    process(clk, reset)
    begin
        if reset = '1' then
            state          <= S_IDLE;
            clear_addr_cnt <= (others => '0');
            splat_idx      <= (others => '0');
            frame_cnt      <= (others => '0');
            fb_clear_we    <= '0';
            fb_swap        <= '0';
            rast_start     <= '0';
            render_active  <= '0';

        elsif rising_edge(clk) then

            -- Default: clear pulses
            fb_clear_we   <= '0';
            fb_swap       <= '0';
            rast_start    <= '0';

            case state is

                when S_IDLE =>
                    render_active <= '0';
                    if frame_trigger = '1' then
                        num_splats_reg <= unsigned(num_splats);
                        state <= S_CLEAR;
                        clear_addr_cnt <= (others => '0');
                    end if;

                when S_CLEAR =>
                    -- Clear framebuffer to black, one pixel per clock
                    render_active <= '0';
                    fb_clear_addr <= std_logic_vector(clear_addr_cnt);
                    fb_clear_data <= (others => '0'); -- black
                    fb_clear_we   <= '1';

                    if clear_addr_cnt = FB_SIZE - 1 then
                        state     <= S_LOAD_SPLAT;
                        splat_idx <= (others => '0');
                    else
                        clear_addr_cnt <= clear_addr_cnt + 1;
                    end if;

                when S_LOAD_SPLAT =>
                    -- Check if we've processed all splats
                    render_active <= '1';
                    if splat_idx >= num_splats_reg then
                        state <= S_SWAP;
                    else
                        -- Request splat data from ROM
                        splat_addr <= std_logic_vector(splat_idx);
                        state <= S_WAIT_ROM;
                    end if;

                when S_WAIT_ROM =>
                    -- Wait 1 cycle for ROM read latency
                    render_active <= '1';
                    state <= S_START_RAST;

                when S_START_RAST =>
                    -- Pass splat data to rasterizer and start it
                    render_active <= '1';
                    rast_splat <= splat_data;
                    rast_start <= '1';
                    state <= S_WAIT_RAST;

                when S_WAIT_RAST =>
                    -- Wait for rasterizer to finish this splat
                    render_active <= '1';
                    if rast_done = '1' then
                        state <= S_NEXT_SPLAT;
                    end if;

                when S_NEXT_SPLAT =>
                    render_active <= '1';
                    splat_idx <= splat_idx + 1;
                    state <= S_LOAD_SPLAT;

                when S_SWAP =>
                    -- Swap display/render buffers
                    fb_swap <= '1';
                    frame_cnt <= frame_cnt + 1;
                    state <= S_DONE;

                when S_DONE =>
                    state <= S_IDLE;

                when others =>
                    state <= S_IDLE;

            end case;

        end if;
    end process;

end Behavioral;
