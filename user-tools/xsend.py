"""xsend.py PORT file.bas [--crunch] - send a program to a PicoMite by XMODEM.

    XMODEM RECEIVE with no filename loads straight into program memory, so
    there is no file and no LOAD step.  The firmware asks with NAK rather than
    'C' (XModem.c: "use NAK instead of 'C' to avoid printing"), so this is
    checksum mode, 128-byte blocks.

Much faster than pasting lines at the prompt, and - the reason it matters -
it is ACKNOWLEDGED.  A paste can fail silently and leave the previous program
running, which looks exactly like a successful run of the new one.
"""
import sys
import time
import serial

SOH, EOT, ACK, NAK, CAN = 0x01, 0x04, 0x06, 0x15, 0x18


def send(port, path, crunch=False, verbose=True):
    data = open(path, "rb").read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    s = serial.Serial(port, 115200, timeout=1.0)
    time.sleep(0.3)
    s.write(b"\r")
    time.sleep(0.4)
    s.reset_input_buffer()

    s.write(b"XMODEM C\r" if crunch else b"XMODEM RECEIVE\r")
    s.flush()

    # wait for the receiver's NAK
    t0 = time.time()
    while time.time() - t0 < 15:
        c = s.read(1)
        if c and c[0] == NAK:
            break
    else:
        s.close()
        raise SystemExit("error: no NAK from the board - is it at the prompt?")

    blocks = [data[i:i + 128] for i in range(0, len(data), 128)]
    for n, blk in enumerate(blocks, 1):
        blk = blk + b"\x00" * (128 - len(blk))      # NUL pad: the program store
        pkt = bytes([SOH, n & 0xFF, 255 - (n & 0xFF)]) + blk
        pkt += bytes([sum(blk) & 0xFF])
        for attempt in range(10):
            s.write(pkt)
            s.flush()
            c = s.read(1)
            if c and c[0] == ACK:
                break
            if c and c[0] == CAN:
                s.close()
                raise SystemExit("error: board cancelled at block %d" % n)
        else:
            s.close()
            raise SystemExit("error: block %d not acknowledged" % n)

    s.write(bytes([EOT]))
    s.flush()
    t0 = time.time()
    while time.time() - t0 < 10:
        c = s.read(1)
        if c and c[0] == ACK:
            break
    time.sleep(0.6)
    tail = s.read(4000).decode("latin-1")
    s.close()
    if verbose:
        print("sent %d bytes in %d blocks" % (len(data), len(blocks)))
        if tail.strip():
            print(tail.strip()[-200:])
    return len(blocks)


if __name__ == "__main__":
    send(sys.argv[1], sys.argv[2], "--crunch" in sys.argv)
