// Read-only hardware smoke test. Run while the GUI and other MTP clients are closed.
#include "CMTP.h"
#include <stdio.h>
#include <string.h>
int main(void) {
    LIBMTP_mtpdevice_t *d = k_open_kindle();
    if (!d) { fprintf(stderr, "No accessible Kindle MTP device\n"); return 1; }
    if (LIBMTP_Get_Storage(d, 0) != 0) { LIBMTP_Dump_Errorstack(d); LIBMTP_Release_Device(d); return 2; }
    for (LIBMTP_devicestorage_t *s=d->storage; s; s=s->next) {
        printf("Storage accessible; free bytes: %llu\n", (unsigned long long)s->FreeSpaceInBytes);
        LIBMTP_Clear_Errorstack(d);
        LIBMTP_file_t *f=LIBMTP_Get_Files_And_Folders(d,s->id,0xffffffff);
        unsigned int count=0, docs=0;
        while(f) { LIBMTP_file_t *next=f->next; count++; if (f->filename && !strcasecmp(f->filename,"documents") && f->filetype == LIBMTP_FILETYPE_FOLDER) docs=f->item_id; f->next=NULL; LIBMTP_destroy_file_t(f); f=next; }
        if (LIBMTP_Get_Errorstack(d)) { LIBMTP_Dump_Errorstack(d); LIBMTP_Release_Device(d); return 3; }
        printf("Root listing: %u items; documents folder: %s\n",count, docs ? "found" : "not found");
        if (docs) {
            f=LIBMTP_Get_Files_And_Folders(d,s->id,docs); count=0;
            while(f) { LIBMTP_file_t *next=f->next; count++; f->next=NULL; LIBMTP_destroy_file_t(f); f=next; }
            if (LIBMTP_Get_Errorstack(d)) { LIBMTP_Dump_Errorstack(d); LIBMTP_Release_Device(d); return 4; }
            printf("Documents listing: %u items\n",count);
        }
    }
    LIBMTP_Release_Device(d); puts("Read-only probe passed; session released."); return 0;
}
