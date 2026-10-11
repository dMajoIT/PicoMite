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
(worktree `../pm_pc3`). The experiment links and fits, and after Peter
handed over the COM4 board it was flashed and ran the whole benchmark set
(section "Performance").

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
   leaves 259 KB for the framebuffer pool and an SRAM heap together: with the
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
   SAVE or an A: write reads garbage or hangs. The policy that measured best
   is today's: records, temporaries and small blocks SRAM first, anything
   over half the SRAM heap and the overflow in PSRAM, plus a new allocator
   for the driver buffers that refuses PSRAM; the program-text buffers
   (EDIT, LOAD and the rest) become a 512 KB PSRAM block so a 256 KB program
   can be edited and loaded. "Program data always in PSRAM" was measured
   too, and costs 2-9% for no gain.
5. **The speed question is measured (section "Performance"), on the COM4
   PC3.** All program data in PSRAM costs 2-9% on compute-bound programs
   and far more on a game that draws into a framebuffer that has gone to
   PSRAM; today's rule (SRAM first, PSRAM for big blocks and the overflow)
   with the PC3's 108 KB SRAM heap costs under 1% on everything that fits,
   and the PC3's full framebuffer pool keeps a 320x240 framebuffer in SRAM
   whatever the heap holds. The all-in build itself, flashed and run on the
   board, is 5-11% slower than HDMIWEB, and the RC0 images of HDMIUSB and
   HDMIBTH on the same board show that this is the Bluetooth host's
   millisecond poll, which HDMIBTH pays today: the PC3 runs at HDMIBTH's
   speed. The heap in PSRAM is worth about 1%.
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
| BSS | 424.0 KB | 419.7 KB | 403.9 KB | 401.7 KB |
| of which `AllMemory` | 362.0 (212 heap + 150 pool) | 302.0 (208 + 93.75) | 314.0 (220 + 93.75) | 258.3 (108 + 150) |
| **Static, all other** | **143.6 KB** | **196.1 KB** | **167.2 KB** | **224.9 KB** |
| C heap + stack budget | 2 + 8 KB | 10 + 8 KB | 16 + 16 KB | 16 + 16 KB |
| RAM margin | 4.0 KB | 3.5 KB | 6.4 KB | 4.2 KB |

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
rule). That leaves 264,968 bytes (258.8 KB) of the 520 KB for `AllMemory`:
the framebuffer pool plus the SRAM heap plus its 256-byte guard. The pool is what the full
HDMI build allocates at boot for the resolution in `OPTION RESOLUTION`
([PicoMite.c](../PicoMite.c#L3940)):

| Boot resolution | Pool | SRAM heap (4 KB steps) | Margin |
| --- | --- | --- | --- |
| 640x480 (252, 315, 378 MHz), 720x400, 1024x768, 1280x720, 1024x600 | 153,600 | **108 KB** | 4.5 KB |
| 800x480 | 192,000 | 72 KB | 3.0 KB (68 KB would leave 7.0) |
| 848x480 | 203,520 | 60 KB | 3.75 KB |
| 800x600 | 240,000 | 24 KB | 4.1 KB |

(The heap is one `HEAP_MEMORY_SIZE`, 108 KB; the boot-time resize for the
three medium resolutions takes their bigger pool out of it, as HDMIUSB does
today, so the rows below the first are what is left at those resolutions.)

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
| Program data | arrays, strings over the inline size, `LOCAL` arrays, structures | SRAM first, PSRAM when over half the heap or when SRAM is full | **the same** (measured: "PSRAM always" costs 2-9% and gains nothing; see Performance) | with a 108 KB heap the threshold is 54 KB; a program whose small data outgrows the heap spills, as on HDMIWEB today past 104 KB |
| Driver buffers | COM rx/tx ([Serial.c](../io/Serial.c#L693)), audio sample buffers ([Audio.c](../io/Audio.c#L873)), ADC DMA ([External.c](../misc/External.c#L5640)), stepper blocks and arcs ([stepper.c](../io/stepper.c#L237)), MEMORY SHARE, PLAY BBC state, PIO rings | plain `GetMemory`, so SRAM unless SRAM is full | a new `GetDriverMemory`: SRAM only, a precise error if there is none | an interrupt or DMA reading PSRAM during a flash write reads a dead window (below) |
| Layers | `FRAMEBUFFER LAYER`, `LAYER TOP` | refused if the allocation lands in PSRAM ([FrameBuffer.c](../graphics/FrameBuffer.c#L1621)) | same, through `GetDriverMemory` | core 1 reads them every scanline |
| JPEG capture | [I2C.c](../io/I2C.c#L3703) | already refuses PSRAM ("Not enough fast RAM") | same | DMA |
| TLS working set | mbedtls via `CallocMemory` | MMBasic heap, SRAM first | PSRAM | 16 KB record buffer plus 20-35 KB of handshake transients; core 0 only |
| JSON arena, blit and sprite buffers, tilemaps, FRAMEBUFFER F and N | `GetMemory` | mostly SRAM | PSRAM | core 0 only; speed to be measured for the sprite-heavy games |
| lwIP packet buffers, DHCP, PCBs | libc malloc | C heap | C heap | lwIP state outlives a RUN; unchanged |
| btstack pools, TinyUSB, cyw43 | static BSS | | | unchanged |

Peter's wording was "exclusively in PSRAM". The classes above are what that
means once the hardware rules are applied: an SRAM pool for the firmware's
own use, a PSRAM heap for the program. The pure form, "Program data" always
in PSRAM and nothing else moved, was built (`PSRAMHEAP_TEST`) and measured
against today's rule on the same board: it is slower on every program and
gains nothing, so the table keeps today's rule. A variant that also sends
temporaries to PSRAM was not worth measuring, since temporaries are the
hottest allocations the interpreter makes.

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

### The program-text commands: EDIT, AUTOSAVE, LOAD, SAVE and the transfers

Every command that handles the program as text takes one buffer sized from
`EDIT_BUFFER_SIZE` ([configuration.h](../configuration.h#L737)), which is
`heap_memory_size - 3072 - 3 * HRes`: the whole SRAM heap, less a little.
That is why each of them first empties the heap (`HeapReleaseForBuffer`,
[MMBasic.c](../core/MMBasic.c#L1230)) and why the editor opened from FM
asks for `FM_HEAP_RESERVE` less. On the PC3 the SRAM heap is 108 KB and the
program 256 KB, so the definition has to change; nothing else in these
commands does.

| Command | Buffer | Taken with | On the PC3 |
| --- | --- | --- | --- |
| EDIT, program or file ([Editor.c](../misc/Editor.c#L647)) | `EDIT_BUFFER_SIZE` (2 KB less from FM) | `GetTempMemory` | PSRAM (below) |
| AUTOSAVE, AUTOSAVE APPEND ([FileIO.c](../misc/FileIO.c#L7187)) | `EDIT_BUFFER_SIZE` less 8 KB | `GetTempMemory` | PSRAM |
| LOAD, RUN "file", CHAIN (`FileLoadProgram`, [FileIO.c](../misc/FileIO.c#L4567)) and RAM FILE LOAD ([:5075](../misc/FileIO.c#L5075)) | `EDIT_BUFFER_SIZE` less 2 KB | `GetTempMemory` | PSRAM |
| LOAD with `#DEFINE` preprocessing ([FileIO.c](../misc/FileIO.c#L3766)) | `loadbuffsize` | `GetMemory` | already PSRAM on every PSRAM build (over half the heap) |
| LIBRARY LOAD from a text file ([FileIO.c](../misc/FileIO.c#L7187)) | `EDIT_BUFFER_SIZE` | `GetTempMemory` | PSRAM |
| LIBRARY SAVE ([MM_Misc.c](../core/MM_Misc.c#L1945)) | `EDIT_BUFFER_SIZE` | `GetTempMainMemory`, i.e. `GetMemory` | already PSRAM |
| XMODEM, YMODEM and ZMODEM RECEIVE and SEND of the program ([XModem.c](../misc/XModem.c#L110)) | `XMODEMBUFFERSIZE` = `EDIT_BUFFER_SIZE` | `GetTempMemory` | PSRAM |
| SAVE "file", LIST, LIST to a file ([FileIO.c](../misc/FileIO.c#L3458), [Commands.c](../core/Commands.c#L2302)) | none: `llist` expands one line into a 256-byte buffer | | unchanged |
| The tokeniser, `SaveProgramToFlash` ([PicoMite.c](../PicoMite.c#L4850)) | none: `inpbuf`/`tknbuf` and a 4 KB flash page | | unchanged; it reads the text buffer once, sequentially, and checks `MAX_PROG_SIZE` at the write pointer |

**The change** is one definition: on the PC3, `EDIT_BUFFER_SIZE` is a
constant, 512 KB. Prince of Pico's source is 245 KB for a program that
tokenises under 156 KB, so a 256 KB program can come from a source of
400 KB or more; the buffer is temporary and PSRAM has 5.6 MB, so there is no
reason to be tight. The allocator does the rest without being touched:
`GetTempMemory` goes through the bottom-up SRAM search, finds no 512 KB run
in a 108 KB heap, and takes the block from PSRAM, which is the path LIBRARY
SAVE and the `#DEFINE` LOAD already take today. `HeapReleaseForBuffer` and
`FM_HEAP_RESERVE` stop being necessary for the buffer to fit, but they stay:
the release is also what guarantees that no interrupt is still writing a
variable record when the program is replaced.

**What to watch:**

- *Editing a big program gets slower per keystroke.* `editInsertChar`
  ([Editor.c](../misc/Editor.c#L8832)) walks to the end of the text and then
  shifts the whole tail down one byte at a time; DEL and BACKSPACE
  ([:6608](../misc/Editor.c#L6608)) shift it up the same way; beautify uses
  `memmove`. Two passes over the text per key, so inserting at the top of a
  300 KB listing already costs a few milliseconds in SRAM; in PSRAM, through
  the write-back cache, expect several times that, 10-30 ms, which shows with
  key repeat and with a paste. It is the same O(n) the editor has today with a
  bigger constant, and the cure is independent of PSRAM: keep the end-of-text
  pointer instead of re-scanning, or a gap buffer. Measure it in phase 1 with
  a 250 KB program open at line 1 before deciding.
- *AUTOSAVE and the transfers* append sequentially and are bound by the
  serial link; no change. AUTOSAVE's 255-character line limit is unrelated.
- *Tokenising* reads the buffer once, sequentially (cache-friendly), with two
  more sequential passes for the symbol table (`SymCount`). Seconds for a
  256 KB program either way.
- *The tables the program builds in the SRAM heap* are the real pressure on
  the 108 KB, not the text buffer: the variable record chunks (2 KB per 32
  variables; Prince of Pico takes 38 KB), the SUB/label name index
  ([MMBasic.c](../core/MMBasic.c#L855)), the IF table
  ([Commands.c](../core/Commands.c#L3299)) and the line-number targets. The
  symbol bindings already go to PSRAM when the hot block passes 4 KB
  ([Symbols.c](../core/Symbols.c#L496); the cold block always does), and the
  compiled stream is in PSRAM. A 256 KB program with 1200 variables would
  want about 75 KB of records; past the heap they spill to PSRAM, which
  works but slows every reference to the spilled variables. Phase 1 should
  RUN the biggest programs and read `MM.INFO(HEAP)`.
- *CHAIN* keeps its order ([Commands.c](../core/Commands.c#L4612)):
  `SaveContext`, `ClearVars`, `FileLoadProgram` with `M_LIMITED` (no PSRAM
  wipe), `ClearRuntime`. The load buffer is then taken from PSRAM beside the
  parent's preserved data, and the saved page map frees it at
  `RestoreContext`, as any allocation made after a save is freed today. A
  plain LOAD does `m_alloc(M_PROG)`, which clears the PSRAM heap, before it
  takes its buffer, so the order is right there too.

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
- **Coexistence on the air, measured 2026-10-11 on the COM4 PC3** (speaker
  00:13:EF:D2:4E:8C, a 10 s `PLAY TONE`, counters read once afterwards,
  because a `BLUETOOTH STATUS` during a stream stalls it): with the WiFi
  option cleared the stream is clean, bitpool 53, longest send wait 20 ms,
  no samples dropped; with WiFi merely associated and idle it is not,
  bitpool pinned at 26, send waits of 220-231 ms, 17-19% of the samples
  dropped, audibly broken. Raising the Bluetooth backlog cap from a quarter
  second to a second changed nothing (18.7% dropped), so this is the link's
  average capacity with the WiFi receiver on, not bursts a buffer could
  absorb. The Bluetooth keyboard works throughout. Not tried, for Peter to
  choose from: WiFi power save only while a stream runs (he has had trouble
  with power save before and ruled it out as a general setting), the
  firmware's coexistence iovars (`btc_mode`, `btc_params`; the driver sets
  none), filtering broadcast reception while streaming, and a mono or
  lower-rate fallback when WiFi is associated.

## Build mechanics

**A variant, not a fork.** The seventeen variants share one tree because
every fix lands once; the last month alone moved ZMODEM, Route B, the symbol
bindings, the compact variable table and Bluetooth audio through all of
them. A PC3 fork would have to take each of those by hand within weeks. The
experiment shows the cost of staying in the tree: five files.

The branch's changes (`pc3-all`):

| File | Change |
| --- | --- |
| [CMakeLists.txt](../CMakeLists.txt) | `PC3` in the variant lists (RP2350, BTH, WEB, USB host, UPNG, raycaster, HDMI, rand, subprofile); the turtle and display-source exclusions widened; no cut-down; the HDMI heap/stack defaults, the WEB heap/stack budget, the `WebMite` host name, the `PICOMITE` define and `CYW43_LWIP=0` kept off it; an identity block defining `PICOMITEHDMIBTH`, `PICOMITEHDMIWEB`, `PICOMITEPC3`, host name `PicoMitePC3` |
| [configuration.h](../configuration.h#L75) | a PC3 budget block ahead of HDMIBTH's: offset 1728 KB, heap 108 KB, program 180 KB (the asserts cap it until the reserve and the map change in phase 2), new MagicKey; `EDIT_BUFFER_SIZE` 512 KB from PSRAM; the `HEAPKB` knob |
| [PicoMite.c](../PicoMite.c#L214) | `MES_SIGNON`, the banner's chip-letter index (31), the Bluetooth init block skipped under `PICOMITEWEB`, `bt_keyboard_init()` after `WebConnect()` |
| [WiFi.c](../net/WiFi.c#L389), [BTKeyboard.c](../bluetooth/BTKeyboard.c#L2269) | one heartbeat: `WebHeartbeat` keeps the LED, with the Bluetooth speaker's no-toggle-while-streaming rule; the Bluetooth poll's blink is out under `PICOMITEWEB` |
| [Memory.c](../core/Memory.c#L2336) | the `PSRAMHEAP_TEST` knob in `GetMemory` |
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

### What the PC3 build lacks against PICORP2350 (Peter's question, 2026-10-11)

Every gate in the command and function tables evaluated for the two define
sets: PICORP2350 has 330 entries, the PC3 336. PICORP2350 has four the PC3
has not: `Backlight`, `Refresh` and the SPI-panel `Mode` (all display), and
`YModem`, which is gated to the USB CDC console builds (every USB host build
lacks it; XMODEM and ZMODEM are there). The PC3 adds ten: `Bluetooth`, `WEB`,
`RESOLUTION`, `MODE`, `TILE`, `DRAW3D(`, `Gamepad`, `Keyboard`,
`GetScanLine` and `Json$(`. The gaps that are not in the tables:

| Missing on the PC3 | Where it is gated | Why | Worth adding? |
| --- | --- | --- | --- |
| VS1053 audio codec: `OPTION AUDIO VS1053`, `PLAY NOTE`, `STREAM`, `MIDI`, `MIDIFILE`, `HALT`, `CONTINUE`, VS1053 playback of WAV/FLAC/MP3/MOD | `NOVS1053` (CMake, every Bluetooth host build) | dropped on the BT host builds for flash; the PC3 has 16 MB and 300 KB of system-area headroom | yes if wanted: 28 KB of flash, no RAM to speak of, one 16 KB offset step; it is a separate SPI device and does not touch the Bluetooth audio path |
| PWM audio and the SPI DAC: `OPTION AUDIO GPn,GPm` and `OPTION AUDIO SPI` | `NOPWMAUDIO` (CMake, every Bluetooth host build) | dropped so the PWM wrap interrupt serves only the I2S path next to Bluetooth audio | Peter's call: about 10 KB of flash, but it is the audio interrupt the Bluetooth audio feed shares, so it needs his view of BTAudio.c, not a CMake flag |
| PS/2 keyboard and mouse, `ON PS2`, `OPTION KEYBOARD DISABLE` | `!USBKEYBOARD` | the PC3 has no PS/2 socket; its keyboards are USB and Bluetooth | no |
| I2C keyboard (`CheckI2CKeyboard`) | `!USBKEYBOARD` ([I2C.c](../io/I2C.c#L609)) | compiled out of every USB host build | only if a PC3 user wants an I2C keyboard beside USB and Bluetooth |
| The USB CDC console (the chip's own USB serial) | USB host builds | the PC3's USB port is the host port; the console is the CH340 serial, telnet and the display | no |
| The fourth ADC channel (GP29) and a GPIO heartbeat pin | `PICOMITEWEB` | GP29 and GP25 belong to the radio; the LED is the radio's | no |
| `OPTION CPUSPEED` from 48 to 420 MHz | every HDMI build | the clock follows `OPTION RESOLUTION` | no |
| PIO2 for user programs | every wireless build | the radio runs on PIO2 | no |
| `PALM PICO`, `PICOCALC`, `GAMEMITE` and the RP2040 LCD presets, `OPTION KEYBOARD REPEAT`, `OPTION LOCAL KEYBOARD` | `PICOMITERP2350`, `PICOCALC` | other boards' hardware | no |

One thing the PC3 gets back that HDMIWEB and HDMIBTH do not have: the
OV7670 camera (`CAMERA`), whose gate is `!HDMICUTDOWN`, and the PC3 is not
cut down. The Wii controllers, the stepper, GPS, MEMORY SHARE, 3D, the
raycaster, turtle, FM, the structures and the transfers are all in.

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

One measurement in the tree says how sensitive the games are: when the
symbol bindings' hot block took 9 KB of SRAM, the 9 KB of Elite's own data
that it displaced into PSRAM cost Elite 20% ([Symbols.c](../core/Symbols.c#L493),
the reason the block now goes to PSRAM itself). That is the cost of a slice of
hot game data in PSRAM; "all program data in PSRAM" puts every slice there.
So the expectation is: scalar maths and the interpreter's own paths (records,
temporaries, the compiled stream) about as today, array and sprite heavy games
measurably slower, with the threshold knob as the fallback. The number
decides.

**The A/B/C, on an HDMIWEB board (COM4), nothing PC3-specific needed.** The
branch adds two CMake knobs, both off by default and neither for a release:
`-DPSRAMHEAP_TEST=ON` sends every `GetMemory` block to PSRAM with the records
and the temporaries left in SRAM, which is the design's policy and an upper
bound on its cost (the driver buffers go there too in that build, so no COM
ports or audio while it runs); `-DHEAPKB=108` gives today's policy the PC3's
108 KB SRAM heap, which is phase 1's behaviour. HDMIWEB's offset and
MagicKey are unchanged by either, so the board's options and A: drive
survive the three flashes:

| Build | What it measures |
| --- | --- |
| A: HDMIWEB as released | today |
| B: HDMIWEB `PSRAMHEAP_TEST=ON` | the phase 2 policy's cost, upper bound |
| C: HDMIWEB `HEAPKB=108` | phase 1: a 108 KB SRAM heap, PSRAM overflow |

### Measured (2026-10-11, COM4 PC3, HDMIWEB, 315 MHz, 640x480)

Peter flashed HDMIWEB from the branch (identical to the release for that
variant) and handed the board over; the three images were flashed in turn,
each verified against its uf2 by `fwsum.py`, A was flashed back at the end
and its repeat run agreed with the first to 0.1%. Every program was run with
`OPTION COMPILE OFF` and `ON` after `MODE 1 : CLS` and `OPTION CONSOLE SERIAL`.
Prince of Pico and PETSCII Robots were not run: their data sets are not on
this machine. The chess bench is the `chessiter.bas` benchmark cut to plies
1-3 (8,911 nodes). The raw outputs, the driver and the new string benchmark
are in `Bas/bench/results/pc3heap_1011/`.

| Program, mode | A: release | B: all blocks to PSRAM | C: 108 KB SRAM heap, today's rule |
| --- | --- | --- | --- |
| solar_eclipse, text (s) | 14.21 | 14.69 (+3.4%) | 14.32 (+0.8%) |
| solar_eclipse, compiled (s) | 5.65 | 5.88 (+4.1%) | 5.68 (+0.6%) |
| Exile kernel, compiled (ms/tick) | 4.58 | 4.67 (+1.9%) | 4.62 (+0.9%) |
| Exile kernel, text (ms/tick) | 10.59 | 10.77 (+1.7%) | 10.69 (+0.9%) |
| chess plies 1-3, compiled (s) | 35.8 | 38.9 (+8.7%) | 36.0 (+0.6%) |
| chess plies 1-3, text (s) | 193.4 | 197.2 (+1.9%) | 194.2 (+0.4%) |
| Elite demo, compiled (ms/frame) | 9.49 | 16.66 (+75%) | 15.58 (+64%) |
| Elite demo, text (ms/frame) | 20.94 | 28.41 (+36%) | 27.74 (+32%) |
| micro suite, 36 statements, text | | +0 to +2% (one +6%: a SUB creating 3 LOCAL arrays) | +0 to +2% |
| micro suite, compiled | | +0 to +3% | +0 to +2% |
| 100-char string array compare / copy, text | 24.0 / 22.3 us | +6.6% / +9.1% | +2.0% / +1.1% |
| 64 KB integer array, strided read / write, compiled | 1.17 / 1.22 us | +30% / +44% | +31% / +46% |
| 64 KB integer array, strided read / write, text | 16.5 / 17.1 us | +2.6% / +3.8% | +2.9% / +4.0% |

What it says:

- **Program data in PSRAM costs 2-9% on compute-bound programs.** solar
  3-4%, the Exile kernel 2%, chess 9% compiled (its 32 KB history table and
  the board arrays are what it touches). The micro suite shows the floor:
  a single array element read or write in PSRAM is 1-3% slower than SRAM in
  the interpreter, whose own overhead dominates, and 30-45% slower compiled,
  where the access is most of the statement. Strings cost 7-9% where the
  string itself is in PSRAM (array elements), nothing where it is a
  temporary.
- **Elite is the case that matters, and its cost is not the policy.** Under
  C, today's rule with a 108 KB heap, it is +64% compiled, nearly the +75%
  of B. In C small blocks still go to SRAM first; Elite's working set is
  simply bigger than 108 KB, so the rest spills, and what spills is hot:
  its framebuffer (38 KB), the 3D meshes, and the LOCAL arrays its routines
  create every frame. The absolute cost is the same in both modes (about
  +7 ms a frame), a fixed per-frame price for drawing into and copying out
  of PSRAM. Under A, with 208 KB, everything fits. (On the first C run Elite
  did not even LOAD: the 117 KB program is bigger than a load buffer sized
  from a 108 KB heap, which is exactly why the PC3 gives that buffer 512 KB
  of PSRAM; the `HEAPKB` knob now carries the same rule.)
- **So the choice of policy (decision 2) is secondary; where the
  framebuffer a game draws into lands is what decides whether it runs as it
  does today.** Today's rule (C) is free for everything that fits, and no
  worse than B for what does not, so phase 2 should keep it: SRAM first,
  PSRAM for blocks over half the SRAM heap and for the overflow, plus the
  driver allocator for correctness. "Program data always in PSRAM" would
  cost the 2-9% on every program for no gain.

**Where Elite's 7 ms a frame goes, and why the PC3 build does not pay it.**
A sweep of HDMIWEB builds with 128, 144, 160 and 176 KB SRAM heaps left
Elite at 15.5-17.2 ms/frame compiled: no knee, only the 208 KB release gets
9.5. A probe program (`fbprobe.bas` in the results directory, run on A:
`MODE 2`, `FRAMEBUFFER CREATE`, a frame of 50 lines, a box, text and
`FRAMEBUFFER COPY F,N`, then the same after filling the SRAM heap with
arrays) measured the frame at 9.7 ms with F in the SRAM heap and 15.9 ms with
F in PSRAM, text mode, and 8.9 against 15.1 compiled: the same +6-7 ms Elite
loses. `MM.INFO(WRITEBUFF)` showed where F was each time. The reason the
sweep never recovered is in [FrameBuffer.c](../graphics/FrameBuffer.c#L1569):
`FRAMEBUFFER CREATE` puts F inside the framebuffer pool when `ScreenSize`
is under a third of the pool, and only otherwise takes it from the heap.
HDMIWEB's cut-down pool is 96,000 bytes, a third is 32,000, and a 320x240
F is 38,400, so on HDMIWEB F always comes from the heap and goes to PSRAM
whenever the heap is too full or too fragmented for 150 contiguous pages,
which it was on every heap below 208 KB. The PC3 build has the full
153,600-byte pool, a third is 51,200, so at MODE 2 (and MODE 1) a 640x480
F lives in the pool, in SRAM, whatever the heap holds. The one case that
still takes the heap is MODE 3/4/5 at 640x480 (153,600 bytes, PSRAM on
every build today), which is also what today's HDMIWEB does.

**The PC3 build itself, on the same board (COM4, flashed after the A/B/C).**
It boots, signs on as `PicoMitePC3`, verifies against its uf2, keeps the A:
drive across the variant change (the 16 MB fixed map) and takes the
`OPTION RESET PICO COMPUTER 3` preset (PSRAM on GP47, SD, I2S, 315 MHz),
which on this map no longer asks or formats. The first boot after the
variant change comes up without the preset, so the PSRAM is off until it is
applied: the auto-configure on GP27 did not run, as noted for HDMIWEB on
2026-09-26. With the preset, `MM.INFO(HEAP)` reports 6,383,616: 90 KB of the
108 KB SRAM heap free at the prompt plus the 6 MB of PSRAM. The full set,
every check passing:

| Program, mode | A: HDMIWEB release | PC3 build | PC3 / A |
| --- | --- | --- | --- |
| solar_eclipse, text (s) | 14.21 | 15.46 | +8.8% |
| solar_eclipse, compiled (s) | 5.65 | 6.01 | +6.3% |
| Exile kernel, compiled (ms/tick) | 4.58 | 4.86 | +6.1% |
| Exile kernel, text (ms/tick) | 10.59 | 11.60 | +9.5% |
| Elite demo, compiled (ms/frame) | 9.49 | 10.39 | +9.4% |
| Elite demo, text (ms/frame) | 20.94 | 23.30 | +11.3% |
| chess plies 1-3, compiled (s) | 35.8 | 37.6 | +5.1% |
| chess plies 1-3, text (s) | 193.4 | 211.0 | +9.1% |

Elite's +9% rather than +64% is the framebuffer in the pool, as predicted.
But solar text, which hardly touches the heap and was +0.8% with the same
108 KB heap on HDMIWEB (C), is +8.8% here, so most of the PC3's cost is not
the heap at all. The two things the PC3 adds that C did not have are the
Bluetooth host's poll (`bt_keyboard_poll` runs the cyw43 and btstack once a
millisecond from every statement's `CheckAbort`) and the full-pipeline
scanout (HDMIloop0, RGB555 at 640x480, more SRAM traffic from core 1 than
the cut-down RGB332 loop). The RC0 release images of HDMIUSB (full pipeline,
no radio) and HDMIBTH (cut-down pipeline, Bluetooth host), same board, same
preset, solar_eclipse:

| Build | text (s) | compiled (s) |
| --- | --- | --- |
| HDMIWEB (A) | 14.21 | 5.65 |
| HDMIUSB | 14.36 (+1.1%) | 5.59 (-1.0%) |
| HDMIBTH | 15.50 (+9.1%) | 5.90 (+4.5%) |
| PC3 | 15.46 (+8.8%) | 6.01 (+6.3%) |

The full pipeline costs about 1% in text mode and nothing compiled. The
Bluetooth host's poll costs 9% in text mode and 4.5% compiled, and every
HDMIBTH user pays it today. The PC3 runs at HDMIBTH's speed in text mode and
2% behind it compiled, which is the WiFi poll and the smaller heap (C2 put
the heap at under 1%). **So the heap in PSRAM is worth about 1%, and the
price of the all-in build is the price of the Bluetooth host.** The poll's
cadence, running the cyw43 and btstack every millisecond whether or not
anything is connected, is a tuning target for HDMIBTH and the PC3 alike, and
outside this review.

The test plan, on the bench programs Peter judges by, at a fixed clock,
the three HDMIWEB builds first, then the PC3 build:

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
| 1 | The variant that runs: one radio init (done), one heartbeat (done), `EDIT_BUFFER_SIZE` as a PSRAM-sized constant (done), heap 108 KB with today's allocator (done), program 180 KB, flash offset 1728 KB, `buildpicomite.bat` target (done); the two polls left as they are (each throttled to once a millisecond; `ProcessWeb` returns early with no WiFi, so the Bluetooth poll must stay) | Boot on the PC3; WiFi join, telnet, TLS fetch; BT keyboard, mouse, speaker; USB keyboard and MSC; HDMI at every resolution and mode; EDIT a 150 KB program; goldens; the A/B/C above | the branch builds; the board tests are the work |
| 2 | The heap: today's rule kept (measured), `GetDriverMemory` and its call sites (COM, audio, ADC, stepper, share, BBC, layers), `CallocMemory` to PSRAM. **Done 2026-10-11 (2513f23):** `PSRAM_RESERVE` replacing the four 2 MB sites (2.5 MB on the PC3, Peter's choice: 384 KB context, five 256 KB RAM slots, 896 KB of stream), the Route B flash stream dropped (`RB_STREAM_FLASH_SLOTS` 0, system flash ends at 2772 KB), `MAX_PROG_SIZE` 256 KB, new MagicKey. On the board: `MM.INFO(PSRAM SIZE)` 5,767,168, MEMORY shows a 256K program and 5738K free, a 245 KB source loads as 220K (6209 lines), RAM SAVE 1 / NEW / RAM LOAD 1 brings it back, the compiled stream area is 917,504 bytes, solar unchanged (15.48 s / 5.89 s) | SAVE CONTEXT, CHAIN, LIBRARY LOAD RAM, a 250 KB program through EDIT, SAVE, LIBRARY SAVE; flash writes during COM traffic, WAV playback and a stepper run; PSRAM disabled at boot; the benchmark set again | the driver allocator ~40 lines of call sites remain |
| 3 | PC3-only gating (presets, flash map, PSRAM option), optional stepper decision, lwIP pool sizing | build margins, OPTION LIST, a TCP throughput check if the pool shrinks | small |
| 4 | Manual (variant table, memory section, the PSRAM map), release notes, the Bluetooth and WiFi companions' variant lists, the release asset | help lint, `release_preflight.py` | small |

Phase 1 is a working all-in board with a 108 KB SRAM heap and PSRAM
overflow, which is to say HDMIWEB's behaviour with Bluetooth added and a
smaller SRAM heap. Everything the PC3 is for works at that point; phase 2 is
what makes the 256 KB program and the deterministic placement true.

## Decisions (Peter, 2026-10-11)

1. **Name:** `COMPILE=PC3`, sign-on and `MM.DEVICE$` `PicoMitePC3`.
2. **Phase 2's policy:** program data always in PSRAM, measured first. The
   measurement (same day, section "Performance") says today's rule: "always
   in PSRAM" costs 2-9% on compute-bound programs and gains nothing, while
   today's rule with the PC3's heap costs under 1%. Recommendation: keep
   today's rule, add only the driver allocator; the `PSRAMHEAP_TEST` knob
   stays as a measuring tool.
3. **The Route B flash stream:** dropped on this variant; the 3 MB system
   top, the 1 MB MOD buffer and the A: drive at 4 MB stay as on every other
   RP2350 build.
4. **800x600, 848x480 and 800x480:** full modes. Consequence: at those boot
   resolutions the SRAM heap is 72, 60 and 24 KB. At 800x600 that is room for
   about eight record chunks (256 variables) plus the temporaries before the
   records spill to PSRAM, and a WAV or MP3 player takes 16 KB of it for its
   sample buffers; a big program at 800x600 runs, but slower, and
   `MM.INFO(HEAP)` is the thing to watch there.
5. **lwIP pools:** keep `PBUF_POOL_SIZE` 32.
6. **Stepper:** in.
7. **The context area:** 384 KB, as today.
8. **Heartbeat:** the CYW43's GPIO0 LED only, one driver: `WebHeartbeat`
   (from `routinechecks`, blinking whether or not WiFi is up, honouring
   `OPTION HEARTBEAT`), which on the PC3 also leaves the LED alone while a
   Bluetooth speaker streams, the rule `bt_keyboard_poll` had; its own blink
   is compiled out under `PICOMITEWEB`.

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
