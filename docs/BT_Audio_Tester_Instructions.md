# Bluetooth audio: test build after RC0

Thank you for the reports on the M12 and the three car radios. This build
changes three things, one for each of the problems you found. We have only
been able to try them with our own speakers, so your results on the real
devices are what tells us whether they work.

- **M12:** the sound stream now starts as soon as a speaker connects,
  whatever the `OPTION AUDIO BLUETOOTH` idle time. Your tests showed the M12
  plays only if the stream starts soon after it connects, which is why it
  worked with `OPTION AUDIO BLUETOOTH 0` and not with an idle time.
- **VDO TR723UB-BU:** `BLUETOOTH CONNECT` now takes a PIN after the name, so
  it can be given the 1234 the radio needs. Without one, 0000 is used as
  before.
- **AXIS AX1801BT:** the board now offers the speaker only 44.1 kHz. The
  radio was choosing 48 kHz, and we suspect that is behind the gap every 3
  seconds.

Nothing was changed for the AXIS AX1300BT, but please repeat its test (see
below) so we can compare.

## Installing it

The build is for the PicoMiteRP2350BTH, as before. Coming from RC0 nothing
is lost: options, pairings and programs are kept. Coming from beta 8 or
earlier the options and the Bluetooth pairings are reset, so set
`OPTION AUDIO BLUETOOTH` again and pair each device again.

`MM.VER` still says 7.00005, the same as RC0. To check you have the new
build, type this (the name does not matter):

```
BLUETOOTH CONNECT "x", ""
```

The new build answers `Error : PIN must be 1 to 16 characters`. RC0 gives a
different error.

## Before each test

Use the default idle time of 60 seconds, not 0. The M12 test is about
whether it now works with an idle time:

```
OPTION AUDIO BLUETOOTH 60
```

If Bluetooth is already the audio output this only changes the idle time;
otherwise the PicoMite restarts.

The speaker counts in `BLUETOOTH STATUS` (stream starts and pauses, gaps,
send waits, dropped samples and the rest) start again from zero each time
you use it, so they always cover the time since the last
`BLUETOOTH STATUS`.

## Test 1: the M12

1. Connect it again from scratch (use the name `BLUETOOTH SCAN` shows for
   it):

   ```
   BLUETOOTH DISCONNECT
   BLUETOOTH CONNECT "M12 name"
   BLUETOOTH STATUS
   ```

   The `Speaker:` line should end in `streaming`, not `idle`.

2. Within a minute, play a tone. Do you hear it?

   ```
   PLAY TONE 440, 440, 3000
   ```

3. Leave it alone for 2 minutes, then type `BLUETOOTH STATUS`. It should
   say `idle` and `pauses: 1 (0 by the speaker)`. Play the tone again. Do
   you hear it? (It starts about half a second late, which is normal.)

4. Switch the M12 off, wait 30 seconds and switch it on again. The
   PicoMite should reconnect by itself within a minute or so and show
   `Bluetooth speaker connected`. Leave it for 2 minutes, then play the tone
   again. Do you hear it?

5. Send the `BLUETOOTH STATUS` listing from the end.

## Test 2: the VDO TR723UB-BU

1. If the radio lists the PicoMite from your earlier attempts, delete it on
   the radio first.
2. Put the radio into its pairing mode, then:

   ```
   BLUETOOTH SCAN
   BLUETOOTH CONNECT "VDO name", "1234"
   ```

   using the name the scan shows. It should end with `Connected to ...`.
   The PIN is only needed this once; after that the radio reconnects by
   itself like the others.
3. Play a tone, and then some music from a file (MP3, WAV or FLAC) for a
   few minutes. Does it play cleanly?
4. Send the `BLUETOOTH STATUS` listing. If `BLUETOOTH CONNECT` fails, send
   the error line and the `BLUETOOTH STATUS` listing.

## Test 3: the AXIS AX1801BT

1. Connect it the way you did before, and tell us which way that was: the
   radio connecting by itself, or `BLUETOOTH CONNECT`.
2. `BLUETOOTH STATUS`: the `Stream:` line should now start
   `SBC 44100 Hz`. It said 48000 before.
3. Play music from a file for at least 3 minutes. Is the gap every 3
   seconds gone, still there, or different?
4. Send the `BLUETOOTH STATUS` listing from straight after the music.

## Test 4: the AXIS AX1300BT

1. Play music from a file for at least 3 minutes, as before. Are the
   stutters the same, better or worse?
2. Send the `BLUETOOTH STATUS` listing from straight after the music.
3. If a Bluetooth keyboard was connected during that test, please repeat
   it with the keyboard switched off, and say whether the stutters change.
   This tells us whether the radio link itself is running out of room.

## Test 5: the devices that already worked

Connect one of them, play a tone and some music, and check that it still
works. Its `Stream:` line should say 44100 Hz.

## What to send back

For each device: what you did, what you heard, and the `BLUETOOTH STATUS`
listing. Please copy the listings from the terminal window as text rather
than photos if you can, so we can compare the numbers directly. If anything
happens that is not described here, such as an error, a message, or a
connection dropping, note what you were doing at the time.
