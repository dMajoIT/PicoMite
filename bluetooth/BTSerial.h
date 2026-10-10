/*
 * BTSerial.h - a Bluetooth Classic serial device (Serial Port Profile over
 * RFCOMM) as COM7, for the BT host builds (PICOMITEBTH, PICOMITEHDMIBTH).
 *
 * BLUETOOTH CONNECT pairs a device whose SDP records offer a serial port and
 * remembers it. OPEN "COM7:" then works as it does for a USB CDC port:
 * received bytes go to the port's buffer (or the GPS decoder with AS GPS),
 * and while the port is open a device that drops out is reconnected.
 */
#ifndef BTSERIAL_H
#define BTSERIAL_H
#if defined(PICOMITEBTH) || defined(PICOMITEHDMIBTH)
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Initialises RFCOMM. Called from bt_audio_init(), after sdp_init() and
   before HCI is powered on. */
void bt_serial_init(void);

/* True for the remembered serial device's address. */
bool bt_serial_is_remembered(const uint8_t *addr);

/* BLUETOOTH CONNECT: finds the device's serial port in its SDP records,
   connects and pairs it. Returns false when it has no serial port (the
   caller then tries it as a speaker); reports failure with error().
   Interpreter context. */
bool bt_serial_connect(const uint8_t *addr);

/* BLUETOOTH DISCONNECT SERIAL: drops the link; it is not reconnected until
   COM7 is opened again or the next CONNECT. Interpreter context. */
void bt_serial_disconnect(void);

/* True while CONNECT is pairing this address: BTAudio.c's pairing handler
   leaves the request to this module. */
bool bt_serial_owns_pairing(const uint8_t *addr);

/* MM.INFO(BLUETOOTH SERIAL): the connected device's address, or "". */
void bt_serial_address(char *buf);

/* BLUETOOTH STATUS: one line describing the serial device. */
void bt_serial_status(char *buf, int len);

/* BLUETOOTH FORGET (addr NULL = all): drop the device's link if it is the
   one, and forget it. Call with the async-context lock held. */
void bt_serial_forget(const uint8_t *addr);

/* COM7, from Serial.c (interpreter context) */
bool bt_serial_known(void);      /* connected, or remembered */
void bt_serial_port_opened(void); /* reconnect it while the port is open */
void bt_serial_port_closed(void);
bool bt_serial_putc(uint8_t c);   /* false: the send buffer is full, try again */
int bt_serial_tx_pending(void);

#ifdef __cplusplus
}
#endif

#endif /* PICOMITEBTH || PICOMITEHDMIBTH */
#endif /* BTSERIAL_H */
