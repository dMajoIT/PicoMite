# Plan: 640x1024 @ 75 Hz on the HDMI builds

**ABANDONED 2026-09-15.** The TMDS clock lane is the pixel clock, so a
half-width 640x1024 signal is a 67.8 MHz timing that appears in no monitor's
mode table; whether a scaler shows it is luck, not design. A true 1280-wide
timing is out of reach: HSTX sends 10 bits per pixel per lane at 2 bits per
clock, so pixel clock = clk_hstx / 5, at most 75.6 MHz at the 378 MHz ceiling,
against 135 MHz for 1280x1024@75 and 91 MHz even for 1280x1024@60 reduced
blanking. Kept for the parts that transfer to any future 320x256 mode:
section 3b (compute a row once, let the DMA repeat it), section 3a (tile
sizing must follow the mode height, not the scanout height) and section 4
(pool arithmetic for 320x256 modes 2 and 5).

Status: plan only, nothing implemented. Written 2026-09-14 against the code on
main at 40516db. Applies to HDMI, HDMIUSB (full) and HDMIBTH, HDMIWEB
(HDMICUTDOWN).

## 1. Target

Monitor mode: VESA 1280x1024 @ 75 Hz (135 MHz pixel clock). HSTX cannot do
675 MHz, so the firmware drives half the horizontal pixels with all horizontal
counts halved and the same vertical timing. The monitor sees a 640x1024 signal
with the 1280x1024@75 line and frame rates.

| Part            | VESA 1280x1024@75 | Halved (what HSTX sends) |
|-----------------|-------------------|--------------------------|
| H active        | 1280              | 640                      |
| H front porch   | 16                | 8                        |
| H sync          | 144               | 72                       |
| H back porch    | 248               | 124                      |
| H total         | 1688              | 844                      |
| V active        | 1024              | 1024                     |
| V front porch   | 1                 | 1                        |
| V sync          | 3                 | 3                        |
| V back porch    | 38                | 38                       |
| V total         | 1066              | 1066                     |
| Sync polarity   | H +, V +          | same (informational only, the HSTX sync words are fixed for every resolution) |

BASIC-visible modes (all RGB332 into HSTX, PIXELS_PER_WORD = 4, exactly like
1024x768 and 1024x600):

| MODE | Geometry     | Depth | Output scaling        | Bytes per surface |
|------|--------------|-------|-----------------------|-------------------|
| 1    | 640x512      | 1-bit + 8x12 colour tiles | 1x H, 2x V | 40960 + tiles 10240 |
| 2    | 320x256      | 4-bit | 2x H, 4x V            | 40960             |
| 5    | 320x256      | 8-bit | 2x H, 4x V            | 81920             |
| 3, 4 | not offered  |       |                       | MODE3SIZE = MODE4SIZE = 0 |

## 2. Clock: 339 MHz (decided)

The pixel clock is clk_hstx / 5, so 67.5 MHz would need clk_hstx = 337.5 MHz,
which has no integer PLL solution. 338 is reachable only with the PLL
reference divider at 2 (VCO 1014 = 6 MHz x 169); Peter tried it and it does
not work, so the clock is **339000 with clk_hstx = clk_sys (divider 1)**:

| clk_sys | REFDIV | FBDIV | PD1 | PD2 | VCO MHz | Pixel MHz | Line kHz | Frame Hz |
|---------|--------|-------|-----|-----|---------|-----------|----------|----------|
| 339     | 1      | 113   | 4   | 1   | 1356    | 67.8      | 80.33    | 75.36    |

339 uses the SDK's default reference divider, so `check_sys_clock_khz`
(boot and `CPUSpeedRuntime`) accepts it with no build or clock-code change.
Core voltage 1.60 V (above 320 MHz) and QMI CLKDIV=4 (above 288 MHz) apply as
they already do for 360/375/378. The refresh is 0.34 Hz above the VESA
nominal 75.025; a fractional clk_hstx divider from a higher clk_sys (the
x0.332 trick of 640x480@378) could hit 67.5 exactly but would add divider
jitter on an 80 kHz line, so it is not used.

Define the speed as its own name (`FreqSXGA 339000`) rather than sharing an
existing one.

## 3. The two things that make this resolution different

### 3a. Mode 1 is half the output height

Every existing resolution has mode 1 equal to the scanout geometry, and two
places rely on that by sizing the tile-colour arrays and Y_TILE from
`MODE_V_ACTIVE_LINES`:

- `settiles()` in graphics/HDMI.c (non-FullColour branch)
- the editor's exit repaint block in misc/Editor.c (~line 6950), which is a
  copy of settiles

Here the scanout is 1024 lines but mode 1 is 512 rows. Using the output height
would over-allocate the tile arrays (2 x 80 x 128 = 20480 instead of 10240) and
set Y_TILE = 85 instead of 42. It is not unsafe (the loop indexes tiles by
framebuffer row and the arrays are memset), but it wastes 10 KB of pool and is
a trap. Fix: in both places use `HRes` / `VRes` instead of
`MODE_H_ACTIVE_PIXELS` / `MODE_V_ACTIVE_LINES`. In mode 1 those are identical
for every existing resolution (ResetDisplay sets HRes/VRes before it calls
settiles, and the editor block runs after ResetDisplay), so this is a
behaviour-preserving change everywhere else.

Y_TILE = 512 / 12 = 42 leaves an 8-pixel partial tile row at the bottom that
text never reaches. 720x400x8 already has the same situation (400 / 12) and is
fine.

### 3b. The line rate is 80 kHz, twice the current fastest

Line period = 844 px / 67.8 MHz = 12.45 us = 4220 core1 cycles (5 x 844,
independent of which clock is chosen since clk_sys = 5 x pixel clock), with
two DMA IRQs inside it. The existing loops recompute every output line,
including the vertically replicated modes (HDMIloopX mode 2/5 do the 4x lines
by recomputing). Estimated per-line cost if this resolution does the same:

| Mode | Work per output line               | Est. cycles | Budget share | Reference (existing) |
|------|------------------------------------|-------------|--------------|----------------------|
| 1    | 80 tile bytes x 8 px               | ~2700       | ~64 %        | 1024x768 mode 1 ~48 % |
| 2    | 160 source bytes, 3 layers, 2 px each | ~2900    | ~69 %        | 1024x600 mode 2 ~50 % |
| 5    | 320 source bytes, 3 layers, 2 px each | ~3500 to 3800 | ~83 to 91 % | 1024x600 mode 5 ~53 %, 640x480x8 mode 5 ~30 % |

These are hand estimates, not measurements, but mode 5 has no safe margin and
every mode is tighter than anything that exists. Since every framebuffer row is
sent twice, the fix is to compute each row once and let the DMA send the same
line buffer twice:

- `dma_irq_handler0`: `HDMIlines[(v_scanline >> hdmi_line_shift) & 1]` with a
  new `hdmi_line_shift` set by HDMICore (0 for every existing resolution, 1
  for this one). One extra shift per IRQ on the shared hot path. **This is
  the one change outside the new resolution's own code, and it needs your OK.**
- The new loop acts only on odd `v_scanline` values: row = (v_scanline + 1 -
  BLANKING_COUNT) / 2, written into `HDMIlines[((v_scanline + 1) >> 1) & 1]`,
  valid for 0 <= row < 512. That buffer was last streamed two lines earlier
  and the deadline is the start of the row's first copy, two line periods
  away, so the budget doubles to 8440 cycles (mode 5 ~45 %, comparable to the
  1024x600 loop). Requires BLANKING_COUNT even (1 + 3 + 38 = 42, it is) and
  the handler and the loop sharing one buffer-index formula.

If you would rather not touch the handler, the fallback is the plain
recompute-every-line loop and a hardware test of mode 5; expect it to miss
lines.

Halving the loop work also halves core1's SRAM writes; DMA reads of HDMIlines
are 51 MB/s, below the 58 MB/s of 1024x768.

## 4. Memory: no pool change on any build

Pool allocation rules (graphics/FrameBuffer.c cmd_framebuffer): LAYER lands in
the pool if ScreenSize < pool/2, CREATE if ScreenSize < pool/3, LAYER TOP if
ScreenSize < pool/4, else GetMemory from the MMBasic heap (PSRAM rejected for
layers).

| Surface            | Full build, 153600 pool | Cutdown, 96000 pool |
|--------------------|-------------------------|---------------------|
| Mode 1 display + tiles | 51200 in pool       | 51200 in pool       |
| Mode 2 display     | 40960                   | 40960               |
| Mode 2 LAYER       | pool (40960 < 76800)    | pool (40960 < 48000) |
| Mode 2 CREATE      | pool (40960 < 51200)    | heap (40960 >= 32000) |
| Mode 2 LAYER TOP   | heap (40960 >= 38400), same as 640x480 today | heap |
| Mode 5 display     | 81920 in pool           | 81920 in pool       |
| Mode 5 LAYER       | heap (81920 >= 76800); 640x480 mode 5 is also heap today (76800 >= 76800) | heap (80 KB of a 136 KB heap on HDMIWEB) |
| Mode 5 CREATE / TOP| heap (mode 5 rule)      | heap                |

Consequences:

- No boot-time heap resize in main(), so no change to the `need` gate in the
  full build's cmd_resolution: the default `320*240*2` branch already covers
  it. The resolution is live-switchable in both directions on every build.
- The cutdown builds can offer all three modes (unlike 800x600 there, whose
  mode 5 overflows the pool).
- HDMIlines is `[2][848]` uint16 = 1696 bytes per line; a 640-byte RGB332 line
  fits. (HDMI.c declares the extern as `[2][800]`, harmless, pre-existing.)

## 5. Work items by file

Ordered so that each step compiles. "Both" = full and cutdown code paths.

### graphics/Screens.h
1. `#define FreqSXGA 339000`.
2. Enum: `R640x1024 = 13`, defined OUTSIDE the `#ifdef HDMICUTDOWN` block so
   the value is the same in every build (11 and 12 stay cutdown-only).
3. `CPUFreqs[]`: extend to 14 entries, padding indices 11 and 12 (never
   indexed by the cutdown, per the existing rule) and putting FreqSXGA at 13.
   The full build indexes this table from OPTION RESOLUTION, cmd_resolution
   and the factory default.
4. Add R640x1024 to `MediumRes` (gives tile height 12 and font 1 in mode 1,
   font 6 in modes 2/5, exactly like 1024x600). Both `MediumRes` variants.
5. Timing macros with a new suffix (say `_P`): `MODE_H_P_ACTIVE_PIXELS 640`,
   `MODE_V_P_ACTIVE_LINES 1024`, FP/sync/BP 8/72/124 and 1/3/38, polarity
   1/1, `MODE_H_P_TOTAL_PIXELS` / `MODE_V_P_TOTAL_LINES`.
6. Size macros: `MODE1SIZE_P = 640*512/8`, `MODE2SIZE_P = 320*256/2`,
   `MODE5SIZE_P = 320*256`. Note MODE1SIZE_P is NOT `MODE_H_P * MODE_V_P / 8`
   (the mode is half the output height), so write the 512 explicitly with a
   comment.
7. Comment update on FRAMEBUFFER_POOL_SIZE (still 96000, still sized by
   1024x600 mode 1).

### graphics/HDMI.c
8. New scanout loop, one function compiled in BOTH `#ifdef` arms (as
   HDMIloop3 is), `MIPS32 __not_in_flash_func`, hand-unrolled with the `_P`
   constants (no runtime vgaloopN). Structure = HDMIloop2 with the line-pair
   trigger from section 3b:
   - mode 1: source row = row, 80 bytes, `d = DisplayBuf | LayerBuf`, tile
     colours from `tilefcols_w + row / ytileheight * X_TILE`;
   - mode 2: source row = row >> 1, 160 bytes, three layers with the
     SecondLayer-aliases-DisplayBuf guard, `(uint16_t)map16quads[...]` for 2x
     horizontal (as HDMIloopBTH640);
   - mode 5: source row = row >> 1, 320 bytes, three layers, two bytes out per
     source byte (a 16-bit store of `c | c << 8` saves a cycle per pixel pair);
   - `hdmi_switch_pending` check per v_scanline change, as every loop.
   About 0.75 to 1.2 KB of RAM (HDMIloopBTH640 is 740 B, HDMIloop2 1164 B).
9. `dma_irq_handler0`: `hdmi_line_shift` (section 3b).
10. HDMICore dispatch: a new arm in both the cutdown and the full chain
    setting the 13 timing globals from `_P`, MODE1/2/5SIZE_P, MODE3SIZE =
    MODE4SIZE = 0, PIXELS_PER_WORD = 4, `hdmi_line_shift = 1` (and 0 in every
    other arm, or once before the chain).
11. clk_hstx derivation: the `else if (FullColour || (MediumRes &&
    Option.Resolution != R1024x600))` divide-by-2 branch must also exclude
    R640x1024 so it falls through to divider 1. Update the comment table.
12. Loop dispatch at the end of HDMICore: both arms route R640x1024 to the
    new loop.
13. `settiles()`: HRes/VRes instead of MODE_H/V (section 3a).
14. Teardown: nothing new; `hdmi_line_shift` is rewritten at setup.

### misc/Editor.c
15. The editor-exit tile block (~6950): HRes/VRes instead of MODE_H/V.

### graphics/Draw.c
16. `ResetDisplay()`: explicit branch inside `#ifdef HDMI` (next to R1024x600):
    HRes = mode 1 ? 640 : 320; VRes = mode 1 ? 512 : 256. Without it the
    generic fallthrough gives 640x480 / 320x240.
17. `setmode()`: reject modes 3 and 4 for R640x1024 in BOTH builds (the full
    build currently has no such guard because all its resolutions implement
    1/2/3/5). Same error text as the cutdown guards.
18. `cmd_resolution` (cutdown): keyword `640x1024`, no speed argument,
    `speed = FreqSXGA`. Test the `640x1024` keyword BEFORE `640` /
    `640x480` so the prefix can never shadow it.
19. `cmd_resolution` (full): keyword, `newres = R640x1024`; CPUFreqs[13]
    supplies the speed; `Option.DefaultFont` stays 1 via the existing
    ternary; `need` stays on the default branch.
20. `fun_getscanline()`: new branch `v_scanline - 42`, wrap 1066 (the
    function reports output lines; the row is that >> 1). Note in passing
    that 1024x600, 800x480 and 720x400 have no branch today and return an
    unset value; not this job.

### core/MM_Misc.c
21. OPTION RESOLUTION (cutdown): `640x1024` -> R640x1024, CPU_Speed = FreqSXGA,
    keyword tested before `640`; DefaultFont 1, DISPLAY_TYPE mode 1, save,
    reboot (existing tail).
22. OPTION RESOLUTION (full, inside `#ifdef HDMI`): `640x1024` -> R640x1024,
    DefaultFont 1; the tail's `CPUFreqs[Option.Resolution]` picks 336000.
23. OPTION LIST: `PO2StrInt("RESOLUTION", "640x1024", ...)` in both blocks.
24. OPTION DEFAULT MODE: reject 3 and 4 for R640x1024 in both builds (mirror
    of item 17, otherwise a bad mode is saved and applied at every boot).

### PicoMite.c
25. Boot pair validation, cutdown: add `(R640x1024 && CPU_Speed == FreqSXGA)`
    to the accepted list, else the pair is rewritten to factory on the reboot
    OPTION RESOLUTION triggers.
26. Boot validation, full: add R640x1024 to the accepted-resolution list (the
    full build otherwise resets CPU_Speed to 315000 while keeping the
    resolution, which would then run the 640x1024 timing at a 63 MHz pixel
    clock).
27. No heap resize block (section 4). `restartHDMI` unchanged. The comment
    in restartHDMI about the cutdown "both run at 252 MHz" is already stale.

### No change needed, checked
- MAP / MAP RESET / MAP GRAYSCALE / MAP MAXIMITE (cmd_map, fun_map): dispatch
  on DISPLAY_TYPE only and write map16quads / map256, which the new loop
  reads exactly as HDMIloop2 does.
- FRAMEBUFFER CREATE / CREATE 2 / LAYER / LAYER TOP / CLOSE / COPY / WRITE:
  driven by ScreenSize, framebuffersize and DISPLAY_TYPE (section 4).
- SPRITE, BLIT, TILEMAP, 3D, LOAD IMAGE, mouse pointer, on-screen keyboard,
  console geometry (SetFont -> Option.Height/Width): all HRes / VRes /
  ScreenSize based; none of graphics/Sprite.c, Blit.c, TileMap.c reference
  Option.Resolution.
- ReloadOptionsKeepLive, HDMIres, LiveCPUSpeed: resolution-agnostic.
- struct option_s: Resolution is an existing int field, no layout change, no
  MagicKey bump. OPTION DISK SAVE/LOAD carries the enum value; keeping 13 in
  every build keeps saved option files portable between HDMI variants.
- CMakeLists: nothing; the loop is in HDMI.c which every HDMI variant builds.
- Memory.c: pool sizes unchanged.

## 6. Build and verification order

Each phase is one build. Rig: the PC3 on COM4 (UPDATE FIRMWARE over serial).

Phase 1, monitor lock. Items 1 to 7, 10 to 13, 16, 18/19, 21/22 with the new
loop implementing mode 1 only. Boot with OPTION RESOLUTION 640x1024 and check
the monitor reports a 75 Hz (74.7) mode and shows an 80x42 console. This
proves the halved-horizontal timing on your monitor before any mode work. If
the monitor rejects 640x1024 the rest is moot.

Phase 2, modes 2 and 5 plus the guards (items 8 complete, 17, 24) and the
line-pair scheme (item 9). Test in each mode: text, BOX/CIRCLE at the edges
(0,0 and 319,255 / 639,511), FRAMEBUFFER LAYER + LAYER TOP with transparency,
FRAMEBUFFER CREATE + COPY, MAP colour changes, a SPRITE and a BLIT, the editor
(item 15 exercised by leaving EDIT), and the OSK if enabled.

Phase 3, switching. RESOLUTION 640x1024 from 640x480 and from 1024x768 and
back, each in mode 1 and mode 5; MODE 2 / MODE 5 inside it; deliberate BASIC
error while in it (the error-path option reload must not revert geometry);
OPTION DEFAULT MODE 5 then reboot; OPTION RESOLUTION 640x1024 then reboot
(item 25/26); MM.INFO(HRES)/(VRES) and MM.GETSCANLINE values. Then the same
on HDMIWEB (cutdown pool).

Phase 4, budget. After the first build of each variant check the link: the
new RAM-resident loop plus the flash for options can cross a 4 KB RAM page or
the FLASH_TARGET_OFFSET margin on HDMIWEB / HDMIUSB (see the heap-BSS overlap
and 16 KB flash step notes in memory). If core1 shows missed lines in mode 5
with the line-pair scheme in place, a GPIO toggle around the row compute on a
scope gives the real cycle count.

## 7. Documentation (after it works)

PicoMite_User_Manual.docx: MODE (resolution/mode table gains a row: 640x512
mode 1, 320x256 modes 2 and 5, no 3/4), OPTION RESOLUTION and RESOLUTION
(new keyword, fixed 336 MHz, live-switchable), OPTION DEFAULT MODE (3/4
rejected), FRAMEBUFFER memory notes (mode 5 LAYER comes from the heap, as for
640x480), the appendix table of resolutions vs CPU speed. Regenerate the PDF
with the Word-COM pipeline plus add_manual_bookmarks.py from docs/. Update the
HDMIWEB memory note (six resolutions -> seven) and the OPTION LIST examples.

## 8. Decisions needed

1. Clock: decided, 339000 (section 2).
2. Keyword: `640x1024` proposed; the signal is 640 wide so `1280x1024` would
   misdescribe it, but it is what the monitor's OSD will call the mode.
3. Approval to add `hdmi_line_shift` to `dma_irq_handler0` (section 3b). The
   alternative is a loop that recomputes every line and a hardware test of
   mode 5.
4. Approval for the settiles / Editor.c change to HRes/VRes (section 3a),
   which touches every HDMI resolution's mode-1 tile setup (behaviour
   preserving by construction, but shared code).
5. Enum value 13 with a padded CPUFreqs[] table, versus 11 in the full build
   only.
