"""
Read and change the settings of an HM-10 Bluetooth LE serial module, or of
one of the BT05 clones sold as HM-10s.

The module is configured with AT commands over its own serial port (its TX
and RX pins), through a USB to serial adapter at 3.3 V levels. It takes AT
commands only while nothing is connected to it over Bluetooth: on a genuine
HM-10 an AT command sent while it is connected drops the link instead. So
disconnect it first (BLUETOOTH DISCONNECT SERIAL on the PicoMite, or switch
the PicoMite off).

Two kinds of firmware are understood, and told apart by themselves:
- genuine HM-10 ("HMSoft"): AT answers OK, commands need no line ending,
  queries end in "?" (AT+NAME?) and replies look like OK+Get:0;
- BT05 clones (MLT-BT05, AT-09, many "HM-10"s): commands end with CR LF,
  queries have no "?" (AT+NAME) and replies look like +NAME=BT05. Beware
  that such a module takes AT+NAME? as setting its name to "?" - this
  script never sends that, but --raw does what it is told. A BT05 also
  needs about a second after each change before it hears the next command.
Other clones (CC41-A, JDY...) are reported, and only --raw works for them.

Usage:
    python hm10_config.py COM5                    show the settings
    python hm10_config.py COM5 --name PicoGPS     set the name it advertises
    python hm10_config.py COM5 --baud 115200      set its serial baud rate
    python hm10_config.py COM5 --type 0           no PIN (what the PicoMite needs)
    python hm10_config.py COM5 --pin 123456
    python hm10_config.py COM5 --raw "AT+ADVI?"   send any command
    python hm10_config.py COM5 --factory          back to the factory settings
    python hm10_config.py COM5 --terminal         pass data both ways (test the link)

The baud rate is found by itself (it tries every rate the module supports,
9600 first, which is the factory setting); --at gives the rate to try first.
Changed settings take effect when the module restarts, which the script
does at the end (AT+RESET), and then it shows the settings again.

For use with a PicoMite (BLUETOOTH CONNECT on a PicoMiteRP2350BTH or
PicoMiteHDMIBTH), leave the module a peripheral (--role 0) and without a PIN
(--type 0): the PicoMite has no way to type in a module's PIN. The module
then shows up in BLUETOOTH SCAN as "BLE serial" under its name, and its
serial port is the PicoMite's COM7.
"""

import argparse
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("This needs pyserial:  pip install pyserial")

TRY_ORDER = [9600, 115200, 57600, 38400, 19200, 4800, 2400, 1200, 230400]

ROLES = {"0": "peripheral (slave) - what the PicoMite connects to",
         "1": "central (master)"}
HM_TYPES = {"0": "no PIN",
            "1": "pairing without a PIN",
            "2": "pairing with the PIN",
            "3": "pairing with the PIN, and bonding"}
HM_POWERS = {"0": "-23 dBm", "1": "-6 dBm", "2": "0 dBm", "3": "6 dBm"}
HM_ADV = {"0": "100 ms", "1": "152.5 ms", "2": "211.25 ms", "3": "318.75 ms",
          "4": "417.5 ms", "5": "546.25 ms", "6": "760 ms", "7": "852.5 ms",
          "8": "1022.5 ms", "9": "1285 ms", "A": "2 s", "B": "3 s", "C": "4 s",
          "D": "5 s", "E": "6 s", "F": "7 s"}
HM_NOTIFY = {"0": "off",
             "1": "on (OK+CONN and OK+LOST on its serial port when a central "
                  "connects and disconnects)"}


class Dialect:
    """How one kind of firmware is spoken to."""

    def __init__(self, name, eol, query_fmt, sep, bauds, queries, settings, set_gap, factory):
        self.name = name
        self.eol = eol
        self.query_fmt = query_fmt  # e.g. "AT+{}?" or "AT+{}"
        self.sep = sep              # what comes before the value in a reply
        self.bauds = bauds          # baud rate -> AT+BAUD code
        self.queries = queries      # (label, keyword, meanings or None or "baud")
        self.settings = settings    # option -> keyword (None: not on this firmware)
        self.set_gap = set_gap      # seconds to leave after a change
        self.factory = factory      # the factory-reset keyword

    def value(self, reply):
        """The value from a reply: 'OK+Get:0' -> '0', '+NAME=BT05' -> 'BT05'."""
        for line in reply.replace("\r", "\n").split("\n"):
            line = line.strip()
            if self.sep in line:
                return line.split(self.sep, 1)[1].strip()
        return reply.strip()

    def accepted(self, reply):
        r = reply.strip()
        return bool(r) and "ERROR" not in r.upper() and (r.startswith("OK") or r.startswith("+"))


HMSOFT = Dialect(
    "HMSoft (genuine HM-10)", "", "AT+{}?", ":",
    {9600: 0, 19200: 1, 38400: 2, 57600: 3, 115200: 4, 4800: 5, 2400: 6, 1200: 7, 230400: 8},
    [("Name", "NAME", None), ("Address", "ADDR", None), ("Firmware", "VERR", None),
     ("Baud rate", "BAUD", "baud"), ("Role", "ROLE", ROLES), ("Security", "TYPE", HM_TYPES),
     ("PIN", "PASS", None), ("Connect notices", "NOTI", HM_NOTIFY),
     ("Transmit power", "POWE", HM_POWERS), ("Advertising interval", "ADVI", HM_ADV),
     ("Service UUID", "UUID", None), ("Characteristic UUID", "CHAR", None)],
    {"name": "NAME", "pin": "PASS", "type": "TYPE", "role": "ROLE", "notify": "NOTI",
     "power": "POWE", "adv": "ADVI", "baud": "BAUD"},
    0.05, "RENEW")

BT05 = Dialect(
    "BT05 clone", "\r\n", "AT+{}", "=",
    {1200: 1, 2400: 2, 4800: 3, 9600: 4, 19200: 5, 38400: 6, 57600: 7, 115200: 8},
    [("Name", "NAME", None), ("Address", "LADDR", None), ("Firmware", "VERSION", None),
     ("Baud rate", "BAUD", "baud"), ("Role", "ROLE", ROLES), ("Security type", "TYPE", None),
     ("PIN", "PIN", None), ("Transmit power", "POWE", None),
     ("Advertising interval", "ADVI", None), ("Service UUID", "UUID", None),
     ("Characteristic UUID", "CHAR", None)],
    {"name": "NAME", "pin": "PIN", "type": "TYPE", "role": "ROLE", "notify": None,
     "power": "POWE", "adv": "ADVI", "baud": "BAUD"},
    1.0, "RENEW")


def transfer(ser, cmd, eol="", timeout=1.5, quiet=0.15, gap=0.05):
    """Send one command and return the reply, read until the module is quiet.

    HMSoft tells a command's end by a pause, not a terminator, so the command
    goes out in one write and nothing else follows it until the reply."""
    ser.reset_input_buffer()
    ser.write((cmd + eol).encode("ascii"))
    reply = b""
    start = last = time.time()
    while True:
        chunk = ser.read(ser.in_waiting or 1)
        now = time.time()
        if chunk:
            reply += chunk
            last = now
        elif reply and now - last >= quiet:
            break
        if now - start >= timeout:
            break
    time.sleep(gap)
    return reply.decode("ascii", errors="replace")


def open_port(port, baud):
    ser = serial.Serial(port, baud, timeout=0.05, write_timeout=2)
    time.sleep(0.1)
    ser.reset_input_buffer()
    return ser


def find_module(port, first=None):
    """Find the baud rate and the firmware. Returns (serial, baud, dialect or None)."""
    order = TRY_ORDER if first is None else [first] + [b for b in TRY_ORDER if b != first]
    for eol in ("", "\r\n"):
        for baud in order:
            try:
                ser = open_port(port, baud)
            except serial.SerialException as e:
                sys.exit("Cannot open %s: %s" % (port, e))
            reply = transfer(ser, "AT", eol=eol, timeout=0.6, gap=0.1)
            if reply.strip().startswith("OK"):
                if "LOST" in reply:
                    print("(the module was connected over Bluetooth; that link has been dropped)")
                if eol == "":
                    return ser, baud, HMSOFT
                if "+VERSION=" in transfer(ser, "AT+VERSION", eol=eol, gap=0.1):
                    return ser, baud, BT05
                return ser, baud, None
            ser.close()
    sys.exit("No answer to AT on %s at any baud rate.\n"
             "Check the wiring (adapter TX to module RX and RX to TX, 3.3 V, GND), "
             "and that nothing is connected to the module over Bluetooth "
             "(its LED blinks while it is free and is steady while connected)." % port)


def query(ser, d, keyword):
    return transfer(ser, d.query_fmt.format(keyword), eol=d.eol)


def show_settings(ser, baud, d):
    print("Found a %s module at %d baud." % (d.name, baud))
    codes = {v: k for k, v in d.bauds.items()}
    for label, keyword, meaning in d.queries:
        reply = query(ser, d, keyword)
        if not reply and keyword == "VERR":
            reply = query(ser, d, "VERS")  # the other spelling, on some HMSoft versions
        if not reply.strip() or "ERROR" in reply.upper():
            print("  %-22s (no answer)" % label)
            continue
        v = d.value(reply)
        if meaning == "baud":
            try:
                v = "%s (%d)" % (v, codes[int(v)])
            except (ValueError, KeyError):
                pass
        elif isinstance(meaning, dict) and v.upper() in meaning:
            v = "%s - %s" % (v, meaning[v.upper()])
        print("  %-22s %s" % (label, v))


def change(ser, d, keyword, value, what):
    cmd = "AT+" + keyword + value
    reply = transfer(ser, cmd, eol=d.eol, gap=d.set_gap)
    ok = d.accepted(reply)
    print("  %-26s %s%s" % (cmd, " ".join(reply.split()) or "(no answer)", "" if ok else "   <- not accepted"))
    if not ok:
        sys.exit("The module did not accept %s." % what)


def restart(ser, port, baud, d):
    """AT+RESET, then find the module again (it takes a moment to start)."""
    transfer(ser, "AT+RESET", eol=d.eol, timeout=1.0, gap=0.1)
    ser.close()
    time.sleep(1.5)
    return find_module(port, baud)


def terminal(ser, d):
    """Pass lines typed here to the module, and print what it sends."""
    print("Terminal at %d baud: each line typed is sent with CR LF; Ctrl-C ends." % ser.baudrate)
    print("While a PicoMite is connected, what is typed here reaches its COM7 and its PRINT #")
    print("output appears here. Do not type AT: while connected that drops the link.")
    if d is BT05:
        print("A BT05 echoes each line sent as TX=... on its own serial port; the PicoMite gets")
        print("only the line itself.")
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            data = ser.read(ser.in_waiting or 1)
            if data:
                sys.stdout.write(data.decode("latin-1"))
                sys.stdout.flush()

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    try:
        while True:
            line = input()
            ser.write((line + "\r\n").encode("latin-1"))
    except (KeyboardInterrupt, EOFError):
        pass
    finally:
        stop.set()
        t.join(0.5)


def main():
    ap = argparse.ArgumentParser(description="Read and change the settings of an HM-10 BLE module, "
                                             "or a BT05 clone, over its serial port.")
    ap.add_argument("port", help="the USB serial adapter's port, e.g. COM5 or /dev/ttyUSB0")
    ap.add_argument("--at", type=int, metavar="BAUD", help="try this baud rate first")
    ap.add_argument("--name", help="advertised name, 1 to 12 characters")
    ap.add_argument("--baud", type=int, choices=sorted(set(HMSOFT.bauds) | set(BT05.bauds)),
                    help="serial baud rate (230400 on HMSoft only)")
    ap.add_argument("--type", choices=sorted(HM_TYPES), help="security (HMSoft: " +
                    ", ".join("%s %s" % kv for kv in sorted(HM_TYPES.items())) + "; 0 is no PIN on both)")
    ap.add_argument("--pin", help="the PIN, six digits")
    ap.add_argument("--role", choices=sorted(ROLES), help="0 peripheral, 1 central")
    ap.add_argument("--notify", choices=sorted(HM_NOTIFY), help="HMSoft only: 1 for OK+CONN / OK+LOST "
                    "on its serial port")
    ap.add_argument("--power", choices=sorted(HM_POWERS), help="transmit power code (HMSoft: " +
                    ", ".join("%s %s" % kv for kv in sorted(HM_POWERS.items())) + ")")
    ap.add_argument("--adv", metavar="0-F", help="advertising interval code (HMSoft: 0 = 100 ms ... F = 7 s)")
    ap.add_argument("--raw", action="append", metavar="CMD", help="send this command and show the reply "
                    "(can be repeated); on a BT05 a query has no '?'")
    ap.add_argument("--factory", action="store_true", help="factory settings (AT+RENEW)")
    ap.add_argument("--terminal", action="store_true", help="afterwards, pass data both ways")
    a = ap.parse_args()

    if a.name is not None and not (1 <= len(a.name) <= 12 and all(32 < ord(c) < 127 for c in a.name)):
        sys.exit("--name must be 1 to 12 printable characters without spaces")
    if a.pin is not None and not (len(a.pin) == 6 and a.pin.isdigit()):
        sys.exit("--pin must be six digits")
    if a.adv is not None and a.adv.upper() not in HM_ADV:
        sys.exit("--adv must be one hexadecimal digit, 0 to F")

    ser, baud, d = find_module(a.port, a.at)
    if d is None:
        print("Found a module at %d baud that answers only with a line ending, but not as a BT05 "
              "does: another clone (CC41-A, JDY...). Only --raw is used, with CR LF." % baud)
        for cmd in a.raw or []:
            print("  %-26s %s" % (cmd, " ".join(transfer(ser, cmd, eol="\r\n").split()) or "(no answer)"))
        if a.terminal:
            terminal(ser, None)
        ser.close()
        return

    for cmd in a.raw or []:
        reply = transfer(ser, cmd, eol=d.eol, gap=d.set_gap)
        print("  %-26s %s" % (cmd, " ".join(reply.split()) or "(no answer)"))

    if a.factory:
        print("Restoring the factory settings:")
        change(ser, d, d.factory, "", "the factory reset")
        ser, baud, d = restart(ser, a.port, 9600, d)

    changed = False
    new_baud = baud
    for opt, value, what in (("name", a.name, "the name"), ("type", a.type, "the security type"),
                             ("pin", a.pin, "the PIN"), ("role", a.role, "the role"),
                             ("notify", a.notify, "the connect notices"),
                             ("power", a.power, "the transmit power"),
                             ("adv", a.adv.upper() if a.adv else None, "the advertising interval")):
        if value is None:
            continue
        keyword = d.settings[opt]
        if keyword is None:
            sys.exit("--%s is not available on %s firmware." % (opt, d.name))
        if opt == "role" and value == "1":
            print("  Note: as a central the module looks for devices itself; a PicoMite cannot connect to it.")
        change(ser, d, keyword, value, what)
        changed = True
    if a.baud is not None and a.baud != baud:
        if a.baud not in d.bauds:
            sys.exit("%d baud is not available on %s firmware." % (a.baud, d.name))
        change(ser, d, d.settings["baud"], str(d.bauds[a.baud]), "the baud rate")
        new_baud = a.baud
        changed = True

    if changed:
        print("Restarting the module to apply the changes...")
        ser, baud, d2 = restart(ser, a.port, new_baud, d)
        if baud != new_baud:
            print("  Note: the module came back at %d baud, not %d." % (baud, new_baud))
        d = d2 or d
    show_settings(ser, baud, d)
    if a.terminal:
        terminal(ser, d)
    ser.close()


if __name__ == "__main__":
    main()
