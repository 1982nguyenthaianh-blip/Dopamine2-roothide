
#include <stdbool.h>
#include <bsm/libbsm.h>
#include <xpc/xpc.h>

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/jbclient_xpc.h>
#include <libjailbreak/roothider.h>
#include <libjailbreak/codesign.h>

void xpc_connection_get_audit_token(xpc_connection_t connection, audit_token_t *token);
pid_t xpc_connection_get_pid(xpc_connection_t connection);
uid_t xpc_connection_get_euid(xpc_connection_t connection);

bool isJailbreakBundlePath(const char* path);

