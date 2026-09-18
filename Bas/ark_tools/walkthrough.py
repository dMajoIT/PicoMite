"""Drive Picanoid through a scripted tour, for recording a video.

The game is already playing itself (the A key puts the bat on rails), so all
this does is inject keystrokes on a timeline and push captions onto the screen
so the video narrates itself.

Captions go over the console as Ctrl-B, the text, then RETURN.  The game reads
one character a frame, so a 34-character caption takes about half a second to
appear - the timeline allows for it.

Usage:
    PC3_PORT=COM16 python Bas/ark_tools/walkthrough.py          run the tour
    PC3_PORT=COM16 python Bas/ark_tools/walkthrough.py --list   print it only

Start it with the game sitting on the title screen.
"""
import os
import sys
import time

import serial

PORT = os.environ.get("PC3_PORT", "COM16")
CHAR_GAP = 0.003

# ---------------------------------------------------------------- the script
# (seconds to wait BEFORE this step, key(s) to send, caption or None, note)
# A caption of "" clears nothing - it just is not sent.
TOUR = [
    (2.0,  None,   None, "title screen"),
    (14.0, None,   None, "...alternating with the high-score table"),
    (8.0,  " ",    None, "SPACE - start a game"),
    (5.0,  "A",    None, "bat on rails, so it plays itself"),
    (0.5,  " ",    None, "launch"),

    (1.0,  None,   "PICANOID   for the PicoMite", "what this is"),
    (7.0,  None,   "Bat, ball, bricks and capsules", None),
    (5.5,  None,   "at a steady 75 frames a second", None),
    (5.5,  None,   "A 75 Hz frame, never a dropped one", "the timing decision"),
    (6.0,  None,   "Mouse on the bat, like a spinner", None),
    (6.0,  None,   "Top row is silver: 2 hits now,", "silver bricks"),
    (5.5,  None,   "3 by round 9, 5 by round 25", None),
    (6.0,  None,   "Bat edges hit fast and shallow.", "the bat zones"),
    (5.5,  None,   "The middle returns it slow, steep", None),

    # --- the seven capsules, forced one at a time
    (5.0,  None,   "Seven capsules. One at a time -", "capsules"),
    (5.0,  None,   "each one cancels the last", None),
    (5.0,  "C",    "G - Grab. The ball sticks", None),
    (6.0,  "C",    "D - Disruption. Three balls", None),
    (8.0,  "C",    "E - Enlarge. A wider bat", None),
    (7.0,  "C",    "S - Slow. Down one speed step", None),
    (7.0,  "C",    "L - Laser. Fire shoots upward", None),
    (3.0,  " ",    None, "fire"),
    (1.2,  " ",    None, "fire"),
    (1.2,  " ",    None, "fire"),
    (1.2,  None,   "One shot can take TWO bricks", None),
    (5.0,  "C",    "B - Break. Opens the right wall", None),
    (7.0,  None,   "Drive into it: round over, 10000", None),
    (7.0,  "C",    "P - Player. An extra life", None),

    # --- enemies
    (7.0,  None,   "Two aliens, never more", "aliens"),
    (5.5,  None,   "always through the far door", None),
    (8.0,  None,   "Bat, ball or laser kills one", None),

    # --- a tour of the screens
    (6.0,  "N",    "Thirty-two screens", "round hop"),
    (4.0,  "N",    None, None),
    (4.0,  "N",    None, None),
    (4.0,  "N",    "Gold is indestructible", None),
    (5.0,  "N",    None, None),
    (4.0,  "N",    None, None),
    (4.0,  "N",    None, None),

    # --- the boss
    (4.0,  "Z",    "Round 32 is the boss", "the boss"),
    (4.0,  None,   "A face of solid gold bricks", None),
    (5.5,  None,   "Twenty hits, 1000 each", None),
    (6.0,  None,   "It throws things back at you", None),
    (12.0, None,   None, "let the auto-bat work on him"),

    # --- losing a life
    (8.0,  "N",    "Lose a ball and the speed resets", "death"),
    (2.0,  "A",    None, "bat off rails - the ball will be lost"),
    (10.0, "A",    None, "back on rails"),

    # --- game over and the high score
    (3.0,  "G",    None, "force a game over"),
    (7.0,  None,   None, "GAME OVER, then the name entry"),
    (3.0,  "PICOMITE", None, "type a name"),
    (2.0,  "\r",   None, "RETURN - into the table"),
    (4.0,  None,   None, "back to the attract screen, top of the table"),
    (12.0, None,   None, "done"),
]


def send(ser, text, gap=CHAR_GAP):
    for ch in text:
        ser.write(ch.encode("latin-1"))
        ser.flush()
        time.sleep(gap)


def caption(ser, text):
    send(ser, "\x02" + text + "\r")


def main():
    if "--list" in sys.argv:
        t = 0.0
        for wait, key, cap, note in TOUR:
            t += wait
            bits = []
            if key:
                bits.append("key %r" % key)
            if cap:
                bits.append('caption "%s"' % cap)
            if note:
                bits.append("(%s)" % note)
            print("%3d:%02d  %s" % (int(t) // 60, int(t) % 60, "  ".join(bits) or "-"))
        print("\ntotal %d:%02d" % (int(t) // 60, int(t) % 60))
        return

    ser = serial.Serial(PORT, 115200, timeout=0.2)
    time.sleep(0.4)
    ser.reset_input_buffer()
    t0 = time.time()
    print("Recording tour on %s.  Ctrl-C to stop.\n" % PORT)
    try:
        for wait, key, cap, note in TOUR:
            time.sleep(wait)
            stamp = time.time() - t0
            if cap:
                caption(ser, cap[:34])
            if key:
                send(ser, key)
            label = note or (cap if cap else (("key " + repr(key)) if key else ""))
            print("  %2d:%05.2f  %s" % (int(stamp) // 60, stamp % 60, label))
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        ser.close()
    print("\ntour finished after %.0f s" % (time.time() - t0))


if __name__ == "__main__":
    main()
