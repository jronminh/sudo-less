// updo wire protocol, shared by updo.c (client) and updod.c (daemon).
//
// Transport: a unix stream socket, /run/updo/IDENT.sock, root:master 0660,
// one daemon instance per connection (systemd Accept=yes). No crypto: the
// kernel is the authority. The socket mode decides who can connect, and the
// daemon re-checks the caller's uid with SO_PEERCRED before reading anything.
//
// 1. client -> daemon, one sendmsg:
//      SCM_RIGHTS: 3 fds, the command's stdin, stdout, stderr
//      data:       "UPDO" | u32 len | len bytes of NUL-terminated fields:
//                  version "1", cwd, cwd_strict "0"|"1", argc, argv...,
//                  envc, env ("K=V")...
//    cwd "" means the identity's home. Integers are decimal strings.
// 2. client -> daemon, any time after: 1 byte per signal to deliver to the
//    command's process group (SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGWINCH).
//    EOF (client gone) = SIGHUP, then the service's cgroup is torn down.
// 3. daemon -> client, once: "UPDO" | u8 status, then close. status is the
//    command's exit code, 128+N if it died of signal N, 126 if it could not
//    be executed, 127 if not found.
//
// The command gets the caller's own fds, not a relay: no pty, no copying,
// pipes stay binary-clean, a terminal stays a terminal (window size, raw
// mode, all read straight from the device). Errors from the daemon itself
// are written to the passed stderr.
#ifndef UPDO_PROTO_H
#define UPDO_PROTO_H

#define UPDO_MAGIC     "UPDO"
#define UPDO_MAGIC_LEN 4
#define UPDO_VERSION   "1"
#define UPDO_REQ_MAX   (1024 * 1024)

#endif
