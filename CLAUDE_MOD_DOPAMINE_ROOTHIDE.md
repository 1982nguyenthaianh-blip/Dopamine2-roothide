# Whitelist Tweak Injection Architecture & Patch Specification for Dopamine2-RootHide

## 📌 Context & Objective

In a RootHide environment on iOS 15.0 - 16.5.1:
* **Blacklist ON**: App Z (e.g. Facebook) is completely shielded from jailbreak detection, but all tweaks are blocked by `TweakLoader.dylib`.
* **Blacklist OFF**: System tweaks can load, but Facebook instantly detects jailbreak files (`/var/jb`, `dyld` injections) and locks/flags the account or crashes.

**Solution Achieved**:
Surgical, whitelist-based injection of a specific tweak (`TEST_FAKE_FB.dylib` / `SFM`) directly into Facebook **while keeping Facebook in RootHide Blacklist mode**. Facebook remains 100% stealthy to jailbreak checks while benefiting from device spoofing.

---

## 🛠️ Key Technical Breakthroughs & Architecture

### 1. Launchd Process Spawning (`BaseBin/launchdhook/src/roothider.m`)
* Identifies target App Z processes by checking if `path` contains `Facebook.app` or `com.facebook.Facebook`.
* When detected in Blacklist mode:
  1. Sets environment variable `ROOTHIDE_WHITELIST_TWEAK = "<target_tweak.dylib>"`.
  2. Ensures `systemhook.dylib` is added to `DYLD_INSERT_LIBRARIES`.
  3. Uses `__posix_spawn_hook(&pid, path, desc, argv, envc)` instead of `__posix_spawn_orig_wrapper` to ensure `systemhook.dylib` is properly signed/patched and trusted by dyld/amfid for the target process.

### 2. Mach/XPC Check-in Unblocking (`BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c`)
* Modifies `roothide_domain_allowed()` to explicitly allow IPC communication from `Facebook.app` processes.
* Enables App Z to perform `jbclient_mach_process_checkin`, which yields:
  * Essential root sandbox extensions (`consume_tokenized_sandbox_extensions`).
  * Disabling of page validation for instruction-level hooks (`MSHookFunction`/`ellekit`).

### 3. Isolated Tweak Loading Engine (`BaseBin/systemhook/src/main.c`)
* In `systemhook` process initialization:
  1. Detects `ROOTHIDE_WHITELIST_TWEAK`.
  2. Executes `jbclient_mach_process_checkin` to obtain root sandbox extensions.
  3. Pre-loads `libellekit.dylib` via `dlopen` (required for hook framework symbols).
  4. Loads the target whitelist tweak (`/Library/MobileSubstrate/DynamicLibraries/<whitelistedTweak>`) via `dlopen`.
  5. Bypasses `TweakLoader.dylib` entirely, keeping all non-whitelisted tweaks 100% isolated and blocked.

---

## 📝 Exact File Diffs & Modification Details

### File 1: `BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c`
```diff
diff --git a/BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c b/BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c
index bbe0a4f..d3f86d0 100644
--- a/BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c
+++ b/BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c
@@ -13,9 +13,16 @@ int roothide_unsupport_request()
 
 bool roothide_domain_allowed(audit_token_t clientToken)
 {
+	pid_t pid = audit_token_to_pid(clientToken);
+	char pathBuf[PATH_MAX] = {0};
+	const char *procPath = proc_get_path(pid, pathBuf);
+	if (procPath && (strstr(procPath, "com.facebook.Facebook") || strstr(procPath, "Facebook.app"))) {
+		return true;
+	}
+
 	//its fast enough
 	if(isBlacklistedToken(&clientToken)) {
-		JBLogDebug("ignore xpc message from blacklisted process (%d),%s", audit_token_to_pid(clientToken), proc_get_path(audit_token_to_pid(clientToken),NULL));
+		JBLogDebug("ignore xpc message from blacklisted process (%d),%s", pid, procPath);
 		return false;
 	}
```

---

### File 2: `BaseBin/launchdhook/src/roothider.m`
```diff
diff --git a/BaseBin/launchdhook/src/roothider.m b/BaseBin/launchdhook/src/roothider.m
index 57ffeeb..6adb663 100644
--- a/BaseBin/launchdhook/src/roothider.m
+++ b/BaseBin/launchdhook/src/roothider.m
@@ -376,6 +376,7 @@ int roothide_launchd___posix_spawn_prehook(pid_t *restrict pidp, const char *res
 #endif
 
 	bool roothideBlacklisted = isBlacklistedPath(path);
+	bool isTargetAppZ = (path && (strstr(path, "Facebook.app") || strstr(path, "com.facebook.Facebook")));
 	if (choicyBlocked || roothideBlacklisted)
 	{
 		int ret;
@@ -406,19 +407,41 @@ int roothide_launchd___posix_spawn_prehook(pid_t *restrict pidp, const char *res
 	
 			/* and posix_spawn->kernel->amfid->launchd may cause xpc dead loop so we can't use lock-spawn-unlock here */
 	
-			volatile pid_t* blacklistedPidp = allocBlacklistProcessId();
-	
-			if(roothideBlacklisted || !dyld_patch_enabled() || !iOS15Arm64e) {
-				ret = __posix_spawn_orig_wrapper(blacklistedPidp, path, desc, argv, envc);
+			pid_t pid = 0;
+			if (roothideBlacklisted && isTargetAppZ) {
+				FILE *logf = fopen("/var/mobile/roothide_whitelist.log", "a");
+				if (logf) {
+					fprintf(logf, "[launchdhook] Target App Z detected (%s), injecting systemhook + ROOTHIDE_WHITELIST_TWEAK\n", path);
+					fclose(logf);
+				}
+				envbuf_setenv(&envc, "ROOTHIDE_WHITELIST_TWEAK", "TEST_FAKE_FB.dylib");

+				const char *syshookPath = (HOOK_DYLIB_PATH && HOOK_DYLIB_PATH[0]) ? HOOK_DYLIB_PATH : JBROOT_PATH("/basebin/systemhook.dylib");
+				const char *existingInserts = envbuf_getenv((const char **)envc, "DYLD_INSERT_LIBRARIES");
+				if (existingInserts && strstr(existingInserts, "systemhook") == NULL) {
+					char newInserts[PATH_MAX*2];
+					snprintf(newInserts, sizeof(newInserts), "%s:%s", syshookPath, existingInserts);
+					envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", newInserts);
+				} else if (!existingInserts) {
+					envbuf_setenv(&envc, "DYLD_INSERT_LIBRARIES", syshookPath);
+				}

+				ret = __posix_spawn_hook(&pid, path, desc, argv, envc);
+				if (pidp) *pidp = pid;
 			} else {
-				ret = roothide_launchd___posix_spawn__spinlock_fix_only(blacklistedPidp, path, desc, argv, envc);
-			}
-	
-			pid_t pid = *blacklistedPidp;
-			if(pidp) *pidp = *blacklistedPidp;
+				volatile pid_t* blacklistedPidp = allocBlacklistProcessId();
+				if(roothideBlacklisted || !dyld_patch_enabled() || !iOS15Arm64e) {
+					ret = __posix_spawn_orig_wrapper(blacklistedPidp, path, desc, argv, envc);
+				} else {
+					ret = roothide_launchd___posix_spawn__spinlock_fix_only(blacklistedPidp, path, desc, argv, envc);
+				}

+				pid = *blacklistedPidp;
+				if(pidp) *pidp = *blacklistedPidp;

+				commitBlacklistProcessId(blacklistedPidp); // will release blacklistedPidp
+				blacklistedPidp = NULL;
+			}

 			envbuf_free(envc);
```

---

### File 3: `BaseBin/systemhook/src/main.c`
```diff
diff --git a/BaseBin/systemhook/src/main.c b/BaseBin/systemhook/src/main.c
index e513d54..e848e65 100644
--- a/BaseBin/systemhook/src/main.c
+++ b/BaseBin/systemhook/src/main.c
@@ -10,6 +10,7 @@
 #include <util.h>
 #include <ptrauth.h>
 #include <libjailbreak/jbclient_xpc.h>
+#include <libjailbreak/jbclient_mach.h>
 #include <libjailbreak/codesign.h>
 #include <libjailbreak/jbroot.h>
 #include "../dyldhook/src/dyld_jbinfo.h"
@@ -429,8 +430,61 @@ roothide_init_with_executable(gExecutablePath);
 
 
 		// Load tweaks if desired
-		// We can hardcode /var/jb here since if it doesn't exist, loading TweakLoader.dylib is not going to work anyways
-		if (should_enable_tweaks()) {
+		const char *whitelistedTweak = getenv("ROOTHIDE_WHITELIST_TWEAK");
+		if (whitelistedTweak) {
+			FILE *logf = fopen("/var/mobile/roothide_whitelist.log", "a");
+			if (logf) {
+				fprintf(logf, "[systemhook] Process %s found ROOTHIDE_WHITELIST_TWEAK=%s\n", gExecutablePath, whitelistedTweak);
+				fclose(logf);
+			}
+			unsetenv("ROOTHIDE_WHITELIST_TWEAK");
+
+			// Perform process checkin to obtain sandbox extensions & disable page validation for instruction hooks
+			char jbRootPathBuf[PATH_MAX] = {0};
+			char bootUUIDBuf[PATH_MAX] = {0};
+			char sandboxExtsBuf[4096] = {0};
+			bool fullyDebugged = false;
+			int checkinRet = jbclient_mach_process_checkin(jbRootPathBuf, bootUUIDBuf, sandboxExtsBuf, &fullyDebugged);
+			logf = fopen("/var/mobile/roothide_whitelist.log", "a");
+			if (logf) {
+				fprintf(logf, "[systemhook] jbclient_mach_process_checkin ret=%d jbRoot=%s extsLen=%zu\n", checkinRet, jbRootPathBuf, strlen(sandboxExtsBuf));
+				fclose(logf);
+			}
+			if (checkinRet == 0) {
+				consume_tokenized_sandbox_extensions(sandboxExtsBuf);
+				if (!JB_RootPath && jbRootPathBuf[0]) {
+					JB_RootPath = strdup(jbRootPathBuf);
+				}
+			}
+
+			const char *ellekitPath = JBROOT_PATH("/usr/lib/libellekit.dylib");
+			if (access(ellekitPath, F_OK) == 0) {
+				void *ek = dlopen(ellekitPath, RTLD_NOW | RTLD_GLOBAL);
+				logf = fopen("/var/mobile/roothide_whitelist.log", "a");
+				if (logf) {
+					fprintf(logf, "[systemhook] dlopen libellekit: %p (%s)\n", ek, ek ? "ok" : dlerror());
+					fclose(logf);
+				}
+			}
+			char tweakPath[PATH_MAX];
+			snprintf(tweakPath, sizeof(tweakPath), "/Library/MobileSubstrate/DynamicLibraries/%s", whitelistedTweak);
+			const char *fullPath = JBROOT_PATH(tweakPath);
+			if (access(fullPath, F_OK) == 0) {
+				void *h = dlopen(fullPath, RTLD_NOW | RTLD_GLOBAL);
+				logf = fopen("/var/mobile/roothide_whitelist.log", "a");
+				if (logf) {
+					fprintf(logf, "[systemhook] dlopen tweak %s: %p (%s)\n", fullPath, h, h ? "ok" : dlerror());
+					fclose(logf);
+				}
+			} else {
+				logf = fopen("/var/mobile/roothide_whitelist.log", "a");
+				if (logf) {
+					fprintf(logf, "[systemhook] Tweak file not found: %s\n", fullPath);
+					fclose(logf);
+				}
+			}
+		}
+		else if (should_enable_tweaks()) {
 			const char *tweakLoaderPath = JBROOT_PATH("/usr/lib/TweakLoader.dylib");
 			if (access(tweakLoaderPath, F_OK) == 0) {
 				void *tweakLoaderHandle = dlopen(tweakLoaderPath, RTLD_NOW);
```

---

## 🤖 1-Prompt Re-application Guide for Upstream Updates

> Copy and paste the prompt below into AI whenever updating Dopamine 2.x from upstream source to re-apply this exact patch automatically:

```markdown
Please apply our custom RootHide Whitelist Tweak Injection patch for App Z (Facebook) to this updated Dopamine 2.x repository.

Requirements:
1. File `BaseBin/launchdhook/src/jbserver/jbdomain_roothide.c`:
   - In `roothide_domain_allowed(audit_token_t clientToken)`, extract the process path using `audit_token_to_pid` and `proc_get_path`.
   - If the path contains "com.facebook.Facebook" or "Facebook.app", immediately return `true` before checking `isBlacklistedToken`.

2. File `BaseBin/launchdhook/src/roothider.m`:
   - In `roothide_launchd___posix_spawn_prehook`, declare `bool isTargetAppZ = (path && (strstr(path, "Facebook.app") || strstr(path, "com.facebook.Facebook")));`.
   - If `roothideBlacklisted && isTargetAppZ`, set environment variable `ROOTHIDE_WHITELIST_TWEAK = "TEST_FAKE_FB.dylib"` (or target tweak), ensure `systemhook.dylib` is present in `DYLD_INSERT_LIBRARIES`, and execute `__posix_spawn_hook(&pid, path, desc, argv, envc)`.

3. File `BaseBin/systemhook/src/main.c`:
   - Include `#include <libjailbreak/jbclient_mach.h>`.
   - Before `if (should_enable_tweaks())`, check `const char *whitelistedTweak = getenv("ROOTHIDE_WHITELIST_TWEAK");`.
   - If `whitelistedTweak` is set:
     - Perform `jbclient_mach_process_checkin` to receive root sandbox extensions (`consume_tokenized_sandbox_extensions`).
     - Load `JBROOT_PATH("/usr/lib/libellekit.dylib")` via `dlopen(..., RTLD_NOW | RTLD_GLOBAL)`.
     - Load `JBROOT_PATH("/Library/MobileSubstrate/DynamicLibraries/<whitelistedTweak>")` via `dlopen(..., RTLD_NOW | RTLD_GLOBAL)`.
     - Bypass `TweakLoader.dylib` loading.
