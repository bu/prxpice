/*
 * Stub for iOS cross-compilation.
 * libproc.h is a macOS-only header not present in the iOS SDK.
 * GLib uses proc_pidpath() to find the executable path; returning -1
 * causes GLib to fall back to its other methods.
 */
#ifndef LIBPROC_H_IOS_STUB
#define LIBPROC_H_IOS_STUB

#include <sys/types.h>
#include <stdint.h>

static inline int proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
    (void)pid; (void)buffer; (void)buffersize;
    return -1;
}

#endif /* LIBPROC_H_IOS_STUB */
