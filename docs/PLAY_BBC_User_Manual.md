# PLAY BBC SOUND and PLAY BBC ENVELOPE User Manual

## Overview

`PLAY BBC SOUND` and `PLAY BBC ENVELOPE` are the BBC Micro's `SOUND` and `ENVELOPE` statements, with the same parameters, the same units and the same behaviour. They give MMBasic a four-channel sequencer: notes are queued with a duration and play in order without the program having to time them, chords can be started together, and an envelope can shape both the pitch and the volume of a note while it plays. A BBC Micro program's sound effects and tunes carry across with only the `PLAY BBC` prefix added.

Channels 1 to 3 are square-wave tones and channel 0 is a noise source, as on the BBC. The output is mono (the same signal on both sides), band-limited so sustained notes stay clean at the top of the range, and plays through whatever audio output the firmware is configured for (PWM, I2S or VS1053). `PLAY VOLUME` applies.

Available on all firmware versions.

## Syntax

```basic
PLAY BBC SOUND channel, amplitude, pitch, duration
PLAY BBC ENVELOPE n, T, PI1, PI2, PI3, PN1, PN2, PN3, AA, AD, AS, AR, ALA, ALD
PLAY STOP
PLAY PAUSE
PLAY RESUME
```

## PLAY BBC SOUND

| Parameter | Description |
| :--- | :--- |
| `channel` | The channel word `&HSFC` (0 to 65535). Only three fields are used: `C` (bits 0-1) is the channel 0 to 3, `F` (bit 4, `&H10`) flushes the channel's queue and stops its current note before this one is queued, and `S` (bits 8-9, `&H100` to `&H300`) is the number of *other* channels this note waits for (see Synchronising). Plain `1`, `2`, `3` and `0` are the four channels with no flush and no sync. |
| `amplitude` | `-15` to `0` sets the volume, `-15` loudest and `0` silent (a rest). `1` to `16` selects an envelope defined with `PLAY BBC ENVELOPE`, which then controls the volume and may bend the pitch. |
| `pitch` | 0 to 255 in quarter-semitones. `89` is A4 (440 Hz) and each 4 is a semitone, so 48 is an octave. See the pitch table below. On channel 0 only the low three bits are used, and they select one of the eight noises - see Noise below. |
| `duration` | 0 to 255 in twentieths of a second (255 = 12.75 s). `255` means play until the channel is flushed or `PLAY STOP` is given. `0` is treated as the shortest note, one hundredth of a second. |

### Pitch values

| Note | C | C# | D | D# | E | F | F# | G | G# | A | A# | B |
| :--- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Octave 3 | 5 | 9 | 13 | 17 | 21 | 25 | 29 | 33 | 37 | 41 | 45 | 49 |
| Octave 4 (middle C) | 53 | 57 | 61 | 65 | 69 | 73 | 77 | 81 | 85 | 89 | 93 | 97 |
| Octave 5 | 101 | 105 | 109 | 113 | 117 | 121 | 125 | 129 | 133 | 137 | 141 | 145 |
| Octave 6 | 149 | 153 | 157 | 161 | 165 | 169 | 173 | 177 | 181 | 185 | 189 | 193 |
| Octave 7 | 197 | 201 | 205 | 209 | 213 | 217 | 221 | 225 | 229 | 233 | 237 | 241 |

Frequency in Hz is `440 * 2 ^ ((pitch - 89) / 48)`.

### Noise

On channel 0 the pitch selects one of eight noises from its low three bits, as
on the BBC. Bits 0-1 choose the rate and bit 2 chooses the kind:

| pitch | kind | rate |
| :-: | :--- | :--- |
| 0 | periodic | high |
| 1 | periodic | medium |
| 2 | periodic | low |
| 3 | periodic | channel 1's pitch |
| 4 | white | high |
| 5 | white | medium |
| 6 | white | low |
| 7 | white | channel 1's pitch |

Periodic noise circulates one bit round a fifteen-stage shift register, so it
is a buzzy pitched tone rather than a hiss - the User Guide calls 0 to 2
sawtooth tones. White noise XORs two taps and is the untuned hiss wanted for
explosions and surf.

Pitches 3 and 7 are clocked by channel 1's tone rather than by a fixed rate,
which is how a BBC game tunes a noise: a note on channel 1 sets the pitch of
the noise, and a pitch envelope on channel 1 bends it. Channel 1 does not have
to be audible - an amplitude of 0 still sets its pitch - and until channel 1
has been given one, 3 and 7 are silent.

### Queues and blocking

Each channel has a queue of 8 notes. A `PLAY BBC SOUND` returns at once when there is room, so a tune can be written as a run of statements and the program carries on while it plays. When a channel's queue is full the statement waits for a slot to come free, exactly as the BBC did, so a loop of `PLAY BBC SOUND` statements paces itself to the music. Ctrl-C works while it waits. Timer and other MMBasic interrupts are held off until the statement completes, so keep queues short in a program that relies on them, or use the flush bit.

A note of duration 255 on a channel holds up everything queued behind it on that channel until the channel is flushed.

### Synchronising

A note whose channel word carries `&H100`, `&H200` or `&H300` does not start until 1, 2 or 3 *other* channels are waiting with the same value at the head of their queues, and then they all start together. The value is the number of other channels to wait for, so a three-note chord uses `&H2xx` on all three channels:

```basic
PLAY BBC SOUND &H201, -15, 53, 20   ' C
PLAY BBC SOUND &H202, -15, 69, 20   ' E   the three start together
PLAY BBC SOUND &H203, -15, 81, 20   ' G
```

`&H1xx` releases in pairs, which is the classic mistake: three notes marked `&H1xx` play two together and leave the third waiting for a partner that never comes.

### Flushing

`&H10` in the channel word empties that channel's queue and stops the note it is playing before the new note is queued, so the new note is heard immediately. This is how a game fires a sound effect over whatever was playing:

```basic
PLAY BBC SOUND &H11, 2, 200, 4      ' laser on channel 1, envelope 2, right now
```

A flush never waits.

## PLAY BBC ENVELOPE

An envelope is defined once, with a number 1 to 16, and used by giving that number as the amplitude of a `PLAY BBC SOUND`. Definitions survive `PLAY STOP` and the automatic release of the audio output, so a program defines its envelopes once at the start. They are cleared with the program's variables by `RUN`, `NEW` and loading a program.

```basic
PLAY BBC ENVELOPE n, T, PI1, PI2, PI3, PN1, PN2, PN3, AA, AD, AS, AR, ALA, ALD
```

| Parameter | Range | Description |
| :--- | :--- | :--- |
| `n` | 1 to 16 | Envelope number. |
| `T` | 0 to 255 | Length of each step in hundredths of a second (bits 0-6, 0 is treated as 1). Add 128 to stop the pitch envelope repeating; otherwise it repeats for the length of the note. |
| `PI1`, `PI2`, `PI3` | -128 to 127 | Pitch change per step in each of the three pitch sections, in quarter-semitones. |
| `PN1`, `PN2`, `PN3` | 0 to 255 | Number of steps in each pitch section. |
| `AA` | -127 to 127 | Attack: volume change per step until the level reaches `ALA`. |
| `AD` | -127 to 127 | Decay: volume change per step until the level reaches `ALD`. |
| `AS` | -127 to 0 | Sustain: volume change per step while the note lasts (0 holds the level). |
| `AR` | -127 to 0 | Release: volume change per step after the note's duration ends, until the level reaches 0. |
| `ALA` | 0 to 126 | The level the attack rises to. |
| `ALD` | 0 to 126 | The level the decay falls to. |

Levels run from 0 (silent) to 126 (as loud as amplitude -15). The amplitude envelope steps every `T` hundredths of a second: attack from 0 towards `ALA` by `AA` per step, then decay towards `ALD` by `AD`, then sustain, changing by `AS` per step, until the note's duration runs out, then release by `AR` per step until silent. The note ends when the release reaches 0, so a note with a slow release outlasts its duration; a release of 0 (`AR = 0`) is never heard to end and should be avoided unless the channel will be flushed.

The pitch envelope runs at the same step rate, in three sections: `PN1` steps of `PI1` each, then `PN2` of `PI2`, then `PN3` of `PI3`. When the three sections are done the pitch offset returns to zero and they repeat, unless `T` has 128 added. Vibrato, trills, sirens and slides are all made this way.

```
Volume
  ^
  |        ALA
  |        /\
  |   AA  /  \ AD
  |      /    \____________ ALD, then AS per step
  |     /                  \
  |    /                    \ AR
  |   /                      \
  +----------------------------------> time
      |<---- duration ---->|
```

## Memory

The engine keeps its state (the four channels and their queues, the sixteen envelopes and the noise generator, about 470 bytes) in a block taken from the MMBasic heap by the first `PLAY BBC SOUND` or `PLAY BBC ENVELOPE` a program issues, so a program that does not use it pays nothing. `MEMORY` shows it under General, rounded up to 1K. The block is kept until the program's variables are cleared by `RUN`, `NEW` or loading a program; `PLAY STOP` silences the engine but keeps the block and its envelopes. While the engine is playing it also holds two 2 KB output buffers, as `PLAY TONE` and `PLAY SOUND` do, and those are released whenever the output stops.

## Stopping, pausing and status

`PLAY STOP` silences all four channels, empties every queue and releases the audio output. `PLAY PAUSE` and `PLAY RESUME` freeze and continue the whole engine, queues included. `MM.INFO(SOUND)` returns `BBC` while it is playing and `PAUSED BBC` while paused.

When every channel is silent and every queue is empty the audio output is released automatically, as it is when a `PLAY TONE` ends, so a program does not need `PLAY STOP` between a tune and a following `PLAY WAV` or `PLAY MP3`. The next `PLAY BBC SOUND` starts the engine again. While notes are playing or queued the output is in use, and another `PLAY` command reports `Sound output in use for BBC`.

## Examples

A scale on channel 1:

```basic
FOR p = 53 TO 101 STEP 4
  PLAY BBC SOUND 1, -15, p, 5
NEXT p
```

A chord, with a rest before it on channel 1 so it follows the scale:

```basic
PLAY BBC SOUND 1, 0, 0, 10               ' a rest
PLAY BBC SOUND &H201, -15, 53, 20
PLAY BBC SOUND &H202, -15, 69, 20
PLAY BBC SOUND &H203, -15, 81, 20
```

The BBC User Guide's envelope demonstration, a note that rises and falls:

```basic
PLAY BBC ENVELOPE 1, 1, 4, -4, 4, 10, 10, 10, 126, -2, 0, -10, 120, 100
PLAY BBC SOUND 1, 1, 100, 30
```

A laser (fast downward pitch slide, sharp attack, quick release) and an explosion (noise with a slow decay), the two sounds every BBC game had:

```basic
PLAY BBC ENVELOPE 2, 1, -8, 0, 0, 20, 0, 0, 126, -8, 0, -20, 126, 100
PLAY BBC ENVELOPE 3, 4, 0, 0, 0, 0, 0, 0, 126, -1, -1, -4, 126, 80
PLAY BBC SOUND &H11, 2, 220, 4           ' laser, flushing channel 1
PLAY BBC SOUND &H10, 3, 6, 15            ' explosion: white noise, low
```

A siren that runs until stopped:

```basic
PLAY BBC ENVELOPE 4, 6, 2, -2, 0, 12, 12, 0, 126, 0, 0, -10, 126, 126
PLAY BBC SOUND 2, 4, 120, 255
PAUSE 5000
PLAY STOP
```

## Differences from the BBC Micro

- The `H` field of the channel word (`&H1000`, hold) is ignored.
- Output is mono. `PLAY VOLUME` sets the overall level and can be used to balance it against other sounds; one full-amplitude channel is about a quarter of full scale, so three together are loud.
- `SOUND OFF`, `SOUND ON` and `*FX 210` have no equivalent; use `PLAY STOP`.
- While a `PLAY BBC SOUND` is waiting for room in a full queue, MMBasic interrupts are deferred until it returns.
