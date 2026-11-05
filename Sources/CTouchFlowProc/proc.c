#include "CTouchFlowProc.h"

#include <libproc.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <unistd.h>

/// Reads the socket table of every process we are allowed to inspect.
/// Ports come back host-endian; libproc stores them in network order.
int32_t tf_list_tcp_owners(tf_tcp_owner *out, int32_t capacity) {
    if (out == NULL || capacity <= 0) { return -capacity; }

    int pid_count = proc_listallpids(NULL, 0);
    if (pid_count <= 0) { return 0; }
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)pid_count);
    if (pids == NULL) { return 0; }
    pid_count = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)pid_count));
    if (pid_count <= 0) { free(pids); return 0; }

    int32_t written = 0;
    int32_t needed = 0;
    pid_t self = getpid();

    for (int i = 0; i < pid_count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == self) { continue; }

        int fd_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fd_size <= 0) { continue; }
        struct proc_fdinfo *fds = malloc((size_t)fd_size);
        if (fds == NULL) { continue; }
        fd_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fd_size);
        if (fd_size <= 0) { free(fds); continue; }

        int fd_count = fd_size / (int)sizeof(struct proc_fdinfo);
        for (int j = 0; j < fd_count; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) { continue; }
            struct socket_fdinfo info;
            int n = proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info));
            if (n != (int)sizeof(info)) { continue; }
            if (info.psi.soi_kind != SOCKINFO_TCP) { continue; }

            struct tcp_sockinfo *tcp = &info.psi.soi_proto.pri_tcp;
            if (tcp->tcpsi_state != TSI_S_ESTABLISHED) { continue; }
            struct in_sockinfo *ini = &tcp->tcpsi_ini;
            uint16_t lport = ntohs((uint16_t)ini->insi_lport);
            uint16_t fport = ntohs((uint16_t)ini->insi_fport);
            if (lport == 0 || fport == 0) { continue; }

            needed += 1;
            if (written >= capacity) { continue; }
            out[written].local_port = lport;
            out[written].remote_port = fport;
            out[written].pid = (int32_t)pid;
            written += 1;
        }
        free(fds);
    }

    free(pids);
    return written < needed ? -needed : written;
}

int32_t tf_pid_path(int32_t pid, char *buf, int32_t buflen) {
    if (buf == NULL || buflen <= 0) { return -1; }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int n = proc_pidpath((pid_t)pid, path, sizeof(path));
    if (n <= 0) { return -1; }
    if (n >= buflen) { n = buflen - 1; }
    memcpy(buf, path, (size_t)n);
    buf[n] = '\0';
    return n;
}

int32_t tf_pid_name(int32_t pid, char *buf, int32_t buflen) {
    if (buf == NULL || buflen <= 0) { return -1; }
    char name[2 * MAXCOMLEN + 1];
    int n = proc_name((pid_t)pid, name, sizeof(name));
    if (n <= 0) { return -1; }
    if (n >= buflen) { n = buflen - 1; }
    memcpy(buf, name, (size_t)n);
    buf[n] = '\0';
    return n;
}
