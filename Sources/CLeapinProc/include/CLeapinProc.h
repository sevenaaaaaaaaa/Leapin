#ifndef C_TOUCHFLOW_PROC_H
#define C_TOUCHFLOW_PROC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One TCP socket owned by a user process.
typedef struct {
    uint16_t local_port;
    uint16_t remote_port;
    int32_t pid;
} leapin_tcp_owner;

/// Enumerates TCP sockets of all readable processes.
/// Writes up to `capacity` rows into `out` and returns the number written.
/// A negative return means the buffer was too small; its absolute value is the
/// number of rows that were available.
int32_t leapin_list_tcp_owners(leapin_tcp_owner *out, int32_t capacity);

/// Copies the executable path of `pid` into `buf` (NUL-terminated).
/// Returns the byte length, or -1 when the process cannot be inspected.
int32_t leapin_pid_path(int32_t pid, char *buf, int32_t buflen);

/// Copies the short process name into `buf` (NUL-terminated). Returns length or -1.
int32_t leapin_pid_name(int32_t pid, char *buf, int32_t buflen);

#ifdef __cplusplus
}
#endif

#endif /* C_TOUCHFLOW_PROC_H */
