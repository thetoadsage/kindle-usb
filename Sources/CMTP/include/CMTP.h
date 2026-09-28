#pragma once
#include <libmtp.h>
#include <stdint.h>
typedef struct KCancel KCancel;
KCancel *k_cancel_new(void);
void k_cancel_set(KCancel *);
int k_cancelled(KCancel *);
void k_cancel_free(KCancel *);
LIBMTP_mtpdevice_t *k_open_kindle(void);
