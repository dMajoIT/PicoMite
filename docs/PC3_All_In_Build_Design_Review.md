# Pico Computer 3 all-in build: design review

Review of V7.00.00RC0 (main e33d080), 2026-10-11. The question: can one
build for the Pico Computer 3 carry WiFi, Bluetooth, the full HDMI pipeline
and the USB host, with a 256 KB program, the three flash slots, the five
RAM slots and the compiler space kept, by giving the MMBasic heap to PSRAM
and keeping the internal RAM for the framebuffers, the C stack and heap, and
the firmware's RAM-resident code and data?

Every number below is measured, not estimated: the three existing HDMI
variants were rebuilt from main with the release settings (Release, SDK
2.3.1, private Ninja build directories, Peter's `build/` untouched) and the
all-in variant was built the same way on the experiment branch `pc3-all`
(worktree `../pm_pc3`, commit 3b1418e). The experiment links and fits; it
has not been flashed or run.

## Summary

1. **Yes, as one more variant in this tree, not a separate code set.** The
   all-in build (`COMPILE=PC3`, sign-on `PicoMitePC3`) is HDMIWEB plus
   HDMIBTH on the full HDMI pipeline. It compiles from main with changes to
   five files, 70 lines, nearly all of them CMake lists. The two existing
   hybrids already carry every gate it needs; the only collisions are the
   identity sites (sign-on, `MM.DEVICE$`, the configuration budget, the
   cyw43 init), each a one-line `#if`.
2. **Flash is not the problem.** The image is 1722 KB. With the Route B flash
   stream dropped (this build has PSRAM by definition) a 256 KB program and
   three 256 KB flash slots end at 2772 KB, under the fixed map's 3 MB system
   top, so the MOD buffer stays at 3 MB and the A: drive at 4 MB, shared with
   every other RP2350 variant on a 16 MB board. The 16 KB flash steps leave
   300 KB of growth room before the system top moves.
3. **Internal RAM is the problem, and the numbers close.** Everything that is
   not the MMBasic heap takes 225 KB of the 520 KB (RAM code 81 KB, static
   data and BSS 144 KB, of which lwIP's packet pools are 52 KB and btstack's
   24 KB), plus 32 KB of C heap and stack budget and a 4 KB margin. That
   leaves 265 KB for the framebuffer pool and an SRAM heap together: with the
   full 150 KB pool (640x480 in all five modes, 720x400, 1024x768, 1280x720,
   1024x600) the SRAM heap is **108 KB**; at 800x480, 848x480 and 800x600
   with their bigger pools it is 72, 60 and 24 KB.
4. **"Heap exclusively in PSRAM" needs an SRAM pool anyway, so the design is
   a hybrid.** Three kinds of allocation cannot go to PSRAM: the variables'
   records (read on every variable reference), the buffers that interrupts
   and DMA write (COM ports, audio, ADC, PIO rings, the stepper, MEMORY SHARE)
   and the layer framebuffers core 1 scans. The second group is a correctness
   rule, not a speed preference: a flash write takes the whole QMI window
   down, PSRAM included, so an interrupt that reads a PSRAM buffer during
   SAVE or an A: write reads garbage or hangs. The recommended policy is
   therefore: records, temporaries, driver buffers and layers in the SRAM
   heap; every program-visible allocation (arrays, strings, the editor and
   LOAD buffers, TLS, JSON, blit and sprite buffers) in PSRAM. Today's
   allocator already does most of this by accident (anything over half the
   heap goes to PSRAM, and PSRAM takes the overflow); the change is to make
   it a rule and to give the driver buffers an allocator that refuses PSRAM.
5. **The open question is interpreter speed with all program data in PSRAM.**
   PSRAM reads go through the 16 KB XIP cache that the flash code and the
   compiled Route B stream also use. Big arrays already live there on every
   PSRAM build and the games run compiled from it, but small hot arrays and
   long strings do not. This has to be measured, not argued: the plan puts the
   allocation policy behind one compile-time switch so HDMIWEB can A/B it on
   the bench programs before the PC3 build depends on it.
6. **Gating out the irrelevant buys little.** What the PC3 cannot use is
   already out of the two hybrids (SPI panels, touch, VGA, PS/2, PicoCalc,
   VS1053, PWM audio). The remaining candidates (other boards' presets, the
   4 MB flash map, the PSRAM pin option and the 42 no-PSRAM fallbacks) are
   worth under 10 KB of flash and under 1 KB of RAM. The one real RAM saving
   is the stepper (4.7 KB), which is Peter's call. The budget comes from the
   heap move, not from gating.

## The target

The Pico Computer 3 as the firmware already knows it (`OPTION RESET PICO
COMPUTER 3` in [MM_Misc.c](../core/MM_Misc.c#L4015), the GP27 auto-detect in
[PicoMite.c](../PicoMite.c#L3640)):

| Resource | PC3 | Build consequence |
| --- | --- | --- |
| RP2350B, 48 GPIO | `pimoroni_pico_plus2_w_rp2350` board, as HDMIWEB and HDMIBTH | unchanged |
| Flash 16 MB | fixed map: system below 3 MB, MOD buffer 3-4 MB, A: 4-16 MB | the 4 MB map and the flash-size probe are dead code here |
| PSRAM 8 MB, APS6404 on GP47 | QMI CS1, memory mapped at 0x11000000, clocked at clk_sys / ceil(clk_sys / 109 MHz): 105 MHz at 315, 94.5 at 378, 84 at 252 | PSRAM is mandatory; the no-PSRAM paths are dead code |
| CYW43439 on GP23/24/25/29 | WiFi and Bluetooth on one chip, PIO2 plus two DMA channels, polled from core 0 | one `cyw43_arch_init` serves both radios |
| HDMI on HSTX | core 1 scanout, DMA 0/1, resolutions below | full pipeline (no HDMICUTDOWN) |
| USB host port | TinyUSB host on core 0 (keyboard, mouse, CDC COM3-6, MSC) | the USB CDC console is already off on host builds; console is the CH340 on GP8/9, telnet, and the display |
| SD card GP28/30/31/33, I2S audio GP10/22, system I2C GP20/21, RTC, INT1-4 on GP34-37 | | unchanged |

## Where the RAM goes today

The three HDMI variants and the experiment, from their maps. "Static" is
everything the linker places in RAM except `AllMemory[]` (the MMBasic heap
plus the framebuffer pool): RAM-resident code, initialised data and BSS.

| | HDMIUSB | HDMIWEB | HDMIBTH | PC3 experiment |
| --- | --- | --- | --- | --- |
| Flash image | 1123 KB | 1554 KB | 1491 KB | **1722 KB** |
| `FLASH_TARGET_OFFSET` | 1136 KB | 1568 KB | 1504 KB | 1728 KB |
| RAM code (`.data`) | 81.7 KB | 78.3 KB | 77.3 KB | 81.4 KB |
| BSS | 424.0 KB | 419.7 KB | 403.9 KB | 389.7 KB |
| of which `AllMemory` | 362.0 (212 heap + 150 pool) | 302.0 (208 + 93.75) | 314.0 (220 + 93.75) | 246.3 (96 + 150) |
| **Static, all other** | **143.6 KB** | **196.1 KB** | **167.2 KB** | **224.9 KB** |
| C heap + stack budget | 2 + 8 KB | 10 + 8 KB | 16 + 16 KB | 16 + 16 KB |
| RAM margin | 4.0 KB | 3.5 KB | 6.4 KB | 16.5 KB |

The experiment's static total is within 2 KB of the sum of the parts
(HDMIUSB's 143.6, plus WiFi's 55.3, plus Bluetooth's 26.5, less the cyw43
driver counted twice), so the three builds' maps predict the fourth.

What the static 225 KB is made of, by subsystem (flash alongside, because
it decides the offset):

| Subsystem | Flash | Static RAM | Notes |
| --- | --- | --- | --- |
| Interpreter core, file system, editor, I/O | 596 KB | 95 KB | RAM code 64 KB (MMBasic.c 21 KB, Commands, PicoMite.c, External, Stream 5-6 KB each); BSS: MMBasic.c 12 KB, `psmap` 6 KB, FileIO 6 KB |
| cyw43 driver and firmware | 254 KB | 2.7 KB | WiFi firmware and CLM 236 KB, Bluetooth firmware 13.5 KB; the driver's state 2.5 KB |
| btstack and the BT sources | 172 KB | 23.6 KB | pools 12.4 KB, BTAudio 5.0, HCI transport, SM, SDP, A2DP about 1 KB each |
| lwIP | 65 KB | 52.9 KB | `memp.c` 52.4 KB: the packet pool (32 x 1.5 KB) plus TCP PCBs and segments |
| mbedtls | 130 KB | 0.1 KB | the handshake working set comes from the MMBasic heap (`CallocMemory`) |
| Graphics (Draw, GUI, sprites, 3D, raycaster, turtle, decoders) | 134 KB | 9 KB | |
| Audio (I2S, WAV/FLAC/MP3, MOD, BBC) | 98 KB | 0.9 KB | VS1053 (28 KB) and PWM audio are already out of the BT host builds |
| libc and libgcc | 62 KB | 8.6 KB | C++ unwind tables in RAM 2.6 KB, newlib malloc 1 KB, mem* 0.7 KB |
| TinyUSB host plus USBKeyboard | 55 KB | 11.5 KB | hid_host 4.0, usbh 2.8, USBKeyboard 1.9, cdc_host 1.5 |
| Stepper | 47 KB | 4.7 KB | |
| WEB commands (net/*.c, cJSON, MQTT, TFTP) | 20 KB | 2.2 KB | |
| HDMI scanout | 4 KB | 6.5 KB | the full pipeline's loops are 5.8 KB of RAM code; the cut-down's 2.9 KB |

## The SRAM budget of the all-in build

Fixed: 225.2 KB static (including the 304-byte vector table), 32 KB of C
heap and stack budget (the Bluetooth host builds' 0x4000 each; the TLS
handshake stack and the lwIP packet buffers live here), 4 KB margin (Peter's
rule). That leaves 264.9 KB of the 520 KB for `AllMemory`: the framebuffer
pool plus the SRAM heap plus its 256-byte guard. The pool is what the full
HDMI build allocates at boot for the resolution in `OPTION RESOLUTION`
([PicoMite.c](../PicoMite.c#L3940)):

| Boot resolution | Pool | SRAM heap (4 KB steps) | Margin |
| --- | --- | --- | --- |
| 640x480 (252, 315, 378 MHz), 720x400, 1024x768, 1280x720, 1024x600 | 153,600 | **108 KB** | 7.0 KB |
| 800x480 | 192,000 | 72 KB | 5.5 KB |
| 848x480 | 203,520 | 60 KB | 6.3 KB |
| 800x600 | 240,000 | 24 KB | 6.5 KB |

Knobs that would raise every row:

- lwIP `PBUF_POOL_SIZE` 32 -> 16: +24 KB. The pool was sized for TCP
  throughput on the WebMite; whether the PC3 needs 32 packets in flight is a
  question for the TCP tests.
- Stepper out of this build: +4.7 KB (and 47 KB of flash).
- libgcc's C++ unwind tables out of RAM (`default_text_excludes.incl`, as the
  complex-math move did on 2026-10-02): +2.6 KB, if nothing needs them in
  RAM. Untested.
- 800x600, 848x480 and 800x480 as the cut-down builds have them (modes 1 and
  2 only, in the 96,000-byte pool): they would then share the 108 KB row. A
  design choice, not a saving on the common resolutions.

The 108 KB SRAM heap is the figure to design around. It holds, with room to
spare, what must be there: a big program's variable records (Prince of Pico
needs 19 chunks, 38 KB), the 64 temporary string slots, the COM port and
audio buffers (two 8 KB audio buffers, COM buffers as opened), the GUI
controls carved from its top, and one layer at the resolutions a layer fits
today.

## The heap

### Allocation classes

The allocators in [Memory.c](../core/Memory.c#L2336) today: `GetMemory` sends
anything over half the SRAM heap to PSRAM and otherwise searches SRAM
top-down, falling back to PSRAM when SRAM has no run; `GetVarMemory` (record
chunks) and `GetTempMemory` (temporaries, via the bottom-up search) are SRAM
first with the same fallback; `GetAlignedMemory` (PIO rings) is SRAM only.
The proposed classes, and what changes:

| Class | Examples | Today | PC3 | Why |
| --- | --- | --- | --- | --- |
| Variable records | `GetVarMemory`, 2 KB chunks of 32 | SRAM, PSRAM when full; RUN reserves the declared globals' chunks | same | every variable reference reads its record |
| Temporaries | `GetTempMemory`, `GetTempStrMemory` | SRAM bottom-up, PSRAM when full | same for small ones; the big program buffers (next row) go to PSRAM by size | expression evaluation allocates these constantly |
| Program buffers | EDIT, LOAD, LIBRARY LOAD/SAVE, LIST to file, XMODEM, FM: all sized from `EDIT_BUFFER_SIZE` | `heap_memory_size - 3072 - 3 * HRes`, i.e. the whole SRAM heap | a constant bigger than the program (`MAX_PROG_SIZE + 64 KB`); the SRAM search fails and the existing fallback lands them in PSRAM | with a 108 KB heap the editor could not hold a 256 KB program |
| Program data | arrays, strings over the inline size, `LOCAL` arrays, structures | SRAM first, PSRAM when big or when SRAM is full | **PSRAM always** | this is "the heap in PSRAM"; it also makes placement independent of allocation order and keeps SRAM for the rows above and below |
| Driver buffers | COM rx/tx ([Serial.c](../io/Serial.c#L693)), audio sample buffers ([Audio.c](../io/Audio.c#L873)), ADC DMA ([External.c](../misc/External.c#L5640)), stepper blocks and arcs ([stepper.c](../io/stepper.c#L237)), MEMORY SHARE, PLAY BBC state, PIO rings | plain `GetMemory`, so SRAM unless SRAM is full | a new `GetDriverMemory`: SRAM only, a precise error if there is none | an interrupt or DMA reading PSRAM during a flash write reads a dead window (below) |
| Layers | `FRAMEBUFFER LAYER`, `LAYER TOP` | refused if the allocation lands in PSRAM ([FrameBuffer.c](../graphics/FrameBuffer.c#L1621)) | same, through `GetDriverMemory` | core 1 reads them every scanline |
| JPEG capture | [I2C.c](../io/I2C.c#L3703) | already refuses PSRAM ("Not enough fast RAM") | same | DMA |
| TLS working set | mbedtls via `CallocMemory` | MMBasic heap, SRAM first | PSRAM | 16 KB record buffer plus 20-35 KB of handshake transients; core 0 only |
| JSON arena, blit and sprite buffers, tilemaps, FRAMEBUFFER F and N | `GetMemory` | mostly SRAM | PSRAM | core 0 only; speed to be measured for the sprite-heavy games |
| lwIP packet buffers, DHCP, PCBs | libc malloc | C heap | C heap | lwIP state outlives a RUN; unchanged |
| btstack pools, TinyUSB, cyw43 | static BSS | | | unchanged |

Peter's wording was "exclusively in PSRAM". The classes above are what that
means once the hardware rules are applied: an SRAM pool for the firmware's
own use, a PSRAM heap for the program. The pure form is the same table with
"Program data" in PSRAM and nothing else moved, which is the recommendation;
a variant that also sends temporaries to PSRAM is not worth measuring, since
temporaries are the hottest allocations the interpreter makes.

### Why interrupt and DMA buffers cannot be in PSRAM

`safe_flash_range_program` and `safe_flash_range_erase`
([FileIO.c](../misc/FileIO.c#L403)) run the SDK's `flash_range_program`,
which calls the ROM's `flash_exit_xip` and so takes the QMI out of
memory-mapped mode for the duration of the write: the PSRAM window at
0x11000000 is as dead as the flash window. The SDK saves and restores the
CS1 timing registers ([flash.c](../../pico-sdk/src/rp2_common/hardware_flash/flash.c#L116)),
so PSRAM comes back afterwards, but nothing can read it meanwhile. Core 1
survives today because the scanout reads only `AllMemory` and the lookup
tables placed in RAM for that reason ([SPI-LCD.c](../graphics/SPI-LCD.c#L3231)).
Interrupts survive because their buffers are in the SRAM heap, which today is
a side effect of their size, not a rule: a program that has filled SRAM with
small arrays and then opens a COM port gets an interrupt-written buffer in
PSRAM on any PSRAM build. The PC3 design makes it certain unless the driver
allocator exists, so it is part of phase 2, and it fixes the latent case on
the other PSRAM builds for free.

The second reason is contention: the PSRAM shares the QMI with flash XIP,
so a DMA stream from PSRAM steals from every instruction fetch that misses
the cache, and core 1's layer reads would do the same.

### What does not change

- `SAVE CONTEXT`, `CHAIN` and the editor's snapshot keep their mechanism:
  the SRAM heap and the tables are copied into the 384 KB context area, the
  PSRAM page map (`psmap`) is copied with them and the PSRAM data stays where
  it is, protected by the saved map. With a 108 KB SRAM heap the context
  image is about 125 KB, so `CONTEXT_BYTES` ([Commands.c](../core/Commands.c#L4348))
  could drop to 192 KB and give the difference back to the heap, but 384 KB
  costs 3% of the PSRAM and keeps the static assertion's margin.
- Loading a program (`m_alloc(M_PROG)`, [Memory.c](../core/Memory.c#L1903))
  already clears the whole PSRAM heap; that stays (6 MB at 30 MB/s is about
  0.2 s, paid today too). A lazy clear is an optimisation for later:
  `GetPSMemory` zeroes every allocation anyway.
- RAM image slots 4-8, the RAM library, the Route B stream in PSRAM, the
  PSRAM search hint: unchanged.
- A PSRAM that fails to answer at boot leaves the board with the SRAM heap
  only: the prompt works, `OPTION` and `UPDATE FIRMWARE` work, programs are
  limited. That is a better failure mode than today's PSRAM-less fallback,
  which the all-in build cannot offer anyway (its program size needs PSRAM
  for the editor), and it is why the SRAM heap must stay a real heap rather
  than a bag of reservations.

## Flash map

The image is 1722 KB, so `FLASH_TARGET_OFFSET` is 1728 KB (6 KB spare; the
next 16 KB step is where the design starts). The 16 MB fixed map
([configuration.h](../configuration.h#L889)) puts the MOD buffer at 3 MB and
the A: drive at 4 MB on every RP2350 variant, and
[FileIO.c](../misc/FileIO.c#L486) asserts that the system areas end below
3 MB. With a 256 KB program:

| Area | Start | Size |
| --- | --- | --- |
| Firmware | 0 | 1728 KB |
| Options | 1728 KB | 4 KB |
| Saved variables | 1732 KB | 16 KB |
| Flash slots 1, 2, 3 (3 is the library) | 1748 KB | 3 x 256 KB |
| Program | 2516 KB | 256 KB, ending at 2772 KB |
| Route B flash stream | none | see below |
| Growth room to the 3 MB system top | | 300 KB (the offset can reach 2016 KB) |
| MOD buffer | 3072 KB | 1 MB, unchanged |
| A: drive | 4096 KB | 12 MB, unchanged and shared with every other variant |

The Route B flash stream (`RB_STREAM_SLOTS` x `MAX_PROG_SIZE` after the
program, [configuration.h](../configuration.h#L880)) exists for boards
without PSRAM; with it the system areas would end at 3540 KB. On a build
that requires PSRAM it is never used (`RBInPsram()` in
[Stream.c](../core/Stream.c#L51) is true), so the design drops it:
`RB_STREAM_FLASH_SIZE` 0 and `TOP_OF_SYSTEM_FLASH` ending at the program.
The alternative, a 3.5 MB system top with a 512 KB MOD buffer (3584-4096 KB)
for this variant only, also keeps A: at 4 MB; it is more map to explain for
a fallback nobody can reach.

The library keeps its slot-3 rule and grows to 256 KB with the program.
`MagicKey` is new, so the first boot of this variant on a board resets the
options; on the 16 MB map the A: drive survives (fixed map, 2026-10-09).

## PSRAM map

The reserve off the top of the PSRAM is hard-coded as 2 MB in four places
(`PSRAMsize -= 2 MB` in [PicoMite.c](../PicoMite.c#L3881), `PSRAMstreamsize`
in [configuration.h](../configuration.h#L710), the two static assertions in
[FileIO.c](../misc/FileIO.c#L804), and the clear in [psram.c](../io/psram.c#L402),
which re-derives the same arithmetic). It becomes one constant,
`PSRAM_RESERVE = CONTEXT_BYTES + (MAXRAMSLOTS + RB_STREAM_SLOTS) * MAX_PROG_SIZE`:

| Area | Offset in PSRAM | Size |
| --- | --- | --- |
| MMBasic heap | 0 | 5760 KB (5.625 MB) |
| Context save area | 5760 KB | 384 KB |
| RAM slots 1-5 (image slots 4-8, RAM library in slot 5) | 6144 KB | 5 x 256 KB |
| Route B compiled stream | 7424 KB | 768 KB (3 program sizes, as today's rule) |

`PSRAMHEAPMAX` (6 MB) already covers the page map. The user loses 384 KB of
PSRAM against today's 6 MB, which Peter has said is acceptable.

## The two radios on one chip

The SDK's poll backend initialises lwIP and btstack on the same async
context in one `cyw43_arch_init`
([cyw43_arch_poll.c](../../pico-sdk/src/rp2_common/pico_cyw43_arch/cyw43_arch_poll.c#L33)),
and the Pico W examples run both. The experiment does exactly that: the WiFi
block's `cyw43_arch_init_with_country` is the one init, followed by
`WebConnect` and `bt_keyboard_init`; the Bluetooth host builds' own init
block is skipped under `PICOMITEWEB`. The firmware blob with the Bluetooth
part is the one HDMIBTH already carries (13.5 KB more than HDMIWEB's).

Things to settle in phase 1, none of them hard:

- **One pump.** `ProcessWeb()` and `ProcessBT()` are already called at the
  same sites and each throttles its own `cyw43_arch_poll` to once a
  millisecond; on the PC3 that is two polls per millisecond. One poll, then
  the WiFi housekeeping, then the Bluetooth notices.
- **One heartbeat.** `WebHeartbeat` (from `routinechecks`) and
  `bt_keyboard_poll` both blink the CYW43 LED. Keep one.
- **Option struct.** HDMIWEB's arm (`mousespeed` plus `extensions[58]`) and
  the Bluetooth builds' `bt_tlv[2048]` tail already coexist in the
  experiment; the 896-byte assertion and `LIBRARY_HASH` at 892 both hold.
- **Clock.** The gSPI divider is `ceil(CPU / 100 MHz)` on both the WiFi and
  the Bluetooth host builds, so every HDMI clock stays under the chip's
  50 MHz: 39.4 MHz at 315, 47.3 at 378, 45 at 360 (800x600), 47.2 at 283.2
  (720x400).
- **Coexistence on the air** is the risk to test, not to design: an A2DP
  stream to a speaker while a TFTP transfer or a TLS fetch runs on the same
  radio. The CYW43439 arbitrates; the AX1300BT stutter test with a keyboard
  connected is the same question one link smaller.

## Build mechanics

**A variant, not a fork.** The seventeen variants share one tree because
every fix lands once; the last month alone moved ZMODEM, Route B, the symbol
bindings, the compact variable table and Bluetooth audio through all of
them. A PC3 fork would have to take each of those by hand within weeks. The
experiment shows the cost of staying in the tree: five files.

The experiment's changes (branch `pc3-all`, commit 3b1418e):

| File | Change |
| --- | --- |
| [CMakeLists.txt](../CMakeLists.txt) | `PC3` in the variant lists (RP2350, BTH, WEB, USB host, UPNG, raycaster, HDMI, rand, subprofile); the turtle and display-source exclusions widened; no cut-down; the HDMI heap/stack defaults, the WEB heap/stack budget, the `WebMite` host name, the `PICOMITE` define and `CYW43_LWIP=0` kept off it; an identity block defining `PICOMITEHDMIBTH`, `PICOMITEHDMIWEB`, `PICOMITEPC3`, host name `PicoMitePC3` |
| [configuration.h](../configuration.h#L75) | a PC3 budget block ahead of HDMIBTH's: offset 1728 KB, heap 96 KB (the experiment's), program 180 KB (the experiment's; the asserts cap it until the reserve and the map change), new MagicKey |
| [PicoMite.c](../PicoMite.c#L214) | `MES_SIGNON`, the banner's chip-letter index (31), the Bluetooth init block skipped under `PICOMITEWEB`, `bt_keyboard_init()` after `WebConnect()` |
| [MM_Misc.c](../core/MM_Misc.c#L8159) | `MM.DEVICE$` = `PicoMitePC3` |
| [buildpicomite.bat](../buildpicomite.bat#L37) | `PC3:PicoMitePC3` in the RP2350 targets |

The one trap met: the IS_BT/IS_BTH block defines `PICOMITE` for every BT
build except HDMIBTH by name, so the new variant inherited the SPI-panel
world (duplicate `Option` members, `PIO0` twice, `USBenabled` twice). Any
future HDMI-plus-wireless variant needs the same exclusion.

**Macros.** `PICOMITEPC3` is the identity. The allocation policy of phase 2
goes behind a second macro (`PSRAMHEAP`, say) so that HDMIWEB can build with
it for the speed comparison and the PC3 can build without it to bisect a
problem; the PC3 defines both.

**Name.** `PicoMitePC3` in the experiment. `MM.DEVICE$` answers it, the
sign-on prints it, the uf2 is `PicoMitePC3V<ver>.uf2`. Peter's call.

## Gating out what the PC3 cannot use

| Candidate | Status on the hybrids | Flash | RAM | Recommendation |
| --- | --- | --- | --- | --- |
| SPI LCD panels, touch, SSD1963 | out (DISPLAY_SOURCES) | | | already out |
| VGA PIO scanout, VGA222 | out | | | already out |
| PS/2 keyboard and mouse | out (USB host builds use USBKeyboard.c) | | | already out |
| PicoCalc | out (`PICOCALC` is false with USBKEYBOARD) | | | already out |
| VS1053 | out of the BT host builds (`NOVS1053`) | 28 KB | 0.1 KB | out via IS_BTH |
| PWM and SPI-DAC audio | out of the BT host builds (`NOPWMAUDIO`) | ~10 KB | | out via IS_BTH |
| OV7670 camera | out of the wireless builds | 11 KB | 1 KB | already out |
| Other boards' `OPTION RESET` presets (HDMIUSB, HDMIUSBI2S, OLIMEX, HDMIBASIC, CMM1.5, VGA designs) | in | ~4 KB | 0 | out: a PC3 preset only |
| 4 MB flash map, flash-size probe (`FlashSizeDetect`), `OPTION FLASH SIZE` | in | ~1 KB | 0 | out: the fixed map is the only map |
| `OPTION PSRAM PIN`, `psram_not_responding` handling, the 42 `if (PSRAMsize)` fallbacks | in | ~2 KB | 0 | PSRAM pin fixed at GP47; keep the "not responding" boot message; the fallbacks come out where the PC3 code path replaces them (editor buffer, stream) and stay where they are harmless |
| `OPTION CYW43 PINS` | in | ~1 KB | 0 | keep: it costs nothing and a PC3 variant with the radio on other pins exists in the wild (Waveshare) |
| Stepper | in | 47 KB | 4.7 KB | Peter's call: the PC3 exposes the GPIOs, nothing on the board uses it |
| GPS, MQTT, TFTP, NTP, ping, UDP, MEMORY SHARE, MOD player, BBC sound, 3D, raycaster, turtle, FM, X/Y/ZMODEM | in | | | keep: they are what the display and the radios are for |

Total if everything in the "out" rows went: under 10 KB of flash and under
1 KB of RAM. The experiment did none of it and fits.

## Performance

Facts:

- The RP2350's XIP cache is 16 KB, two-way, 8-byte lines
  ([xip_cache.h](../../pico-sdk/src/rp2_common/hardware_xip_cache/include/hardware/xip_cache.h#L63)),
  shared by flash code, PSRAM data and the compiled stream in PSRAM. Code
  that hits it is faster than code in RAM (Peter, 2026-10-06); data in PSRAM
  competes with that code for the same lines.
- PSRAM bandwidth measured on the PC3: a 150 KB `memcpy` from PSRAM to SRAM
  takes 4.4 ms (34 MB/s); two PSRAM streams read alternately in one loop
  drop to 15-19 MB/s because every switch breaks a QMI burst; a 256-byte SRAM
  staging buffer restores the copy rate (FRAMEBUFFER MERGE, 2026-09-19).
  Image slot reads from PSRAM measured equal to flash (2026-09-18).
- What already runs from PSRAM on every PSRAM build: arrays over half the
  heap (Prince of Pico's, Bad Apple's frames), the Route B compiled stream,
  the RAM library, FRAMEBUFFER F and N at the bigger modes. The profiled
  games showed a 14% allocator cost when the SRAM heap was full and every
  temporary spilled to PSRAM, 5% after the search hint; that is the cost of
  temporaries in PSRAM, which the design keeps in SRAM.

What is new on the PC3 is small program data in PSRAM: a 10-element array
in an inner loop, a 200-byte string compared each iteration, sprites blitted
every frame. Each access that misses the cache is a QMI transaction of about
100-200 ns at 105 MHz; sequential walks amortise it, random ones do not.

The test plan, on the bench programs Peter judges by, at a fixed clock,
HDMIWEB first with the policy macro on and off, then the PC3 build:

| Program | What it exercises |
| --- | --- |
| `solar_eclipse.bas` (answers 12,1,2000 / 39,40,36 / -104,57,12 / 1644 / 30) | float arrays and scalar maths |
| PETSCII Robots, `chessiter.bas` | integer arrays, string handling, deep recursion |
| gamebench: Exile, Elite, Prince of Pico | sprites, blits, tilemaps, big arrays, compiled and text |
| `stdset` goldens | correctness under the new placement |
| A string benchmark (none in the set yet: LEFT$/MID$/concatenation over 200-byte strings) | long strings in PSRAM, the case most likely to regress |

If the sprite-heavy games regress, the knob is a size threshold in
`GetMemory` (blocks up to n bytes SRAM first, with the SRAM search still
refusing to starve the records), to be set from the measurements rather than
guessed. If long strings regress, string scalars join the records in SRAM
(they are bounded: one page each, `MAXVARS` of them at most).

## Work plan

| Phase | Work | Test | Size |
| --- | --- | --- | --- |
| 0 (done) | The experiment: the PC3 variant that links | build margins | 5 files |
| 1 | The variant that runs: one radio init and one pump (done in the experiment), one heartbeat, `EDIT_BUFFER_SIZE` as a PSRAM-sized constant, heap 108 KB with today's allocator, program 180 KB, flash offset 1728 KB; `buildpicomite.bat` target | Boot on the PC3; WiFi join, telnet, TLS fetch; BT keyboard, mouse, speaker; USB keyboard and MSC; HDMI at every resolution and mode; EDIT a 150 KB program; goldens | small; 2-3 days with the board |
| 2 | The heap: the allocation classes (program data to PSRAM behind `PSRAMHEAP`), `GetDriverMemory` and its call sites (COM, audio, ADC, stepper, share, BBC, layers), `CallocMemory` to PSRAM, `PSRAM_RESERVE` replacing the four 2 MB sites, the Route B flash stream dropped, `MAX_PROG_SIZE` 256 KB, new MagicKey | The benchmark table above on HDMIWEB (A/B) and the PC3; SAVE CONTEXT, CHAIN, RAM slots, LIBRARY LOAD RAM, a 250 KB program through EDIT, LOAD, SAVE, LIBRARY SAVE; flash writes during COM traffic, WAV playback and a stepper run; PSRAM disabled at boot | medium; the allocator change is ~150 lines, the call sites ~40 |
| 3 | PC3-only gating (presets, flash map, PSRAM option), optional stepper decision, lwIP pool sizing | build margins, OPTION LIST, a TCP throughput check if the pool shrinks | small |
| 4 | Manual (variant table, memory section, the PSRAM map), release notes, the Bluetooth and WiFi companions' variant lists, the release asset | help lint, `release_preflight.py` | small |

Phase 1 is a working all-in board with a 108 KB SRAM heap and PSRAM
overflow, which is to say HDMIWEB's behaviour with Bluetooth added and a
smaller SRAM heap. Everything the PC3 is for works at that point; phase 2 is
what makes the 256 KB program and the deterministic placement true.

## Decisions for Peter

1. The name and the `COMPILE` token (`PC3` / `PicoMitePC3` in the experiment).
2. Phase 2's policy: program data always in PSRAM (recommended, measured
   first), or today's size rule with a smaller SRAM heap (phase 1 as the end
   state).
3. The Route B flash stream: dropped on this variant (recommended) or kept
   with a 3.5 MB system top and a 512 KB MOD buffer.
4. 800x600, 848x480 and 800x480: full modes with a 24-72 KB SRAM heap, or
   modes 1 and 2 as the cut-down builds have them.
5. `PBUF_POOL_SIZE` and the other lwIP pools: keep 32 (WebMite throughput)
   or halve for 24 KB of heap.
6. Stepper in or out.
7. The context area: 384 KB as today, or 192 KB.
8. Which heartbeat survives.

## Appendix: how the numbers were taken

Private build directories under the session scratchpad, one per variant,
configured from the main checkout (and from `../pm_pc3` for PC3) with
`cmake -G Ninja -DCOMPILE=<variant> -DCMAKE_BUILD_TYPE=Release
-DPICOTOOL_FETCH_FROM_GIT_PATH=<a copy of build/_deps/picotool>`, built with
`cmake --build <dir> --target PicoMite -j 10` (about 20 s each), and checked
with `tools/GetHighestHexAddress.py PicoMite.hex PicoMite.elf.map`. The
margins match Peter's `buildpicomite.bat` builds of the same tree (HDMIWEB
+13.1 KB flash, +3.5 KB RAM). The per-object and per-subsystem tables are
from the maps, with two classifier corrections applied by hand: `Draw.c`
(64 KB flash, 4.8 KB RAM) had matched the lwIP pattern and TinyUSB's
`hid_host.c` had matched btstack's.
