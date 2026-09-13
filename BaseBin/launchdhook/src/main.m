#import <Foundation/Foundation.h>
#import <libjailbreak/libjailbreak.h>
#import <libjailbreak/util.h>
#import <libjailbreak/kernel.h>
#import <libjailbreak/display.h>
#import <mach-o/dyld.h>
#import <os/alloc_once_private.h>
#import <dlfcn.h>
#import <spawn.h>
#import <pthread.h>
#import <sys/sysctl.h>
#import <substrate.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <kern_memorystatus.h>

#import "hookd_provider.h"
#import <libjailbreak/hookd.h>
#import <litehook.h>
#import "../systemhook/src/common/common.h"
#import "../systemhook/src/common/hookd_external.h"
#import "spawn_hook.h"
#import "xpc_hook.h"
#import "daemon_hook.h"
#import "ipc_hook.h"
#import "jetsam_hook.h"
#import "crashreporter.h"
#import "boomerang.h"
#import "update.h"
#import "jbserver/jbserver_local.h"
#import "asl.h"

bool gInEarlyBoot = true;

//void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);
extern void launchd_panic(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
#define abort_with_reason(reason_namespace,reason_code,reason_string,reason_flags)  launchd_panic("%s",reason_string)
extern void systemwide_domain_set_enabled(bool enabled);

/*********************** roothide specific ********************/
void roothide_launchd_preinit(void);
void roothide_launchd_postinit(bool firstLoad);
/*************************************************************/

void exec_with_asl_disabled(void (^block)(void))
{
	struct asl_context *aslCtx = os_alloc_once(OS_ALLOC_ONCE_KEY_LIBSYSTEM_PLATFORM_ASL, sizeof(struct asl_context), NULL);
	aslCtx->asl_enabled = false;
	block();
	aslCtx->asl_enabled = true;
}

struct drawctx *gBootLogoDrawCtx = NULL;
bool gFreeBootLogoBeforeBackboardd = NO;

void draw_boot_logo(const char *bootLogoPath)
{
	exec_with_asl_disabled(^{
		if (!gBootLogoDrawCtx) {
			gBootLogoDrawCtx = drawctx_init();
		}

		if (bootLogoPath) {
			if (!access(bootLogoPath, R_OK)) {
				killall("/usr/libexec/backboardd", SIGTERM);
				drawctx_draw_image_path(gBootLogoDrawCtx, bootLogoPath);
			}
		}
	});
}

void free_boot_logo(void)
{
	drawctx_free(gBootLogoDrawCtx);
	gBootLogoDrawCtx = NULL;
}

int (*sysctlbyname_orig)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) = NULL;
int sysctlbyname_hook(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
{
/*********************** roothide specific ********************/
#ifdef __arm64e__
	if (!__builtin_available(iOS 16.0, *))
	{
		if (strcmp(name, "vm.shared_region_pivot") == 0) {
			return 0;
		}
	}
#endif
/*************************************************************/

	int r = sysctlbyname_orig(name, oldp, oldlenp, newp, newlen);
	// draw_boot_logo moved to __sysctlbyname_launchd_hook in roothider.m — avoid double call
	return r;
}

__attribute__((constructor)) static void initializer(void)
{
	crashreporter_start();

/********** roothide specific ********/
	roothide_launchd_preinit();
/*************************************/

	@autoreleasepool {
		Dl_info selfInfo;
		if (dladdr(&initializer, &selfInfo) != 0) {
			NSString *selfPath = [NSString stringWithUTF8String:selfInfo.dli_fname];
			gSystemInfo.jailbreakInfo.rootPath = strdup(selfPath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation);
		}
	}

	const char *jbupdatePrevVersion = getenv("JBUPDATE_PREV_VERSION");
	const char *jbupdateNewVersion = getenv("JBUPDATE_NEW_VERSION");
	if (jbupdatePrevVersion && jbupdateNewVersion) {
		jbupdate_finalize_stage1(jbupdatePrevVersion, jbupdateNewVersion);
	}

	bool firstLoad = false;
	if (getenv("DOPAMINE_INITIALIZED") != 0) {
		if (!access("/var/mobile/Library/Preferences/com.apple.NanoRegistry.NRRootCommander.volatile.plist", W_OK)) {
			remove("/var/mobile/Library/Preferences/com.apple.NanoRegistry.NRRootCommander.volatile.plist");
		}
		if (!access("/var/mobile/Library/Preferences/com.apple.NanoRegistry.NRLaunchNotificationController.volatile.plist", W_OK)) {
			remove("/var/mobile/Library/Preferences/com.apple.NanoRegistry.NRLaunchNotificationController.volatile.plist");
		}

		/* In RootHide, draw_boot_logo is drawn during kern.willuserspacereboot sysctl BEFORE userspace reboot */
		// draw_boot_logo(JBROOT_PATH("/basebin/bootlogo.jp2"));
		// gFreeBootLogoBeforeBackboardd = YES;
	}
	else {
		gInEarlyBoot = false;
		firstLoad = true;
	}

	int err = boomerang_recoverPrimitives(firstLoad, true);
	if (err != 0) {
		char msg[1000];
		snprintf(msg, 1000, "Dopamine: Failed to recover primitives (error %d), cannot continue.", err);
		abort_with_reason(7, 1, msg, 0);
		return;
	}

	if (jbupdatePrevVersion && jbupdateNewVersion) {
		jbupdate_finalize_stage2(jbupdatePrevVersion, jbupdateNewVersion);
		unsetenv("JBUPDATE_PREV_VERSION");
		unsetenv("JBUPDATE_NEW_VERSION");
	}

	cs_allow_invalid(proc_self(), false);

	if (__builtin_available(iOS 19.0, *)) {
		hookd_provider_init();
		litehook_hook_memory = litehook_hook_memory_hookd;
		litehook_hook_function(mach_vm_protect, mach_vm_protect_fixed);
		init_hookd_external_support();
	}

	initXPCHooks();
	initDaemonHooks();
	initSpawnHooks();
	initIPCHooks();
	initJetsamHook();

	sysctlbyname_orig = sysctlbyname;
	litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)sysctlbyname, (void *)sysctlbyname_hook, NULL);

	setenv("DYLD_INSERT_LIBRARIES", JBROOT_PATH("/basebin/launchdhook.dylib"), 1);

	setenv("DOPAMINE_INITIALIZED", "1", 1);

	setenv("LAUNCHD_UUID", [NSUUID UUID].UUIDString.UTF8String, 1);

/********** roothide specific ********/
	roothide_launchd_postinit(firstLoad);
/*************************************/
}
