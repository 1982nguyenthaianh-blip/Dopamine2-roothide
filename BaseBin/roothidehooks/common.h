
#include <stdbool.h>
#include <bsm/libbsm.h>
#include <xpc/xpc.h>

void xpc_connection_get_audit_token(xpc_connection_t connection, audit_token_t *token);

#include <libjailbreak/libjailbreak.h>
#include <libjailbreak/jbclient_xpc.h>
#include <libjailbreak/roothider.h>
#include <libjailbreak/codesign.h>

bool isJailbreakBundlePath(const char* path);
