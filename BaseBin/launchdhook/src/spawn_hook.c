#include <spawn.h>
#include "../systemhook/src/common/common.h"
#include "boomerang.h"
#include "crashreporter.h"
#include "update.h"
#include <libjailbreak/util.h>
#include <libjailbreak/roothider/common.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <litehook.h>
#include "jbserver/jbserver_local.h"
#include "hookd_provider.h"
extern char **environ;

//void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);
#define abort_with_reason(reason_namespace,reason_code,reason_string,reason_flags)  launchd_panic("%s",reason_string)

extern int systemwide_trust_file_by_path(const char *path);
extern int platform_set_process_debugged(uint64_t pid, bool fullyDebugged);
extern void systemwide_domain_set_enabled(bool enabled);

extern int roothide_launchd___posix_spawn_prehook(pid_t *restrict pid, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);
extern int roothide_launchd___posix_spawn_posthook(pid_t *restrict pid, const char *restrict path, struct _posix_spawn_args_desc *desc, char *const argv[restrict], char *const envp[restrict]);
extern int roothide_launchd_trust_executable(const char* path);

#define LOG_PROCESS_LAUNCHES 0

extern bool gInEarlyBoot;
extern bool gFreeBootLogoBeforeBackboardd;
void free_boot_logo(void);

void early_boot_done(void)
{
	gInEarlyBoot = false;
}

void ensure_fakelib_mounted(void)
{
	struct statfs fsb;
	if (statfs("/usr/lib", &fsb) != 0) return;
	if (strcmp(fsb.f_mntonname, "/usr/lib") != 0) {
		systemwide_domain_set_enabled(true);

		mach_port_t serverPort = jbserver_local_start();
		jbctl_earlyboot(serverPort, "internal", "fakelib", "mount", NULL);
		jbserver_local_stop();

		setenv("DOPAMINE_IS_HIDDEN", "1", true);
	}
}

int __posix_spawn_orig_wrapper(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	crashreporter_pause();
	int r = __posix_spawn_inline(pid, path, desc, argv, envp);
	crashreporter_resume();

	if(r == 0 && pid) {
		register_job(*pid);
	}

	return r;
}

int __posix_spawn_hook(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	if (path) {
		char executablePath[1024];
		uint32_t bufsize = sizeof(executablePath);
		_NSGetExecutablePath(&executablePath[0], &bufsize);
		if (!strcmp(path, executablePath)) {
			gInEarlyBoot = true;

			hookd_provider_teardown();

			// RootHide: fakelib not mounted — use proc_patch_dyld instead
//			ensure_fakelib_mounted();

#if LOG_PROCESS_LAUNCHES
			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
			fprintf(f, "==== USERSPACE REBOOT ====\n");
			fclose(f);
#endif

			boomerang_stashPrimitives();

			unmount("/Developer", MNT_FORCE);

			const char *stagedJailbreakUpdate = getenv("STAGED_JAILBREAK_UPDATE");
			if (stagedJailbreakUpdate) {
				int r = jbupdate_basebin(stagedJailbreakUpdate);
				if (r != 0) {
					char msg[1000];
					snprintf(msg, 1000, "Failed updating basebin (error %d).", r);
					abort_with_reason(7, 1, msg, 0);
				}
				unsetenv("STAGED_JAILBREAK_UPDATE");
			}

			// RootHide: start new launchd suspended so boomerang can patch dyld before it processes DYLD_INSERT_LIBRARIES
			if (desc && desc->attrp) {
				short flags = 0;
				posix_spawnattr_getflags(&desc->attrp, &flags);
				posix_spawnattr_setflags(&desc->attrp, flags | POSIX_SPAWN_START_SUSPENDED);
			}

			return __posix_spawn_orig_wrapper(pid, path, desc, argv, environ);
		}
	}

#if LOG_PROCESS_LAUNCHES
	if (path) {
		FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		fprintf(f, "%s", path);
		int ai = 0;
		while (argv) {
			if (argv[ai]) {
				if (ai >= 1) {
					fprintf(f, " %s", argv[ai]);
				}
				ai++;
			}
			else {
				break;
			}
		}
		fprintf(f, "\n");
		fclose(f);
	}
#endif

	if (gInEarlyBoot) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			early_boot_done();
		}
		else {
			return __posix_spawn_orig_wrapper(pid, path, desc, argv, envp);
		}
	}

	if (gFreeBootLogoBeforeBackboardd) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			if (argv[0]) {
				if (argv[1]) {
					if (!strcmp(argv[1], "com.apple.backboardd")) {
						free_boot_logo();
						gFreeBootLogoBeforeBackboardd = false;
					}
				}
			}
		}
	}

	return posix_spawn_hook_shared(pid, path, desc, argv, envp, roothide_launchd___posix_spawn_posthook, roothide_launchd_trust_executable, platform_set_process_debugged, jbsetting(jetsamMultiplier));
}

void initSpawnHooks(void)
{
	litehook_hook_function(__posix_spawn, roothide_launchd___posix_spawn_prehook);
}
