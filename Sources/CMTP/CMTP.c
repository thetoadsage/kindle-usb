#include "CMTP.h"
#include <stdlib.h>
#include <stdatomic.h>
struct KCancel { atomic_int cancelled; };
KCancel *k_cancel_new(void) { KCancel *c = malloc(sizeof(KCancel)); if (c) atomic_init(&c->cancelled, 0); return c; }
void k_cancel_set(KCancel *c) { atomic_store(&c->cancelled, 1); }
int k_cancelled(KCancel *c) { return atomic_load(&c->cancelled); }
void k_cancel_free(KCancel *c) { free(c); }
LIBMTP_mtpdevice_t *k_open_kindle(void) {
    static int initialized = 0;
    if (!initialized) { LIBMTP_Init(); initialized = 1; }
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_Detect_Raw_Devices(&raw, &count);
    LIBMTP_mtpdevice_t *device = NULL;
    for (int i = 0; i < count; i++) {
        // Amazon's USB vendor ID. Never claim unrelated Android devices.
        if (raw[i].device_entry.vendor_id == 0x1949) {
            device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
            if (device) break;
        }
    }
    free(raw);
    return device;
}
