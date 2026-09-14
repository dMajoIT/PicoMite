"""Four envelopes and nine sound blocks, into PLAY BBC's own parameters.

OSWORD &07 blocks are already in PLAY BBC SOUND's order - channel word,
amplitude, pitch, duration, each a 16 bit little-endian word - so they
transcribe rather than translate.  OSWORD &08 blocks are PLAY BBC ENVELOPE's
fourteen parameters in order.

Two things in here are not transcription, and both are flagged in the
output.  See ENVELOPE_2_NOTE below.

  python gen_sound.py        emit the DATA fragment
"""
import thrustdata as td

BLOCKS = [
    ('own_gun', 'the ship firing'),
    ('explosion_1', 'explosion: the channel 1 tone that pitches the noise'),
    ('explosion_2', 'explosion: the noise itself'),
    ('hostile_gun', 'a limpet gun firing'),
    ('collect_1', 'picking something up'),
    ('collect_2', 'the second half of it'),
    ('engine', 'thrust, retriggered while the key is held'),
    ('countdown', 'the ten seconds after the reactor goes'),
    ('enter_orbit', 'leaving the planet'),
]

ENV_FIELD = ['n', 'T', 'PI1', 'PI2', 'PI3', 'PN1', 'PN2', 'PN3',
             'AA', 'AD', 'AS', 'AR', 'ALA', 'ALD']

ENVELOPE_2_NOTE = """
'  Envelope 2 is not quite the original's bytes, and here is why.
'
'  Its block in the source is thirteen bytes, not fourteen - the ENVELOPE
'  calls are 14, 13 and 14 bytes apart - so OSWORD 8 read its last parameter
'  out of the first byte of envelope 3.  The bytes it does have are
'
'      02 02 FF 00 01 09 09 09 00 00 00 01 01  (+03 from its neighbour)
'
'  which is AA=0 rising to ALA=1: the attack never gets off zero, so the
'  note is silent for its whole five seconds.  That is deliberate.  The
'  explosion is two notes - a tone on channel 1 and noise pitch 7 on
'  channel 0 - and pitch 7 clocks the noise from channel 1's pitch.  So
'  channel 1 is not there to be heard; it is there to be swept, and the
'  pitch envelope (-1 for 9 steps, 0 for 9, +1 for 9, repeating) is what
'  bends the noise.  An amplitude of 0 would have set the pitch too, but it
'  could not have swept it.
'
'  What does not carry across is AR=1.  A positive release makes no sense
'  to the BBC, which stops a note when the release reaches zero, but our
'  engine adds AR each step and would ramp this note up to full volume and
'  leave it there.  AR, ALA and ALD are zeroed below so the note stays
'  silent and ends cleanly.  The pitch sweep, which is the whole point, is
'  untouched."""


def word(b, i):
    """16 bit little-endian, signed - amplitudes are negative volumes."""
    v = b[i] | (b[i + 1] << 8)
    return v - 65536 if v > 32767 else v


def envelope(n):
    e = td.label('envelope_%d' % n)
    if n == 2 and len(e) == 13:
        e = e + [td.label('envelope_3')[0]]      # what OSWORD 8 read
    if len(e) != 14:
        raise SystemExit('envelope %d is %d bytes, not 14' % (n, len(e)))
    return [e[0], e[1]] + [td.signed(v) for v in e[2:5]] + list(e[5:8]) \
        + [td.signed(v) for v in e[8:12]] + list(e[12:14])


def data_lines():
    out = td.bar('Sound')
    out[2:2] = [
        "'  The original's four envelopes and nine sound blocks.  PLAY BBC",
        "'  ENVELOPE and PLAY BBC SOUND take the BBC's parameters unchanged,",
        "'  so these are its numbers.  An amplitude of 1 to 4 selects an",
        "'  envelope; a negative one is a plain volume."]
    out.append("'")
    out += ENVELOPE_2_NOTE.strip('\n').split('\n')
    out.append("' " + '=' * 70)
    out.append('SUB SndInit')
    out.append("  ' PLAY BBC arrived in V6.03.02b6.  On anything older these")
    out.append("  ' four fail, sndOK stays 0, and the game runs without sound")
    out.append("  ' rather than stopping with an error a player cannot read.")
    out.append('  sndOK = 0')
    out.append('  ON ERROR SKIP 4')
    for n in (1, 2, 3, 4):
        e = envelope(n)
        raw = ' '.join('%02X' % v for v in td.label('envelope_%d' % n))
        if n == 2:
            e = e[:11] + [0, 0, 0]                # AR, ALA, ALD - see above
            out.append("  ' %s  (+03), AR/ALA/ALD zeroed" % raw)
        else:
            out.append("  ' %s" % raw)
        out.append('  PLAY BBC ENVELOPE ' + ', '.join(str(v) for v in e))
    out.append('  IF MM.ERRNO = 0 THEN sndOK = 1')
    out.append('  ON ERROR CLEAR')
    out.append('END SUB')
    out.append('')
    out += td.bar('The nine sound blocks')
    for name, what in BLOCKS:
        b = td.label('sound_data_' + name)
        if len(b) != 8:
            raise SystemExit('%s is %d bytes, not 8' % (name, len(b)))
        chan, amp, pitch, dur = (word(b, 0), word(b, 2), word(b, 4),
                                 word(b, 6))
        ch = '&H%02X' % chan if chan & 0x10 else str(chan)
        bits = []
        if chan & 0x10:
            bits.append('flushed')
        bits.append('envelope %d' % amp if amp > 0 else
                    'silent' if amp == 0 else 'volume %d' % amp)
        out.append("' %-13s channel %d, %s" % (name + ':', chan & 3,
                                               ', '.join(bits)))
        out.append("'   %s" % what)
        out.append('SUB Snd%s' % ''.join(p.title() for p in name.split('_')))
        out.append('  IF sndOK = 0 THEN EXIT SUB')
        out.append('  PLAY BBC SOUND %s, %d, %d, %d' % (ch, amp, pitch, dur))
        out.append('END SUB')
        out.append('')
    return out


if __name__ == '__main__':
    lines = data_lines()
    td.emit(lines, 'sound.bas')
    print('\n'.join(lines))
