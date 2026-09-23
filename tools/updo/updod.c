// updod — the daemon side of updo: runs one command as this service's
// identity, for one caller, then exits.
//
// Started by systemd per connection (updo-IDENT.socket, Accept=yes,
// StandardInput=socket), already as the identity and inside the unit's
// sandbox; updod itself holds no privilege and changes none.
//
//   updod --allow-uid UID [--name IDENT] [--ephemeral]
//
//   --allow-uid UID  the only caller accepted (SO_PEERCRED, checked before
//                    the request is read)
//   --name IDENT     exported to the command as UPDO_IDENTITY
//   --ephemeral      this is a per-call identity (DynamicUser); exported as
//                    UPDO_EPHEMERAL=1 so the client refuses shells
//
// Protocol: updo-proto.h. Every call is logged to stderr (the journal):
// caller pid/uid, cwd, argv, exit status.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include "updo-proto.h"

#define SOCK 0

static void die(const char *msg) {
    fprintf(stderr, "updod: %s\n", msg);
    exit(1);
}

static char *kv(const char *k, const char *v) {
    char *s;
    if (asprintf(&s, "%s=%s", k, v) < 0) die("out of memory");
    return s;
}

static int read_full(int fd, void *buf, size_t len) {
    char *p = buf;
    while (len) {
        ssize_t r = read(fd, p, len);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        p += r; len -= (size_t)r;
    }
    return 0;
}

// Walks the NUL-terminated fields of the request.
struct fields { char *p, *end; };
static char *next_field(struct fields *f) {
    if (f->p >= f->end) die("truncated request");
    char *s = f->p;
    char *nul = memchr(s, 0, (size_t)(f->end - s));
    if (!nul) die("unterminated field");
    f->p = nul + 1;
    return s;
}
static long next_count(struct fields *f) {
    char *s = next_field(f), *e;
    long n = strtol(s, &e, 10);
    if (*s == 0 || *e || n < 0 || n > 65536) die("bad count");
    return n;
}

static int allowed_signal(int sig) {
    return sig == SIGINT || sig == SIGTERM || sig == SIGHUP ||
           sig == SIGQUIT || sig == SIGWINCH;
}

int main(int argc, char **argv) {
    long allow_uid = -1;
    const char *name = "updo";
    int ephemeral = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--allow-uid") && i + 1 < argc) allow_uid = atol(argv[++i]);
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--ephemeral")) ephemeral = 1;
        else die("usage: updod --allow-uid UID [--name IDENT] [--ephemeral]");
    }
    if (allow_uid < 0) die("--allow-uid is required");
    signal(SIGPIPE, SIG_IGN);

    // 1. who is calling: the kernel's answer, before anything is read
    struct ucred cred;
    socklen_t cl = sizeof(cred);
    if (getsockopt(SOCK, SOL_SOCKET, SO_PEERCRED, &cred, &cl) < 0)
        die("stdin is not a unix socket (run from updo-IDENT.socket)");
    if ((long)cred.uid != allow_uid) {
        fprintf(stderr, "updod: refused pid %d uid %u\n", cred.pid, cred.uid);
        return 1;
    }

    // 2. header + the caller's three fds, in one message
    char hdr[UPDO_MAGIC_LEN + 4];
    union { struct cmsghdr h; char buf[CMSG_SPACE(3 * sizeof(int))]; } ctl;
    struct iovec iov = { hdr, sizeof(hdr) };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1,
                          .msg_control = ctl.buf, .msg_controllen = sizeof(ctl.buf) };
    ssize_t r = recvmsg(SOCK, &msg, MSG_CMSG_CLOEXEC | MSG_WAITALL);
    if (r != (ssize_t)sizeof(hdr) || memcmp(hdr, UPDO_MAGIC, UPDO_MAGIC_LEN))
        die("bad request header");
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    if (!c || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS ||
        c->cmsg_len != CMSG_LEN(3 * sizeof(int)) || (msg.msg_flags & MSG_CTRUNC))
        die("request carries no stdin/stdout/stderr");
    int fds[3];
    memcpy(fds, CMSG_DATA(c), sizeof(fds));
    uint32_t len;
    memcpy(&len, hdr + UPDO_MAGIC_LEN, 4);
    if (len == 0 || len > UPDO_REQ_MAX) die("bad request length");
    char *req = malloc(len);
    if (!req || read_full(SOCK, req, len) < 0) die("truncated request");

    // 3. fields: version, cwd, cwd_strict, argc, argv..., envc, env...
    struct fields f = { req, req + len };
    if (strcmp(next_field(&f), UPDO_VERSION)) die("protocol version mismatch");
    char *cwd = next_field(&f);
    int strict = !strcmp(next_field(&f), "1");
    long cargc = next_count(&f);
    if (cargc == 0) die("empty command");
    char **cargv = calloc((size_t)cargc + 1, sizeof(char *));
    for (long i = 0; i < cargc; i++) cargv[i] = next_field(&f);
    long cenvc = next_count(&f);
    char **cenv = calloc((size_t)cenvc + 8, sizeof(char *));
    long n = 0;
    for (long i = 0; i < cenvc; i++) {
        char *e = next_field(&f);
        // the caller may pass locale and terminal settings, not identity vars
        if (!strchr(e, '=') || !strncmp(e, "HOME=", 5) || !strncmp(e, "USER=", 5) ||
            !strncmp(e, "LOGNAME=", 8) || !strncmp(e, "SHELL=", 6) ||
            !strncmp(e, "PATH=", 5) || !strncmp(e, "UPDO_", 5))
            continue;
        cenv[n++] = e;
    }
    struct passwd *pw = getpwuid(getuid());
    const char *home = pw && pw->pw_dir ? pw->pw_dir : "/";
    const char *shell = pw && pw->pw_shell && *pw->pw_shell ? pw->pw_shell : "/bin/sh";
    const char *uname = pw ? pw->pw_name : "updo";
    cenv[n++] = kv("HOME", home);
    cenv[n++] = kv("USER", uname);
    cenv[n++] = kv("LOGNAME", uname);
    cenv[n++] = kv("SHELL", shell);
    cenv[n++] = "PATH=/usr/local/bin:/usr/bin:/bin";
    cenv[n++] = kv("UPDO_IDENTITY", name);
    if (ephemeral) cenv[n++] = "UPDO_EPHEMERAL=1";
    cenv[n] = NULL;

    fprintf(stderr, "updod: pid %d uid %u cwd %s argv", cred.pid, cred.uid,
            *cwd ? cwd : "~");
    for (long i = 0; i < cargc; i++) fprintf(stderr, " [%s]", cargv[i]);
    fputc('\n', stderr);

    // 4. the command: its own session, the caller's fds, our environment
    pid_t pid = fork();
    if (pid < 0) die("fork failed");
    if (pid == 0) {
        setsid();
        signal(SIGPIPE, SIG_DFL);
        for (int i = 0; i < 3; i++)
            if (dup2(fds[i], i) < 0) _exit(126);   // also closes the socket (fd 0)
        const char *dir = *cwd ? cwd : home;
        if (chdir(dir) < 0) {
            if (strict) { dprintf(2, "updo: cannot enter %s: %s\n", dir, strerror(errno)); _exit(1); }
            dprintf(2, "updo: cannot enter %s, using %s\n", dir, home);
            if (chdir(home) < 0 && chdir("/") < 0) _exit(1);
        }
        execvpe(cargv[0], cargv, cenv);
        int e = errno;
        dprintf(2, "updo: %s: %s\n", cargv[0], strerror(e));
        _exit(e == ENOENT ? 127 : 126);
    }
    for (int i = 0; i < 3; i++) close(fds[i]);

    // 5. relay signals from the caller until the command exits
    int pidfd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (pidfd < 0) die("pidfd_open failed");
    struct pollfd p[2] = { { pidfd, POLLIN, 0 }, { SOCK, POLLIN, 0 } };
    int status = 0;
    for (;;) {
        if (poll(p, 2, -1) < 0) { if (errno == EINTR) continue; die("poll failed"); }
        if (p[0].revents) {
            if (waitpid(pid, &status, 0) < 0) die("waitpid failed");
            break;
        }
        if (p[1].revents) {
            unsigned char sig;
            ssize_t k = read(SOCK, &sig, 1);
            if (k == 1 && allowed_signal(sig)) {
                if (kill(-pid, sig) < 0) kill(pid, sig);
            } else if (k <= 0) {            // caller gone
                kill(-pid, SIGHUP);
                p[1].fd = -1;
            }
        }
    }
    unsigned char code = WIFEXITED(status) ? (unsigned char)WEXITSTATUS(status)
                        : (unsigned char)(128 + WTERMSIG(status));
    char out[UPDO_MAGIC_LEN + 1];
    memcpy(out, UPDO_MAGIC, UPDO_MAGIC_LEN);
    out[UPDO_MAGIC_LEN] = (char)code;
    if (write(SOCK, out, sizeof(out)) < 0) { /* caller gone; nothing to tell */ }
    fprintf(stderr, "updod: pid %d exit %u\n", cred.pid, code);
    return 0;
}
