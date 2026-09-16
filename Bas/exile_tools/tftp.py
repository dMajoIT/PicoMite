"""tftp.py - put files on the PicoMite over its own TFTP server.

The WEB builds serve TFTP (net/MMtftp.c, lwIP's tftp server) straight onto the
board's drive, which is twenty to fifty times faster than XMODEM down the
console: the serial path manages about 5 KB/s, this manages 100-250 KB/s on a
quiet network.  The scene suite is some 3 MB, so that is the difference between
fourteen minutes and half a minute.

The server is plain RFC 1350: 512-byte blocks, one ACK a block, no option
negotiation (third_party_mod/tftp.c fixes TFTP_MAX_PAYLOAD_SIZE at 512), so the
round trip sets the rate and there is nothing to tune.

    send(host, 'sc_worm.bin', data)      write a file to the board's drive
    fetch(host, 'exile_put.txt')         read one back
"""
import socket
import struct
import time

PORT = 69
BLOCK = 512
RETRIES = 5
TIMEOUT = 2.0

RRQ, WRQ, DATA, ACK, ERROR = 1, 2, 3, 4, 5


class TftpError(Exception):
    pass


class TftpBusy(TftpError):
    """The server takes one transfer at a time and is still closing the last."""


def _request(sock, host, op, name):
    """Send RRQ/WRQ to the well-known port.  The reply comes from a fresh port
       which every later packet must go to, so the caller keeps the address."""
    pkt = struct.pack('!H', op) + name.encode() + b'\0octet\0'
    sock.sendto(pkt, (host, PORT))


def _unpack(pkt):
    op = struct.unpack('!H', pkt[:2])[0]
    if op == ERROR:
        code = struct.unpack('!H', pkt[2:4])[0]
        if b'one connection' in pkt[4:]:
            raise TftpBusy('the board is still closing the last transfer')
        raise TftpError("the board refused: %s (%d)" % (pkt[4:].split(b'\0')[0].decode('latin1'), code))
    return op, pkt[2:]


BUSY_WAITS = (0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 3.0, 5.0, 5.0, 5.0)


def _retry_busy(fn, *a):
    """The board serves one transfer at a time, so a transfer begun before the
       last one has finished is refused rather than queued.  Usually it needs a
       few milliseconds; if the final ACK of the previous transfer went missing
       it sits retransmitting until its own timeout, which is seconds, so the
       ladder has to reach that far.  Every attempt is inside the guard,
       including the last, or a busy board comes back as a traceback."""
    last = None
    for wait in BUSY_WAITS:
        try:
            return fn(*a)
        except TftpBusy as e:
            last = e
            time.sleep(wait)
    raise TftpError("the board stayed busy for %.0f s: another transfer is stuck, "
                    "or something else is talking to it (%s)" % (sum(BUSY_WAITS), last))


def send(host, name, data, timeout=TIMEOUT):
    """Write data to the board as `name`, overwriting whatever is there."""
    return _retry_busy(_send, host, name, data, timeout)


def fetch(host, name, timeout=TIMEOUT):
    """Read `name` back off the board."""
    return _retry_busy(_fetch, host, name, timeout)


def _send(host, name, data, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        peer = None
        for attempt in range(RETRIES):
            _request(sock, host, WRQ, name)
            try:
                pkt, peer = sock.recvfrom(1024)
            except socket.timeout:
                continue
            op, body = _unpack(pkt)
            if op == ACK and struct.unpack('!H', body[:2])[0] == 0:
                break
            raise TftpError("expected an ACK of block 0, got opcode %d" % op)
        else:
            raise TftpError("no answer from %s: is it on the network and is TFTP enabled?" % host)

        block = 0
        off = 0
        while True:
            block = (block + 1) & 0xFFFF
            chunk = data[off:off + BLOCK]
            pkt = struct.pack('!HH', DATA, block) + chunk
            for attempt in range(RETRIES):
                sock.sendto(pkt, peer)
                try:
                    reply, _ = sock.recvfrom(1024)
                except socket.timeout:
                    continue
                op, body = _unpack(reply)
                if op == ACK and struct.unpack('!H', body[:2])[0] == block:
                    break
            else:
                raise TftpError("no ACK for block %d of %s" % (block, name))
            off += len(chunk)
            if len(chunk) < BLOCK:
                return len(data)
    finally:
        sock.close()


def _fetch(host, name, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        out = bytearray()
        want = 1
        peer = None
        for attempt in range(RETRIES):
            _request(sock, host, RRQ, name)
            try:
                pkt, peer = sock.recvfrom(1024)
                break
            except socket.timeout:
                continue
        else:
            raise TftpError("no answer from %s" % host)
        while True:
            op, body = _unpack(pkt)
            if op != DATA:
                raise TftpError("expected data, got opcode %d" % op)
            block = struct.unpack('!H', body[:2])[0]
            chunk = body[2:]
            if block == want:
                out += chunk
                want = (want + 1) & 0xFFFF
            sock.sendto(struct.pack('!HH', ACK, block), peer)
            if len(chunk) < BLOCK:
                return bytes(out)
            for attempt in range(RETRIES):
                try:
                    pkt, peer = sock.recvfrom(1024)
                    break
                except socket.timeout:
                    sock.sendto(struct.pack('!HH', ACK, block), peer)
            else:
                raise TftpError("the board stopped sending after block %d" % block)
    finally:
        sock.close()
