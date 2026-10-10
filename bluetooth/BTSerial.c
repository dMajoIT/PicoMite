/*
 * BTSerial.c - a Bluetooth Classic serial device (Serial Port Profile over
 * RFCOMM) as COM7, for the BT host builds (PICOMITEBTH, PICOMITEHDMIBTH):
 * a Bluetooth GPS, say.
 *
 * BLUETOOTH SCAN finds the device and BLUETOOTH CONNECT name$ calls
 * bt_serial_connect() for anything that is neither audio nor a keyboard.
 * That asks the device's SDP server for a Serial Port record (UUID 0x1101,
 * searched by its class: such records may have no browse group) and its
 * RFCOMM channel. A device without one is left to the speaker code. The
 * channel is opened at btstack's default security level 2, so the device
 * is paired - legacy PIN "0000", or Just Works - while CONNECT runs, and
 * the address and channel are remembered in the bond store.
 *
 * COM7 then behaves as a USB CDC port does (Serial.c): received bytes go to
 * the port's buffer, or to the NMEA decoder with OPEN ... AS GPS; sent
 * bytes are buffered here and go out when btstack can send. The baud rate
 * is accepted and ignored. While COM7 is open, the remembered device is
 * reconnected when it is not connected - at OPEN, and after a drop-out,
 * retrying at intervals doubling from 5 s to a minute (each attempt pages
 * for at most 5.12 s) - and a program sees nothing but a gap in the data.
 * A closed port pages nothing, and a link left up by CLOSE stays up.
 *
 * Threading: the handlers run in btstack's context inside cyw43_arch_poll()
 * (bt_keyboard_poll) and never print - console messages go through
 * bt_notice(). The interpreter takes the async-context lock around btstack
 * calls. The send buffer is filled by the interpreter and drained by the
 * handlers; both run on core 0's main thread, the handlers only inside the
 * poll, so neither interrupts the other.
 */
#if defined(PICOMITEBTH) || defined(PICOMITEHDMIBTH)

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>

#include "configuration.h"
#include "MMBasic_Includes.h"
#include "Hardware_Includes.h"

#include "pico/cyw43_arch.h"
#undef UNUSED
#include "btstack.h"
#include "btstack_tlv.h"

#include "BTSerial.h"
#include "BTAudio.h"
#include "BTKeyboard.h"

#define SP_TLV_TAG 0x42545350u /* 'BTSP': the remembered device's address and RFCOMM channel */
#define SP_QUERY_TIMEOUT_MS 20000
#define SP_CONNECT_TIMEOUT_MS 30000
#define SP_RECONNECT_FIRST_MS 10
#define SP_RECONNECT_MIN_RETRY_MS 5000
#define SP_RECONNECT_MAX_RETRY_MS 60000
#define SP_TX_SIZE 256

typedef enum
{
    SP_NONE,
    SP_QUERYING,   /* CONNECT: asking for the serial port's RFCOMM channel */
    SP_CONNECTING, /* rfcomm_create_channel() issued */
    SP_CONNECTED,
} sp_state_t;

typedef struct
{
    uint8_t addr[6];
    uint8_t channel;
} sp_remembered_t;

static volatile sp_state_t sp_state;
static bd_addr_t sp_addr;          /* the device connecting or connected */
static uint8_t sp_channel;         /* its RFCOMM server channel */
static uint16_t sp_cid;
static uint16_t sp_frame_size;     /* the largest RFCOMM frame it takes */
static volatile uint8_t sp_last_status;
static volatile bool sp_pairing;   /* CONNECT running: pairing allowed with sp_addr */
static volatile bool sp_quiet_close; /* our own disconnect: no message, no reconnect */
static sp_remembered_t sp_remembered;
static bool sp_have_remembered;
static volatile uint32_t sp_received, sp_sent; /* bytes, since connecting (BLUETOOTH STATUS) */

/* While COM7 is open (bt_serial_port_opened), the remembered device is
   reconnected. */
static volatile bool sp_auto;
static btstack_timer_source_t sp_timer;
static uint32_t sp_retry_ms;

/* Bytes for the device: the interpreter moves the head, the handlers the tail. */
static uint8_t sp_tx_buf[SP_TX_SIZE];
static volatile uint16_t sp_tx_head, sp_tx_tail;
static volatile bool sp_send_requested;

static btstack_packet_callback_registration_t sp_hci_registration;

static void sp_rfcomm_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size);

static inline void sp_lock(void)
{
    async_context_acquire_lock_blocking(cyw43_arch_async_context());
}

static inline void sp_unlock(void)
{
    async_context_release_lock(cyw43_arch_async_context());
}

bool bt_serial_is_remembered(const uint8_t *addr)
{
    return sp_have_remembered && memcmp(addr, sp_remembered.addr, sizeof(bd_addr_t)) == 0;
}

bool bt_serial_owns_pairing(const uint8_t *addr)
{
    return sp_pairing && memcmp(addr, sp_addr, sizeof(bd_addr_t)) == 0;
}

static void sp_remember(void)
{
    if (sp_have_remembered && bt_serial_is_remembered(sp_addr) && sp_remembered.channel == sp_channel)
        return; /* unchanged - no bond-store write */
    memcpy(sp_remembered.addr, sp_addr, sizeof(bd_addr_t));
    sp_remembered.channel = sp_channel;
    sp_have_remembered = true;
    const btstack_tlv_t *tlv;
    void *ctx;
    btstack_tlv_get_instance(&tlv, &ctx);
    if (tlv)
        tlv->store_tag(ctx, SP_TLV_TAG, (const uint8_t *)&sp_remembered, sizeof(sp_remembered));
}

/* ============================================================================
 * Sending (btstack context)
 * ============================================================================
 */
/* Ask for RFCOMM_EVENT_CAN_SEND_NOW. btstack may deliver it inside this call,
   and the handler clears the flag, so the flag is set first. */
static void sp_request_send(void)
{
    sp_send_requested = true;
    if (rfcomm_request_can_send_now_event(sp_cid) != ERROR_CODE_SUCCESS)
        sp_send_requested = false;
}

static void sp_send(void)
{
    if (sp_state != SP_CONNECTED)
        return;
    uint16_t head = sp_tx_head, tail = sp_tx_tail;
    if (head == tail)
        return;
    uint16_t n = head > tail ? head - tail : SP_TX_SIZE - tail; /* the contiguous part */
    if (n > sp_frame_size)
        n = sp_frame_size;
    if (rfcomm_send(sp_cid, &sp_tx_buf[tail], n) == ERROR_CODE_SUCCESS)
    {
        sp_tx_tail = (uint16_t)((tail + n) % SP_TX_SIZE);
        sp_sent += n;
    }
    if (sp_tx_head != sp_tx_tail)
        sp_request_send();
}

/* ============================================================================
 * Reconnecting while COM7 is open (btstack context)
 * ============================================================================
 */
static void sp_reconnect_timeout(btstack_timer_source_t *ts)
{
    if (!sp_auto)
        return;
    if (sp_have_remembered && sp_state == SP_NONE && !bt_audio_inquiry_busy())
    {
        uint16_t cid;
        memcpy(sp_addr, sp_remembered.addr, sizeof(bd_addr_t));
        sp_channel = sp_remembered.channel;
        if (rfcomm_create_channel(&sp_rfcomm_handler, sp_addr, sp_channel, &cid) == ERROR_CODE_SUCCESS)
        {
            sp_cid = cid;
            sp_last_status = 0;
            sp_state = SP_CONNECTING;
        }
    }
    btstack_run_loop_set_timer(ts, sp_retry_ms);
    btstack_run_loop_add_timer(ts);
    sp_retry_ms *= 2;
    if (sp_retry_ms > SP_RECONNECT_MAX_RETRY_MS)
        sp_retry_ms = SP_RECONNECT_MAX_RETRY_MS;
}

static void sp_reconnect_after(uint32_t first_ms)
{
    if (!sp_auto)
        return;
    sp_retry_ms = SP_RECONNECT_MIN_RETRY_MS;
    btstack_run_loop_remove_timer(&sp_timer);
    btstack_run_loop_set_timer_handler(&sp_timer, sp_reconnect_timeout);
    btstack_run_loop_set_timer(&sp_timer, first_ms);
    btstack_run_loop_add_timer(&sp_timer);
}

/* ============================================================================
 * btstack handlers
 * ============================================================================
 */
static void sp_rfcomm_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size)
{
    if (packet_type == RFCOMM_DATA_PACKET)
    {
        if (channel == sp_cid && sp_state == SP_CONNECTED)
        {
            sp_received += size;
            SerialBTReceive(packet, size);
        }
        return;
    }
    if (packet_type != HCI_EVENT_PACKET)
        return;

    switch (hci_event_packet_get_type(packet))
    {
    case RFCOMM_EVENT_CHANNEL_OPENED:
    {
        if (rfcomm_event_channel_opened_get_rfcomm_cid(packet) != sp_cid || sp_state != SP_CONNECTING)
            break;
        uint8_t status = rfcomm_event_channel_opened_get_status(packet);
        bool was_pairing = sp_pairing;
        sp_pairing = false;
        if (status != ERROR_CODE_SUCCESS)
        {
            sp_last_status = status;
            sp_state = SP_NONE;
            break; /* a reconnect: the timer tries again */
        }
        sp_frame_size = rfcomm_event_channel_opened_get_max_frame_size(packet);
        sp_received = sp_sent = 0;
        sp_tx_tail = sp_tx_head; /* nothing older than the connection */
        sp_send_requested = false;
        sp_state = SP_CONNECTED;
        if (was_pairing)
            sp_remember(); /* here, not in CONNECT: Ctrl-C may have left it */
        else if (!CurrentLinePtr)
            bt_notice("Bluetooth serial device connected (COM7)\r\n> ");
        break;
    }

    case RFCOMM_EVENT_CHANNEL_CLOSED:
    {
        if (rfcomm_event_channel_closed_get_rfcomm_cid(packet) != sp_cid)
            break;
        bool was_connected = sp_state == SP_CONNECTED;
        sp_state = SP_NONE;
        sp_pairing = false;
        sp_send_requested = false;
        sp_tx_tail = sp_tx_head;
        if (was_connected && !sp_quiet_close)
        {
            if (!CurrentLinePtr)
                bt_notice("Bluetooth serial device disconnected (COM7)\r\n> ");
            sp_reconnect_after(SP_RECONNECT_MIN_RETRY_MS); /* switched off, or out of range */
        }
        sp_quiet_close = false;
        break;
    }

    case RFCOMM_EVENT_CAN_SEND_NOW:
        if (rfcomm_event_can_send_now_get_rfcomm_cid(packet) != sp_cid)
            break;
        sp_send_requested = false;
        sp_send();
        break;

    default:
        break;
    }
}

/* CONNECT's SDP query: the first Serial Port record's RFCOMM channel. */
static void sp_sdp_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size)
{
    (void)channel;
    (void)size;
    if (packet_type != HCI_EVENT_PACKET)
        return;
    switch (hci_event_packet_get_type(packet))
    {
    case SDP_EVENT_QUERY_RFCOMM_SERVICE:
        if (sp_channel == 0)
            sp_channel = sdp_event_query_rfcomm_service_get_rfcomm_channel(packet);
        break;
    case SDP_EVENT_QUERY_COMPLETE:
        sp_last_status = sdp_event_query_complete_get_status(packet);
        if (sp_state == SP_QUERYING)
            sp_state = SP_NONE;
        break;
    default:
        break;
    }
}

/* Pairing requests for the device CONNECT is pairing; BTAudio.c's handler
   leaves these alone (bt_serial_owns_pairing). */
static void sp_hci_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size)
{
    (void)channel;
    (void)size;
    if (packet_type != HCI_EVENT_PACKET)
        return;
    bd_addr_t addr;

    switch (hci_event_packet_get_type(packet))
    {
    case BTSTACK_EVENT_STATE:
        if (btstack_event_state_get_state(packet) == HCI_STATE_WORKING)
        {
            const btstack_tlv_t *tlv;
            void *ctx;
            btstack_tlv_get_instance(&tlv, &ctx);
            if (tlv && tlv->get_tag(ctx, SP_TLV_TAG, (uint8_t *)&sp_remembered,
                                    sizeof(sp_remembered)) == sizeof(sp_remembered))
                sp_have_remembered = true;
        }
        break;

    case HCI_EVENT_PIN_CODE_REQUEST:
        /* Legacy pairing: serial devices, GPS receivers among them, take "0000". */
        hci_event_pin_code_request_get_bd_addr(packet, addr);
        if (bt_serial_owns_pairing(addr))
            gap_pin_code_response(addr, "0000");
        break;

    case HCI_EVENT_USER_CONFIRMATION_REQUEST:
        /* Secure Simple Pairing, Just Works. */
        hci_event_user_confirmation_request_get_bd_addr(packet, addr);
        if (bt_serial_owns_pairing(addr))
            gap_ssp_confirmation_response(addr);
        break;

    default:
        break;
    }
}

void bt_serial_init(void)
{
    sp_state = SP_NONE;
    rfcomm_init();
    sp_hci_registration.callback = &sp_hci_handler;
    hci_add_event_handler(&sp_hci_registration);
}

/* ============================================================================
 * BLUETOOTH CONNECT, DISCONNECT SERIAL, STATUS, FORGET and MM.INFO
 * ============================================================================
 */
/* Wait in the interpreter while the state stays as it is, keeping Ctrl-C
   and the background services alive. Returns false on timeout. */
static bool sp_wait_while(sp_state_t state, uint32_t timeout_ms)
{
    uint64_t end = time_us_64() + (uint64_t)timeout_ms * 1000u;
    while (sp_state == state)
    {
        CheckAbort();
        if (time_us_64() > end)
            return false;
    }
    return true;
}

/* error() with a btstack status code ('&' is error()'s float placeholder,
   so the hex is formatted here). */
static void sp_error_status(const char *what, uint8_t status)
{
    char buf[64];
    snprintf(buf, sizeof(buf), "%s (Bluetooth error 0x%02X)", what, status);
    error("$", buf);
}

bool bt_serial_connect(const uint8_t *addr)
{
    if (sp_state != SP_NONE)
        error(sp_state == SP_CONNECTED ? "Serial device already connected" : "Serial device already connecting");

    /* Its serial port, if it has one. The SDP client serves one query at a
       time; a keyboard or speaker connecting may hold it briefly. */
    uint64_t end = time_us_64() + 5000000u;
    uint8_t status;
    for (;;)
    {
        sp_lock();
        status = SDP_QUERY_BUSY;
        if (sdp_client_ready())
        {
            memcpy(sp_addr, addr, sizeof(bd_addr_t));
            sp_channel = 0;
            sp_last_status = 0;
            status = sdp_client_query_rfcomm_channel_and_name_for_service_class_uuid(
                &sp_sdp_handler, sp_addr, BLUETOOTH_SERVICE_CLASS_SERIAL_PORT);
            if (status == ERROR_CODE_SUCCESS)
                sp_state = SP_QUERYING;
        }
        sp_unlock();
        if (status != SDP_QUERY_BUSY || time_us_64() > end)
            break;
        CheckAbort();
    }
    if (status != ERROR_CODE_SUCCESS)
        sp_error_status("Connect failed", status);
    if (!sp_wait_while(SP_QUERYING, SP_QUERY_TIMEOUT_MS))
    {
        sp_state = SP_NONE;
        error("Device did not answer");
    }
    if (sp_last_status != ERROR_CODE_SUCCESS)
        sp_error_status("Connection failed", sp_last_status);
    if (sp_channel == 0)
        return false; /* no serial port */

    /* Open it; pairing is allowed meanwhile. */
    uint16_t cid;
    sp_lock();
    sp_last_status = 0;
    sp_pairing = true;
    status = rfcomm_create_channel(&sp_rfcomm_handler, sp_addr, sp_channel, &cid);
    if (status == ERROR_CODE_SUCCESS)
    {
        sp_cid = cid;
        sp_state = SP_CONNECTING;
    }
    else
        sp_pairing = false;
    sp_unlock();
    if (status != ERROR_CODE_SUCCESS)
        sp_error_status("Connect failed", status);

    bool answered = sp_wait_while(SP_CONNECTING, SP_CONNECT_TIMEOUT_MS);
    sp_pairing = false;
    if (!answered)
    {
        sp_lock();
        sp_quiet_close = true;
        rfcomm_disconnect(sp_cid);
        sp_unlock();
        sp_state = SP_NONE;
        error("Serial device did not answer");
    }
    if (sp_state != SP_CONNECTED)
        sp_error_status("Connection failed", sp_last_status);

    char buf[40];
    MMPrintString("Connected to serial device ");
    MMPrintString((char *)bd_addr_to_str(sp_addr));
    snprintf(buf, sizeof(buf), " (RFCOMM channel %u) as COM7", (unsigned)sp_channel);
    MMPrintString(buf);
    PRet();
    return true;
}

void bt_serial_disconnect(void)
{
    sp_lock();
    sp_auto = false; /* until COM7 is opened again, or the next CONNECT */
    btstack_run_loop_remove_timer(&sp_timer);
    sp_unlock();
    if (sp_state != SP_CONNECTED && sp_state != SP_CONNECTING)
        error("No serial device connected");
    sp_lock();
    sp_quiet_close = true;
    rfcomm_disconnect(sp_cid);
    sp_unlock();
    uint64_t end = time_us_64() + 5000000u;
    while (sp_state != SP_NONE)
    {
        CheckAbort();
        if (time_us_64() > end)
            error("Serial device did not release the connection");
    }
}

void bt_serial_address(char *buf)
{
    if (sp_state == SP_CONNECTED)
        strcpy(buf, bd_addr_to_str(sp_addr));
    else
        buf[0] = 0;
}

void bt_serial_status(char *buf, int len)
{
    if (sp_state == SP_CONNECTED)
        snprintf(buf, len, "%s, connected (RFCOMM channel %u, COM7 %s), %lu bytes received, %lu sent",
                 bd_addr_to_str(sp_addr), (unsigned)sp_channel, com7 ? "open" : "closed",
                 (unsigned long)sp_received, (unsigned long)sp_sent);
    else if (sp_state == SP_CONNECTING || sp_state == SP_QUERYING)
        snprintf(buf, len, "%s, connecting", bd_addr_to_str(sp_addr));
    else if (sp_have_remembered)
        snprintf(buf, len, "not connected (remembered %s%s)", bd_addr_to_str(sp_remembered.addr),
                 sp_auto ? ", COM7 open - retrying" : "");
    else
        snprintf(buf, len, "none");
}

void bt_serial_forget(const uint8_t *addr)
{
    if ((sp_state == SP_CONNECTED || sp_state == SP_CONNECTING) &&
        (addr == NULL || memcmp(addr, sp_addr, sizeof(bd_addr_t)) == 0))
    {
        sp_quiet_close = true;
        rfcomm_disconnect(sp_cid);
    }
    if (sp_have_remembered && (addr == NULL || bt_serial_is_remembered(addr)))
    {
        const btstack_tlv_t *tlv;
        void *ctx;
        btstack_tlv_get_instance(&tlv, &ctx);
        if (tlv)
            tlv->delete_tag(ctx, SP_TLV_TAG);
        sp_have_remembered = false;
    }
}

/* ============================================================================
 * COM7 (Serial.c, interpreter context)
 * ============================================================================
 */
bool bt_serial_known(void)
{
    return sp_state == SP_CONNECTED || sp_have_remembered;
}

void bt_serial_port_opened(void)
{
    sp_lock();
    sp_auto = true;
    sp_tx_tail = sp_tx_head;
    sp_reconnect_after(SP_RECONNECT_FIRST_MS); /* nothing happens while it is connected */
    sp_unlock();
}

void bt_serial_port_closed(void)
{
    sp_lock();
    sp_auto = false;
    btstack_run_loop_remove_timer(&sp_timer);
    sp_tx_tail = sp_tx_head;
    sp_unlock();
}

bool bt_serial_putc(uint8_t c)
{
    if (sp_state != SP_CONNECTED)
        return true; /* dropped, as for a USB CDC port with no device */
    uint16_t next = (uint16_t)((sp_tx_head + 1) % SP_TX_SIZE);
    if (next == sp_tx_tail)
        return false;
    sp_tx_buf[sp_tx_head] = c;
    sp_tx_head = next;
    if (!sp_send_requested)
    {
        sp_lock();
        if (sp_state == SP_CONNECTED && !sp_send_requested)
            sp_request_send();
        sp_unlock();
    }
    return true;
}

int bt_serial_tx_pending(void)
{
    if (sp_state != SP_CONNECTED)
        return 0; /* nothing will go */
    int n = sp_tx_head - sp_tx_tail;
    return n < 0 ? n + SP_TX_SIZE : n;
}

#endif /* PICOMITEBTH || PICOMITEHDMIBTH */
