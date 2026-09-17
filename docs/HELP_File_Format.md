# The MMBasic `help.txt` file format

MMBasic's `HELP` command reads its text from a plain file called `help.txt` on
the A: drive. A reference file is supplied with the firmware, but you can edit
it or write your own — for a library you maintain, for your own notes, or in
another language.

This page is the complete format. It is short, because the reader in the
firmware is short, but a few of the rules are unforgiving: break them and a
topic simply never appears.

## Installing the file

The file must be at `A:/help.txt` — the internal flash drive, lower case.
LittleFS is case sensitive, so `HELP.TXT` will not be found.

```basic
' from an SD card
COPY "B:/help.txt" TO "A:/help.txt"
```

or send it over the serial link with `XMODEM RECEIVE "A:/help.txt"`, or, on a
WiFi build with TFTP enabled, push it from a PC with any TFTP client.

Check the room you have first — the full reference file is about 410 KB:

```basic
PRINT MM.INFO(DISK SIZE), MM.INFO$(FREE SPACE)
```

Three files are supplied, all with the same 872 topics. Copy whichever one fits
and rename it to `help.txt` on the drive:

| File | Size | What each topic gives you |
|---|---|---|
| `help.txt` | 416 KB | the full description from the manual |
| `helpmin.txt` | 196 KB | the syntax and a one or two sentence summary |
| `helptiny.txt` | 83 KB | the syntax only |

`helptiny.txt` is the one to use if you mostly want reminding of an argument
order and have the manual to hand for everything else.

## Using HELP

```basic
HELP PRINT
HELP MATH FFT
HELP MM.INFO(OPTION)
```

Quotes are not needed: everything after `HELP ` on the line is taken as the
name, spaces included.

The name must match a topic **exactly** — so the wildcards are how you explore:

| You type | You get |
|---|---|
| `HELP MATH*` | every topic whose name begins with MATH |
| `HELP *SPRITE*` | every topic with SPRITE anywhere in the name |
| `HELP ???` | every three-character name |
| `HELP OPTION ?????` | OPTION plus any five-character word |

`*` stands for any number of characters, `?` for exactly one. Case does not
matter. If nothing matches, nothing at all is printed — try a wildcard.

## The file format

A topic is a header line starting with `~`, followed by its text. The text runs
until the next `~`:

```
~PIXEL
PIXEL x, y [,c]

Draws a single pixel on the display at the coordinates x, y using the
colour c.  If c is not specified the current foreground colour is used.
See also: PIXEL(), LINE, BOX
```

The header is the topic **name** and nothing else — `~PIXEL`, not
`~PIXEL x, y [,c]`. The match is against the whole header, so a header that
carries the argument list can only be found by someone who types the argument
list too. Put the syntax on the first line of the body instead, where it is
printed but not matched.

Everything else is free text and is printed as written, except that each line
is re-wrapped to the width of your console or display, breaking at spaces. A
line laid out as a table will therefore re-wrap on a narrow screen; that is
normal and the reference file accepts it.

### Rules

1. **CRLF line endings.** The reader steps backwards over a line by its length
   plus two, so a file saved with bare LF endings will not be read correctly.
   Save as "Windows (CRLF)" in your editor.
2. **Keep lines under 250 characters.** The reader has a fixed 256-byte line
   buffer. Long paragraphs are fine — just break them across lines and let the
   firmware re-wrap them.
3. **7-bit ASCII only.** The console strips the top bit, so curly quotes,
   en-dashes and accented characters will not survive. Use `'`, `"` and `-`.
4. **No trailing spaces on a `~` line.** `~PIXEL ` is a different name from
   `~PIXEL` and nobody will ever type it.
5. **A body line must not start with `~`.** It would be taken as the start of
   the next topic and the rest of your text would be lost. Indent it by one
   space if you need a leading tilde.
6. **One header per topic.** Two `~` lines in a row do not make an alias: if the
   first one matches, the body stops immediately at the second. To make a second
   name work, give it its own short topic pointing at the first:

   ```
   ~COLOR
   COLOR is the American spelling.

   Described under:  HELP COLOUR
   ```

### Naming topics

Name a topic after the family it belongs to, most general word first — `MATH`,
`MATH FFT`, `MATH FFT INVERSE`. That way `HELP MATH` finds the overview and
`HELP MATH*` lists the whole family. Names that begin with the argument, or
that read as a sentence, are effectively unreachable.

Long entries pause with `PRESS ANY KEY`, so a topic of one or two screens reads
best. Anything longer belongs in the User Manual, which the topic can point at.

## Regenerating the supplied file

The reference file is generated from the User Manual, so that the two cannot
drift apart:

```
python tools/gen_help.py            # docs/help.txt      - full text
python tools/gen_help.py --short    # docs/helpmin.txt   - syntax + summary
python tools/gen_help.py --tiny     # docs/helptiny.txt  - syntax only
python tools/help_lint.py docs/help.txt
```

`tools/help_lint.py` applies every rule above using a transcription of the
firmware's own reader, so if it passes, the firmware will read the file the way
you expect. It will also show you what a search would print, without a board:

```
python tools/help_lint.py docs/help.txt --lookup "MATH*"
```
