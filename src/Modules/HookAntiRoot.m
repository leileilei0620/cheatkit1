//
//  Modules/HookAntiRoot.m
//  App 自有风控对抗
//
//  覆盖：
//   1) App 签名校验（改过 dylib 后主体签名 hash 变了，风控常查）
//   2) Bundle 完整性校验
//   3) 常见探针方法（isJailbroken / isRooted / isTampered / debuggerAttached）
//

#import "HookAntiRoot.h"
#import "../Common/Log.h"
#import "../Common/HookUtil.h"
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>
#import "../vendor/ck_compat.h"

// ============================================================
//  A. 签名校验：- (NSString *)bundleSignature / + (NSData *)codeSignature
//      直接 Hook 掉，返回原始签名的镜像值
// ============================================================
static NSString *g_pinnedSignature = nil;

void CKPinSignature(NSString *sig) {
    g_pinnedSignature = [sig copy];
    CKLog(@"[sign] 固定签名锚点: %@", [sig substringToIndex:MIN(16, sig.length)]);
}

static IMP g_origSignature = NULL;
static NSString *ck_bundleSignature(id self, SEL _cmd) {
    if (g_pinnedSignature) return g_pinnedSignature;
    if (g_origSignature)
        return ((NSString *(*)(id, SEL))g_origSignature)(self, _cmd);
    return @"";
}

// ============================================================
//  B. 探针方法批量兜底
//      所有名字里含 jailbreak/rooted/tamper/debug 的 BOOL 方法
//      一律返回「安全」值
// ============================================================
static IMP g_origProbe = NULL;

static BOOL ck_probe_false(id self, SEL _cmd) {
    CKLog(@"[probe] %s -> NO", sel_getName(_cmd));
    return NO;
}

static void ck_install_probe_hooks(void) {
    static const char *keywords[] = {
        "isJailbroken", "isJailBreak", "jailbreakDetected",
        "isRooted", "isRoot", "rootDetected",
        "isTampered", "isModified", "isRepackaged",
        "debuggerAttached", "isDebuggerAttached", "isBeingDebugged",
        "isEmulator", "isSimulator", "fridaDetected",
        NULL
    };

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int hooked = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        if (!methods) continue;

        for (unsigned int j = 0; j < methodCount; j++) {
            const char *selName = sel_getName(method_getName(methods[j]));
            if (!selName) continue;

            for (int k = 0; keywords[k]; k++) {
                if (ck_strcasecmp_eq(selName, keywords[k]) ||
                    ck_strcasestr(selName, keywords[k])) {
                    const char *enc = method_getTypeEncoding(methods[j]);
                    // 只改无参、返回 BOOL/c 的方法，带参数的不动
                    if (enc && enc[0] == 'c' && enc[1] == '1' && enc[2] == '@' &&
                        enc[3] == ':' && enc[4] == '\0') {
                        // 已 hook 的跳过
                        if (method_getImplementation(methods[j]) == (IMP)ck_probe_false)
                            break;
                        method_setImplementation(methods[j], (IMP)ck_probe_false);
                        CKLog(@"[probe] hook %s -%s", class_getName(classes[i]), selName);
                        hooked++;
                    }
                    break;
                }
            }
        }
        free(methods);
    }
    free(classes);
    CKLog(@"[probe] 共 hook %d 个探针方法", hooked);
}

// ============================================================
//  C. Bundle 完整性：校验 main bundle 的 Info.plist 与可执行段
//      风控会算 Mach-O 的 __TEXT.__text 哈希，与我们改过的 dylib 无关
//      但有些会算整个 bundle 目录树，需要屏蔽新增的 Frameworks/*.dylib
// ============================================================
static IMP g_origContentsOfDirectory = NULL;
static NSArray *ck_contentsOfDirectory(id self, SEL _cmd, NSString *path) {
    NSArray *list = ((NSArray *(*)(id, SEL, NSString *))g_origContentsOfDirectory)
                    (self, _cmd, path);
    if (!list) return list;

    // 过滤掉注入进来的 dylib
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSString *obj, id bindings) {
        NSString *lower = obj.lowercaseString;
        return !([lower hasSuffix:@".dylib"] || [lower hasSuffix:@".deb"]);
    }];
    return [list filteredArrayUsingPredicate:p];
}

// ============================================================
//  安装
// ============================================================
void CKInstallAntiRootHooks(void) {
#if ENABLE_ANTI_JAILBREAK
    ck_install_probe_hooks();

    Class fm = objc_getClass("NSFileManager");
    if (fm) {
        SEL sel = @selector(contentsOfDirectoryAtPath:error:);
        Method m = class_getInstanceMethod(fm, sel);
        if (m) {
            g_origContentsOfDirectory = method_getImplementation(m);
            method_setImplementation(m, (IMP)ck_contentsOfDirectory);
        }
    }
    CKLog(@"App 风控对抗安装完成");
#endif
}
