# Help file coverage: what the supplementary manuals add

Review of the supplementary manuals in `PDF/` against the generated
`docs/help.txt`, 2026-09-18. Tooling: `tools/help_gaps.py`.

> **Acted on the same day.** `gen_help.py` now harvests the supplementary
> manuals as well, adding 291 topics (872 -> 1151). The Stepper Reference has
> been rewritten to cover the six commands it was missing, and the Raycaster
> manual's `SPRITE TRANSPARENT` has been corrected to `SPRITE SET TRANSPARENT`.
> `help_gaps.py` now reports 32 rather than 272, and what is left is variants of
> topics that do exist (`OPTION TOUCH DISABLE` under `OPTION TOUCH`,
> `FRAME CURSOR ON`/`OFF` under `FRAME CURSOR`, `TOUCH(Y)` under `TOUCH(X)`).
> The findings below are kept as the record of what was wrong.

**272 topics are documented in a supplementary manual but absent from the help
file**, across 24 command families. Eight of those families currently have a
single pointer entry where there should be dozens.

## Why the gap exists

`gen_help.py` harvests the User Manual's detailed-listing tables, which is the
right source for everything the manual documents properly. But for these
families the manual carries only a signpost row:

```
~SPRITE
SPRITE
SPRITE()

See Appendix G and the separate SPRITE_User_Manual pdf
```

```
~TILEMAP
TILEMAP

TILEMAP is a powerful command for writing games.  See the separate
TILEMAP_User_Manual.pdf for more details
```

`STEPPER`, `RAY`, `FRAME`, `DRAW3D`, `STRUCT`, `ASTRO`, `STAR`, `LOCATION` and
`SLEW` are all the same shape — a paragraph of overview and a pointer. The GUI
controls are worse: they are not in the manual's listing tables at all, only in
`Advanced Graphics Functions.docx`, so `HELP GUI BUTTON` finds nothing.

So the help file faithfully reproduces a manual that itself delegates. Anyone
typing `HELP SPRITE SHOW` at the prompt gets silence.

## Inventory

| Family | Missing | Source |
|---|---:|---|
| `SPRITE` | 43 | SPRITE_User_Manual, Game_Development_Guide |
| `FRAME` | 40 | FRAME_User_Manual |
| `RAY` | 35 | Raycaster_User_Manual |
| `GUI` | 33 | Advanced Graphics Functions.docx, GUI_LISTBOX_SLIDER |
| `TILEMAP` | 25 | TILEMAP_User_Manual |
| `STEPPER` | 18 | Stepper_Reference (text lives in generate_stepper_pdf.py) |
| `DRAW3D` | 14 | 3D_Graphics_User_Manual |
| `STRUCT` | 13 | MMBasic_Structures_Manual |
| `OPTION` | 9 | option-profiling-cache, Game_Input_Devices, Option_GPS, FM |
| `PEEK` | 7 | Stepper_Reference (`PEEK(STEPPER X)` and friends) |
| `MEMORY SHARE` | 6 | MEMORY_SHARE_User_Manual |
| `CLICK` | 5 | Advanced Graphics Functions.docx |
| `PLAY`, `WII` | 4 each | PLAY_BBC, PLAY_SAMPLE, Game_Input_Devices |
| `DEVICE`, `TOUCH` | 3 each | Game_Input_Devices |
| `BLIT`, `SETTICK` | 2 each | BLIT_User_Manual, Game_Input_Devices |
| `CTRLVAL`, `GAMEPAD`, `GPS`, `KEYBOARD`, `MSGBOX`, `POKE` | 1 each | various |

The four largest families in full:

**SPRITE** — CLOSE, CLOSE ALL, COPY, HIDE, HIDE ALL, HIDE SAFE, INTERRUPT,
LOAD, LOADARRAY, LOADBMP, LOADPNG, MOVE, NEXT, NOINTERRUPT, READ, RESTORE,
SCROLL, SET TRANSPARENT, SHOW, SHOW SAFE, STATIC, STATIC CLEAR, STINTERRUPT,
SWAP, WRITE, and the functions `SPRITE(A|B|C|D|E|H|L|N|S|T|V|W|X|Y)`,
`SPRITE(ST ...)`.

**FRAME** — BOX, CLEAR, CLOSE, CLS, COLOUR, CREATE, CURSOR, CURSOR ON/OFF,
DESTROY, HIDE, HLINE, INPUT, OVERLAY, PANEL, PRINT, SCROLL, SHOW, TITLE, VBUF,
WRITE, and 19 `FRAME(...)` functions.

**RAY** — CAMERA, CAST, CELL, CLOSE, COLOUR, DEFINE, DOOR, DOOR CLEAR, DOOR
CLOSE, MAP, MINIMAP, MOVE, RENDER, SPRITE, SPRITE CLEAR, SPRITE REMOVE, TURN,
and 18 `RAY(...)` functions.

**GUI** — AREA, BARGAUGE, BCOLOUR, BEEP, BUTTON, CAPTION, CHECKBOX, DELETE,
DISABLE, DISPLAYBOX, ENABLE, FCOLOUR, FORMATBOX, FRAME, GAUGE, HIDE, INTERRUPT,
LED, LISTBOX, NUMBERBOX, PAGE, RADIO, REDRAW, SETUP, SHOW, SLIDER, SPINBOX,
SWITCH, TEXTBOX, the three `... CANCEL` forms, plus `CTRLVAL` and `MSGBOX`.

## Cross-check against the firmware parser

I extracted the `checkstring()` sub-keywords from each family's handler and
compared. This turns up discrepancies in both directions.

**DRAW3D matches exactly** — the manual's 14 sub-commands are the firmware's 14.

**In the firmware but in no manual at all.** These parse at the top of
`cmd_stepper()` ([stepper.c](../io/stepper.c)) yet the Stepper Reference does
not mention them:

| | |
|---|---|
| `STEPPER ARC` | [stepper.c:4424](../io/stepper.c#L4424) |
| `STEPPER BUFFER` | [stepper.c:6292](../io/stepper.c#L6292) |
| `STEPPER ENABLE` | [stepper.c:4777](../io/stepper.c#L4777) |
| `STEPPER INVERT` | [stepper.c:4820](../io/stepper.c#L4820) |
| `STEPPER RECOVER` | [stepper.c:4042](../io/stepper.c#L4042) |
| `STEPPER RESET` | [stepper.c:4483](../io/stepper.c#L4483) |

Also undocumented: `GUI RESTORE`, `SPRITE NOSTINTERRUPT`, and `RAY COLOR` (a
genuine alias of `RAY COLOUR` — both are accepted).

**In a manual but not in the firmware.** `SPRITE TRANSPARENT` appears in
SPRITE_User_Manual; the parser only accepts `SPRITE SET TRANSPARENT`. Looks like
a manual slip worth correcting.

Both lists are worth acting on in the manuals regardless of what happens to the
help file.

## Recommendation

Extend `gen_help.py` with a second harvester for the supplementary sources, so
the help file stays generated rather than hand-maintained. The markdown manuals
are already structured for it — `### FRAME BOX` headings with a fenced syntax
block and prose underneath — and the stepper text sits in `code_block("...")`
calls in its generator script.

Size cost, measured from the sources:

| | |
|---|---:|
| all supplementary body text | 111 KB |
| capped at syntax + first two paragraphs | 56 KB |

So `help.txt` goes from 416 KB to roughly 480 KB at the cap, `helpmin.txt` from
196 KB to about 260 KB, and `helptiny.txt` from 83 KB to about 98 KB. The cap is
the one worth taking: these manuals carry long worked examples that belong in
the PDF, not at the prompt. Each generated topic would end with a pointer to
the manual it came from.

## Decisions I need from you

1. **Cap at syntax + two paragraphs, or take the whole entry?** My preference is
   the cap, with `See the FRAME_User_Manual.pdf` as the last line.
2. **The Game_Development_Guide is a tutorial, not a reference** — it accounts
   for 65 of the hits but every one of them duplicates a name already found in
   SPRITE/TILEMAP/RAY/FRAME's own manual. I would use it only as a
   cross-reference, never as the text.
3. **`ASTRO`, `STAR`, `LOCATION`, `SLEW`** already have real descriptive entries
   from the manual, just no per-form syntax. The GPS_Astro_Reference has the
   detail — fold it in, or leave them?
4. **`STEPPER ARC` and the other five** have no prose anywhere. Do you want
   syntax-only stubs generated from the parser, or should they be written up in
   the Stepper Reference first?
