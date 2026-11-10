//
//  Common/AntiDetect.m
//  越狱检测绕过 / 反调试绕过 / dyld 镜像隐藏
//

#import "AntiDetect.h"
#import "Log.h"
#import "FeatureFlags.h"          // 运行时开关（越狱绕过/反调试/dyld 隐藏各自独立）
#import "../Config.h"            // ENABLE_DYLD_INFOARRAY_PATCH 等编译期闸门
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SubstrateRT.h"          // 运行时解析，不产生 MS* 符号依赖（裸注入不崩）
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <stdlib.h>
#import <stdint.h>   // uint32_t / uint8_t（清 P_TRACED、读 dyld 结构用）
#import <stdio.h>   // FILE / fopen（文件层 hook 需要）
// 注意：iPhoneOS SDK 里【没有】<sys/ptrace.h>（那是 Linux / macOS 的）。
//   我们本来也不需要它的常量：ptrace 走 dlsym 动态取，
//   PT_DENY_ATTACH = 31 直接写字面量。
#import <errno.h>
#import <string.h>
#import <unistd.h>
#import <sys/mman.h>
#import <mach-o/dyld.h>

// ============================================================
//  黑名单路径 —— 风控最常查的越狱痕迹
// ============================================================
static const char *kJailbreakPaths[] = {
    "/Applications/Cydia.app",
    "/Applications/Sileo.app",
    "/Applications/Zebra.app",
    "/var/jb",
    "/var/lib/dpkg",
    "/var/cache/apt",
    "/etc/apt",
    "/usr/sbin/sshd",
    "/usr/bin/ssh",
    "/bin/bash",
    "/bin/sh",
    "/usr/libexec/sftp-server",
    "/private/var/lib/apt",
    "/private/etc/apt",
    "/usr/lib/libsubstrate.dylib",
    "/usr/lib/libhooker.dylib",
    "/Library/MobileSubstrate",
    "/var/mobile/Library/Preferences/com.saurik.Cydia.plist",
    NULL
};

static const char *kHideDylibMarkers[] = {
    "Substrate",
    "substrate",
    "ellekit",
    "TweakInject",
    "frida",
    "FridaGadget",
    "cycript",
    "libhooker",
    "CheatKit",
    NULL
};

static int ck_path_blacklisted(const char *path) {
    if (!path) return 0;
    for (int i = 0; kJailbreakPaths[i]; i++) {
        if (strcmp(path, kJailbreakPaths[i]) == 0) return 1;
        if (strstr(path, kJailbreakPaths[i])) return 1;
    }
    return 0;
}

static int ck_dylib_should_hide(const char *name) {
    if (!name) return 0;
    for (int i = 0; kHideDylibMarkers[i]; i++) {
        if (strstr(name, kHideDylibMarkers[i])) return 1;
    }
    return 0;
}

// ============================================================
//  真实 dlsym 快照
//  dlsym 本身会被我们 hook（挡风控查符号），所以所有 orig 的获取
//  必须走这个缓存，否则 hook 之后再 dlsym 拿到的就是自己的 ck_dlsym,
//  调用链变成 ck_dlsym -> ck_dlsym -> ... 直接爆栈。
// ============================================================
typedef void *(*ck_pdlsym_t)(void *, const char *);
static ck_pdlsym_t g_pdlsym = NULL;

static void *g_real_dlsym(void *handle, const char *symbol) {
    if (!g_pdlsym) {
        // 第一次调用发生在 hook dlsym 之前，拿到的是系统原实现
        g_pdlsym = (ck_pdlsym_t)dlsym(RTLD_DEFAULT, "dlsym");
    }
    if (!g_pdlsym) return NULL;
    return g_pdlsym(handle, symbol);
}

// ============================================================
//  安全 hook：符号不存在就跳过，绝不空指针 MSHookFunction
//  ★ 用 CKInlineHook：内部走 dlsym 解析，没有 Substrate 时返回 NO
//    而不是在二进制里留符号引用（那样 dylib 一加载就被 dyld abort）
// ============================================================
static void ck_hook_symbol(const char *name, void *replacement, void **origOut) {
    void *target = g_real_dlsym(RTLD_DEFAULT, name);
    if (!target) {
        CKLog(@"[hook] 跳过（符号缺失）: %s", name);
        return;
    }
    if (!CKInlineHook(target, replacement, origOut)) {
        if (origOut) *origOut = NULL;
        CKLog(@"[hook] 跳过（无 Substrate，无法 inline hook）: %s", name);
        return;
    }
    CKLog(@"[hook] 已挂载: %s", name);
}

// ============================================================
//  A. 越狱检测：文件层
// ============================================================
typedef int (*stat_t)(const char *, struct stat *);
typedef int (*lstat_t)(const char *, struct stat *);
typedef int (*access_t)(const char *, int);
typedef FILE *(*fopen_t)(const char *, const char *);
typedef int (*open_t)(const char *, int, ...);
typedef char *(*realpath_t)(const char *, char *);

static stat_t  orig_stat = NULL;
static lstat_t orig_lstat = NULL;
static access_t orig_access = NULL;
static fopen_t orig_fopen = NULL;
static open_t  orig_open = NULL;
static realpath_t orig_realpath = NULL;

// ★ 运行时开关：关掉就透传原实现，跟没装 hook 一样。
//   越狱绕过 / 反调试 / dyld 隐藏 三个开关都是实时的，
//   浮窗里一关立刻不再伪装（方便对比测试「装 vs 不装」）。
static inline BOOL ck_jbOn(void)   { return CKFeatureGet(CKFeatureAntiJailbreak); }
static inline BOOL ck_dbgOn(void)  { return CKFeatureGet(CKFeatureAntiDebug); }
static inline BOOL ck_dyldOn(void) { return CKFeatureGet(CKFeatureDyldHide); }

int ck_stat(const char *path, struct stat *buf) {
    if (!orig_stat) orig_stat = (stat_t)g_real_dlsym(RTLD_NEXT, "stat");
    if (ck_jbOn() && ck_path_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

int ck_lstat(const char *path, struct stat *buf) {
    if (!orig_lstat) orig_lstat = (lstat_t)g_real_dlsym(RTLD_NEXT, "lstat");
    if (ck_jbOn() && ck_path_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_lstat(path, buf);
}

int ck_access(const char *path, int mode) {
    if (!orig_access) orig_access = (access_t)g_real_dlsym(RTLD_NEXT, "access");
    if (ck_jbOn() && ck_path_blacklisted(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

FILE *ck_fopen(const char *path, const char *mode) {
    if (!orig_fopen) orig_fopen = (fopen_t)g_real_dlsym(RTLD_NEXT, "fopen");
    if (ck_jbOn() && ck_path_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

int ck_open(const char *path, int oflag, ...) {
    if (!orig_open) orig_open = (open_t)g_real_dlsym(RTLD_NEXT, "open");
    if (ck_jbOn() && ck_path_blacklisted(path)) { errno = ENOENT; return -1; }
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap; va_start(ap, oflag);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    return orig_open(path, oflag, mode);
}

char *ck_realpath(const char *path, char *resolved) {
    if (!orig_realpath) orig_realpath = (realpath_t)g_real_dlsym(RTLD_NEXT, "realpath");
    if (ck_jbOn() && ck_path_blacklisted(path)) { errno = ENOENT; return NULL; }
    return orig_realpath(path, resolved);
}

// ============================================================
//  B. 越狱检测：符号层
// ============================================================
typedef void *(*dlsym_t)(void *, const char *);
static dlsym_t orig_dlsym = NULL;

void *ck_dlsym(void *handle, const char *symbol) {
    if (!orig_dlsym) orig_dlsym = (dlsym_t)g_real_dlsym(RTLD_NEXT, "dlsym");
    if (ck_jbOn() && symbol) {
        static const char *bad[] = {
            "MSHookFunction", "MSHookMessageEx", "MSFindSymbol",
            "MSGetImageByName", "SubstrateHookFunction",
            "CFRunLoopAddSource_cheat", NULL
        };
        for (int i = 0; bad[i]; i++) {
            if (strcmp(symbol, bad[i]) == 0) return NULL;
        }
    }
    return orig_dlsym(handle, symbol);
}

// ============================================================
//  C. 越狱检测：ObjC 层（canOpenURL / fork / system）
// ============================================================
typedef BOOL (*canOpenURL_t)(id, SEL, NSURL *);
static canOpenURL_t orig_canOpenURL = NULL;

static BOOL ck_canOpenURL(id self, SEL _cmd, NSURL *url) {
    if (ck_jbOn()) {
        NSString *s = url.absoluteString.lowercaseString ?: @"";
        static NSArray *bad = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            bad = @[@"cydia://", @"sileo://", @"zbra://", @"filza://", @"undecimus://"];
        });
        for (NSString *b in bad) {
            if ([s hasPrefix:b]) return NO;
        }
    }
    if (orig_canOpenURL) return orig_canOpenURL(self, _cmd, url);
    return NO;
}

typedef pid_t (*fork_t)(void);
static fork_t orig_fork = NULL;
static pid_t ck_fork(void) {
    if (!orig_fork) orig_fork = (fork_t)g_real_dlsym(RTLD_NEXT, "fork");
    if (!ck_jbOn()) return orig_fork ? orig_fork() : 0;
    return -1;   // 永远失败，模拟非越狱
}

// ============================================================
//  D. 沙盒写测试（部分风控会尝试写 /private/）
// ============================================================
typedef int (*sandbox_check_t)(pid_t, const char *, int);
static sandbox_check_t orig_sandbox_check = NULL;
static int ck_sandbox_check(pid_t pid, const char *op, int type) {
    if (!orig_sandbox_check) orig_sandbox_check = (sandbox_check_t)g_real_dlsym(RTLD_NEXT, "sandbox_check");
    if (!ck_jbOn()) return orig_sandbox_check ? orig_sandbox_check(pid, op, type) : 1;
    // 返回 1 表示受限（正常）。风控拿它判断是否脱离沙盒
    return 1;
}


// ============================================================
//  E. 反调试：ptrace / sysctl
// ============================================================
// 用 void * 代替 caddr_t：ABI 完全一致（都是 64 位指针），
// 但不依赖 <sys/types.h> 里的 Darwin 扩展 typedef，任何 SDK 都能编。
typedef int (*ptrace_t)(int, pid_t, void *, int);
static ptrace_t orig_ptrace = NULL;

int ck_ptrace(int request, pid_t pid, void *addr, int data) {
    if (!orig_ptrace) orig_ptrace = (ptrace_t)g_real_dlsym(RTLD_NEXT, "ptrace");
    // PT_DENY_ATTACH = 31
    if (ck_dbgOn() && request == 31) return 0;
    if (!orig_ptrace) return 0;
    return orig_ptrace(request, pid, addr, data);
}

typedef int (*sysctl_t)(int *, unsigned int, void *, size_t *, void *, size_t);
static sysctl_t orig_sysctl = NULL;

int ck_sysctl(int *name, unsigned int namelen, void *oldp, size_t *oldlenp,
              void *newp, size_t newlen) {
    if (!orig_sysctl) orig_sysctl = (sysctl_t)g_real_dlsym(RTLD_NEXT, "sysctl");
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    // CTL_KERN, KERN_PROC, KERN_PROC_PID, pid
    // ★ 必须校验缓冲区长度：oldlenp 是调用方给的缓冲区大小，
    //   小于 0x24 时写 0x20 偏移会越界踩坏堆内存（表现为随机闪退）。
    if (ck_dbgOn() && ret == 0 && oldp && oldlenp && namelen == 4 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_PID &&
        *oldlenp >= 0x24) {
        // struct kinfo_proc 里的 kp_proc.p_flag，arm64 偏移 0x20
        uint32_t *pflag = (uint32_t *)((uint8_t *)oldp + 0x20);
        *pflag &= ~0x800;   // 清 P_TRACED
    }
    return ret;
}

// ============================================================
//  F. 反调试：isatty / getppid
// ============================================================
typedef int (*getppid_t)(void);
static getppid_t orig_getppid = NULL;
static int ck_getppid(void) {
    if (!orig_getppid) orig_getppid = (getppid_t)g_real_dlsym(RTLD_NEXT, "getppid");
    if (!ck_dbgOn() && orig_getppid) return orig_getppid();
    return 1;   // 正常 App 的父进程是 launchd(1)
}

typedef char *(*getenv_t)(const char *);
static getenv_t orig_getenv = NULL;
char *ck_getenv(const char *name) {
    if (!orig_getenv) orig_getenv = (getenv_t)g_real_dlsym(RTLD_NEXT, "getenv");
    if (ck_dbgOn() && name &&
        (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
         strcmp(name, "DYLD_FORCE_FLAT_NAMESPACE") == 0)) {
        return NULL;
    }
    return orig_getenv(name);
}

// ============================================================
//  G. dyld 镜像隐藏（两级）
// ============================================================
typedef uint32_t (*image_count_t)(void);
typedef const char *(*image_name_t)(uint32_t);

static image_count_t orig_image_count = NULL;
static image_name_t  orig_image_name = NULL;

// 安全调用原函数，避免 hook 后自递归
static inline uint32_t ck_raw_image_count(void) {
    return orig_image_count ? orig_image_count() : _dyld_image_count();
}
static inline const char *ck_raw_image_name(uint32_t i) {
    return orig_image_name ? orig_image_name(i) : _dyld_get_image_name(i);
}

// 被隐藏的索引集合
static NSMutableIndexSet *g_hiddenIndexes = nil;

static void ck_scan_hidden_indexes(void) {
    if (g_hiddenIndexes) return;
    g_hiddenIndexes = [NSMutableIndexSet indexSet];

    uint32_t total = ck_raw_image_count();
    for (uint32_t i = 0; i < total; i++) {
        const char *name = ck_raw_image_name(i);
        if (ck_dylib_should_hide(name)) {
            [g_hiddenIndexes addIndex:i];
            CKLog(@"[dyld] 隐藏镜像 #%u: %s", i, name ?: "(null)");
        }
    }
}

// 重排索引：把逻辑索引映射到真实索引
static uint32_t ck_remap_index(uint32_t logical) {
    if (!g_hiddenIndexes || g_hiddenIndexes.count == 0) return logical;
    uint32_t real = 0, seen = 0;
    uint32_t total = ck_raw_image_count();
    for (uint32_t i = 0; i < total; i++) {
        if ([g_hiddenIndexes containsIndex:i]) continue;
        if (seen == logical) { real = i; break; }
        seen++;
    }
    return real;
}

static uint32_t ck_dyld_image_count(void) {
    if (!ck_dyldOn()) return ck_raw_image_count();   // 开关关掉 → 原样返回
    ck_scan_hidden_indexes();
    uint32_t total = ck_raw_image_count();
    return total - (uint32_t)g_hiddenIndexes.count;
}

static const char *ck_dyld_get_image_name(uint32_t idx) {
    if (!ck_dyldOn()) return ck_raw_image_name(idx);
    ck_scan_hidden_indexes();
    return ck_raw_image_name(ck_remap_index(idx));
}

// 直接结构体摘除：对付绕过 API 直接读 dyld_all_image_infos 的风控
// 注意：infoArray 的元素是 dyld_image_info 结构（12/24 字节），不是裸 mach_header 指针
struct ck_dyld_image_info {
    const struct mach_header *imageLoadAddress;
    const char               *imageFilePath;
    uintptr_t                 imageFileModTime;
};

typedef struct {
    uint32_t version;
    uint32_t infoArrayCount;
    const struct ck_dyld_image_info *infoArray;
} ck_dyld_info_t;

static ck_dyld_info_t *ck_get_all_image_infos(void) {
    // dyld_all_image_infos 是 libdyld 导出的全局结构体，dlsym 直接返回其地址
    static ck_dyld_info_t *info = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        info = (ck_dyld_info_t *)g_real_dlsym(RTLD_DEFAULT, "dyld_all_image_infos");
    });
    if (!info) {
        CKLog(@"[dyld] 拿不到 dyld_all_image_infos，跳过结构体层");
        return NULL;
    }

    if (!info->infoArray || info->infoArrayCount == 0) return info;

#if !ENABLE_DYLD_INFOARRAY_PATCH
    // ★ 默认不做结构体层改写。
    //   dyld_all_image_infos 位于 __DATA_CONST，受 codesign 保护；
    //   mprotect 常失败，失败后写入 → SIGBUS。即便 mprotect 成功，
    //   dyld 自身与 CrashReporter 遍历 infoArray 时会摸到已换掉的指针，
    //   同样 SIGBUS/SIGSEGV。只保留函数层隐藏已足够骗过绝大多数检测。
    return info;
#else
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        uint32_t n = info->infoArrayCount;

        // ★ mprotect 必须检查返回值。
        //   iOS 上 __DATA_CONST 页带 codesign 保护，mprotect 会失败（EACCES）。
        //   失败后仍去写 info->infoArray 会直接 SIGBUS/SIGSEGV —— 这是
        //   「注入后几秒随机闪退」的典型来源。
        //   dyld_all_image_infos 在多数系统上本来就在可写 __DATA，先探测：

        // 先看当前是否已经可写：试着读一次同类页的属性
        uintptr_t page = (uintptr_t)info & ~(uintptr_t)0xFFF;
        void *pg = (void *)page;
        int rc = mprotect(pg, 0x1000, PROT_READ | PROT_WRITE);
        if (rc != 0) {
            CKLog(@"[dyld] mprotect 失败（errno=%d），跳过 infoArray 结构体层，"
                  @"只保留 _dyld_image_count/_dyld_get_image_name 层", errno);
            return;
        }

        struct ck_dyld_image_info *dst =
            (struct ck_dyld_image_info *)malloc(sizeof(struct ck_dyld_image_info) * n);
        if (!dst) {
            CKLog(@"[dyld] malloc 失败，跳过结构体层");
            return;
        }
        uint32_t j = 0;
        for (uint32_t i = 0; i < n; i++) {
            const char *path = info->infoArray[i].imageFilePath;
            if (ck_dylib_should_hide(path)) continue;
            dst[j++] = info->infoArray[i];
        }
        info->infoArray = dst;
        info->infoArrayCount = j;
        CKLog(@"[dyld] infoArray 重建: %u -> %u", n, j);
    });
    return info;
#endif
}

// ============================================================
//  安装入口
// ============================================================
void CKInstallJailbreakBypass(void) {
#if ENABLE_ANTI_JAILBREAK
    // 文件层
    ck_hook_symbol("stat",     (void *)ck_stat,     (void **)&orig_stat);
    ck_hook_symbol("lstat",    (void *)ck_lstat,    (void **)&orig_lstat);
    ck_hook_symbol("access",   (void *)ck_access,   (void **)&orig_access);
    ck_hook_symbol("fopen",    (void *)ck_fopen,    (void **)&orig_fopen);
    ck_hook_symbol("open",     (void *)ck_open,     (void **)&orig_open);
    ck_hook_symbol("realpath", (void *)ck_realpath, (void **)&orig_realpath);

    // 符号层
    ck_hook_symbol("dlsym", (void *)ck_dlsym, (void **)&orig_dlsym);

    // ObjC 层
    Method m = class_getInstanceMethod([UIApplication class], @selector(canOpenURL:));
    if (m) {
        orig_canOpenURL = (canOpenURL_t)method_getImplementation(m);
        method_setImplementation(m, (IMP)ck_canOpenURL);
        CKLog(@"[hook] UIApplication -canOpenURL: 已挂载");
    }

    ck_hook_symbol("fork", (void *)ck_fork, (void **)&orig_fork);

    // 沙盒
    ck_hook_symbol("sandbox_check", (void *)ck_sandbox_check, (void **)&orig_sandbox_check);

    CKLog(@"越狱检测绕过已安装");
#endif
}

void CKInstallAntiDebugBypass(void) {
#if ENABLE_ANTI_DEBUG
    ck_hook_symbol("ptrace", (void *)ck_ptrace, (void **)&orig_ptrace);
    ck_hook_symbol("sysctl", (void *)ck_sysctl, (void **)&orig_sysctl);
    ck_hook_symbol("getppid", (void *)ck_getppid, (void **)&orig_getppid);
    ck_hook_symbol("getenv", (void *)ck_getenv, (void **)&orig_getenv);
    CKLog(@"反调试绕过已安装");
#endif
}

void CKInstallDyldHide(void) {
#if ENABLE_DYLD_HIDE
    ck_hook_symbol("_dyld_image_count", (void *)ck_dyld_image_count,
                   (void **)&orig_image_count);
    ck_hook_symbol("_dyld_get_image_name", (void *)ck_dyld_get_image_name,
                   (void **)&orig_image_name);
    // 结构体层：先探一次，让 orig_all_image_infos 就位
    ck_get_all_image_infos();
    CKLog(@"dyld 镜像隐藏已安装");
#endif
}

void CKInstallAntiDetect(void) {
    CKInstallJailbreakBypass();
    CKInstallAntiDebugBypass();
    CKInstallDyldHide();
}
