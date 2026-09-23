// updo configuration: /etc/updo/updo.conf, then /etc/updo/conf.d/*.conf.
//
//   [global]                    defaults for every identity
//   callers  = master           users allowed to call (SO_PEERCRED)
//   env      = TERM LANG LC_*   caller variables passed through (* = prefix)
//   timeout  = 0                seconds, 0 = none
//
//   [identity NAME]             one identity, socket /run/updo/NAME.sock
//   user     = updo-NAME        system user (default: updo for "updo",
//                               updo-NAME otherwise), or "dynamic"
//                               (DynamicUser: a new uid per call)
//   callers, env, timeout       override [global]
//   shell    = no               yes: interactive shell, -s, -i, -c allowed
//   edit     = yes              no: updo -e refused
//   commands = *                absolute paths the identity may execute,
//                               or * for anything; enforced by updod on
//                               argv[0] and by the kernel (ExecPaths=)
//   write    =                  paths made writable (ReadWritePaths=)
//   groups   =                  supplementary groups
//   caps     =                  ambient capabilities (short allowlist)
//
// Values are space-separated; "#" starts a comment. Unknown keys are errors.
#ifndef UPDO_CONF_H
#define UPDO_CONF_H

#include <stddef.h>
#include <sys/types.h>

#define UPDO_CONF_DEFAULT "/etc/updo/updo.conf"

struct strs { char **v; size_t n; };

struct ident {
    char *name;
    char *user;            // resolved default filled in by conf_load
    int dynamic;
    int shell, edit;
    long timeout;
    struct strs callers, env, commands, write, groups, caps;
    int has_callers, has_env, has_timeout, has_commands;
};

struct conf {
    struct ident global;
    struct ident *ids;
    size_t n;
    char *err;             // first load error, NULL if none
};

// Loads PATH and PATH's sibling conf.d/*.conf. Returns 0, or -1 with c->err.
int conf_load(struct conf *c, const char *path);
struct ident *conf_find(struct conf *c, const char *name);
// Validates everything; prints "error: ..." / "warning: ..." lines to stdout.
// Returns the number of errors.
int conf_check(struct conf *c);
int conf_caller_ok(const struct ident *id, uid_t uid);
int conf_env_ok(const struct ident *id, const char *kv);
// 1 if PATH (absolute) is an allowed command of ID.
int conf_command_ok(const struct ident *id, const char *path);

#endif
