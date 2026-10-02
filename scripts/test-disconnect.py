#!/usr/bin/env python3
"""Compile actual patched libmtp close functions against fake USB operations."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / '.build/vendor/libmtp-1.1.23/src/libusb1-glue.c').read_text()

def function(signature):
    start = source.index(signature + '\n{')
    return source[start:source.index('\n}', start) + 2]

harness = r'''
#include <assert.h>
#include <stdint.h>
typedef struct {
    struct { struct { uint16_t vendor_id, product_id; } device_entry; } rawdevice;
    int timeout, interface, no_release, reset;
    void *handle;
} PTP_USB;
typedef struct { int unused; } PTPParams;
#define PTP_RC_OK 0
#define LIBMTP_ERROR(...) ((void)0)
#define FLAG_NO_RELEASE_INTERFACE(p) ((p)->no_release)
#define FLAG_FORCE_RESET_ON_CLOSE(p) ((p)->reset)
static PTP_USB *active;
static int result, stage, probes, releases, resets, handles;
static int ptp_closesession(PTPParams *params) {
    assert(stage++ == 0);
    assert(active->timeout == 20000);
    return result;
}
static void clear_stall(PTP_USB *usb) { assert(stage == 1); probes++; }
static void libusb_release_interface(void *handle, int interface) { assert(stage == 1); releases++; }
static void libusb_reset_device(void *handle) { assert(stage == 1); resets++; }
static void libusb_close(void *handle) { assert(stage == 1); handles++; stage++; }
'''
harness += function('static void close_usb(PTP_USB* ptp_usb, int session_closed)')
harness += '\n' + function('void close_device (PTP_USB *ptp_usb, PTPParams *params)')
harness += r'''
int main(void) {
    PTPParams params = {0};
    for (int device = 0; device < 4; device++) {
        int amazon = device < 2;
        for (int failed = 0; failed <= 1; failed++) {
            for (int no_release = 0; no_release <= 1; no_release++) {
                for (int reset = 0; reset <= 1; reset++) {
                    PTP_USB usb = {0};
                    usb.rawdevice.device_entry.vendor_id = amazon ? 0x1949 : 0x1234;
                    usb.rawdevice.device_entry.product_id = (device % 2 == 0) ? 0x9981 : 0x0001;
                    usb.timeout = 20000; usb.no_release = no_release; usb.reset = reset;
                    active = &usb; result = failed;
                    stage = probes = releases = resets = handles = 0;
                    close_device(&usb, &params);
                    assert(probes == (!no_release && (!amazon || failed)));
                    assert(releases == !no_release);
                    assert(resets == reset);
                    assert(handles == 1 && stage == 2);
                    assert(usb.timeout == (amazon ? 500 : 20000));
                }
            }
        }
    }
    /* Open-session recovery still probes endpoints before releasing them. */
    PTP_USB usb = {0}; usb.rawdevice.device_entry.vendor_id = 0x1949;
    usb.rawdevice.device_entry.product_id = 0x9981; usb.reset = 1;
    stage = 1; probes = releases = resets = handles = 0;
    close_usb(&usb, 0);
    assert(probes == 1 && releases == 1 && resets == 1 && handles == 1);
}
'''
with tempfile.TemporaryDirectory() as directory:
    c = Path(directory) / 'test.c'
    binary = Path(directory) / 'test'
    c.write_text(harness)
    subprocess.run(['xcrun', 'clang', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print('Passed 32 disconnect combinations and open-session recovery; no hardware accessed.')
