//
//  Common/SubstrateRT.m —— 运行时解析 Substrate / ElleKit
//
//  设计要点：
//    1. 全程 dlsym，不写任何 MS* 调用 → 二进制里零 Substrate 符号，
//       加载阶段不会因符号缺失 abort
//    2. 一次性解析并缓存（dispatch_once），热路径零开销
//    3. 每个能力独立可选：只有 MSHookFunction 没有 MSHookMessageEx 也能工作
//    4. 优先用 RTLD_DEFAULT 查（ElleKit 把符号导出到全局命名空间），
//       再退一步按镜像路径 dlopen 后查（老版 Substrate）
//

#import "SubstrateRT.h"
#import "Log.h"
#import <dlfcn.h>

// ---- 函数指针类型（与 vendor/substrate.h 原型一致）----
typedef void (*ck_MSHookFunction_t)(void *symbol, void *replace, void **result);
typedef void (*ck_MSHookMessageEx_t)(Class cls, SEL sel, IMP imp, IMP *result);

static ck_MSHookFunction_t    g_MSHookFunction    = NULL;
static ck_MSHookMessageEx_t   g_MSHookMessageEx   = NULL;
static BOOL                   g_resolved          = NO;
static BOOL                   g_hasSubstrate      = NO;

// ============================================================
//  一次性解析
// ============================================================
static void ck_resolve_once(void) {
    if (g_resolved) return;
    g_resolved = YES;

    // 路线 1：全局命名空间（ElleKit / Dopamine 走这条）
    g_MSHookFunction  = (ck_MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    g_MSHookMessageEx = (ck_MSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");

    // 路线 2：显式打开已知的注入框架镜像再查
    //   （符号没有导出到全局时，dlsym(RTLD_DEFAULT) 会拿不到）
    if (!g_MSHookFunction || !g_MSHookMessageEx) {
        static const char *kFrameworks[] = {
            "/usr/lib/libsubstrate.dylib",
            "/usr/lib/libhooker.dylib",
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libhooker.dylib",
            "/usr/lib/libellekit.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            NULL
        };
        for (int i = 0; kFrameworks[i]; i++) {
            void *h = dlopen(kFrameworks[i], RTLD_LAZY | RTLD_NOLOAD);
            if (!h) h = dlopen(kFrameworks[i], RTLD_LAZY);
            if (!h) continue;

            if (!g_MSHookFunction)
                g_MSHookFunction = (ck_MSHookFunction_t)dlsym(h, "MSHookFunction");
            if (!g_MSHookMessageEx)
                g_MSHookMessageEx = (ck_MSHookMessageEx_t)dlsym(h, "MSHookMessageEx");

            // 不 dlclose：框架要一直活着
            if (g_MSHookFunction) break;
        }
    }

    // ElleKit 在部分版本上导出的是 LHHookFunctions 系列别名
    if (!g_MSHookFunction) {
        g_MSHookFunction = (ck_MSHookFunction_t)dlsym(RTLD_DEFAULT, "LHHookFunctions");
    }

    g_hasSubstrate = (g_MSHookFunction != NULL);
}

BOOL CKHasSubstrate(void) {
    ck_resolve_once();
    return g_hasSubstrate;
}

// ============================================================
//  C 函数 inline hook
// ============================================================
BOOL CKInlineHook(void *symbol, void *replacement, void **origOut) {
    ck_resolve_once();

    if (!symbol || !replacement) return NO;

    if (!g_MSHookFunction) {
        // 没有 Substrate：不假装成功，明确返回 NO 让调用方走降级
        if (origOut) *origOut = NULL;
        return NO;
    }

    g_MSHookFunction(symbol, replacement, origOut);
    return YES;
}

// ============================================================
//  ObjC 方法替换
//    有 MSHookMessageEx → 用它（保留 super 调用链）
//    没有              → method_setImplementation（够用，绝大多数场景等价）
// ============================================================
BOOL CKHookInstanceMethod(Class cls, SEL sel, IMP imp, IMP *origOut) {
    if (!cls || !sel || !imp) return NO;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    ck_resolve_once();
    if (g_MSHookMessageEx) {
        IMP old = NULL;
        g_MSHookMessageEx(cls, sel, imp, &old);
        if (origOut) *origOut = old;
        return YES;
    }

    // 降级：纯 runtime
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, imp);
    return YES;
}

BOOL CKHookClassMethod(Class cls, SEL sel, IMP imp, IMP *origOut) {
    if (!cls || !sel || !imp) return NO;

    // 类方法挂在 metaclass 上
    Class meta = object_getClass(cls);
    if (!meta) return NO;

    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;

    ck_resolve_once();
    if (g_MSHookMessageEx) {
        IMP old = NULL;
        g_MSHookMessageEx(meta, sel, imp, &old);
        if (origOut) *origOut = old;
        return YES;
    }

    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, imp);
    return YES;
}

// ============================================================
//  状态打印（浮窗里能看到「有没有 Substrate」）
// ============================================================
void CKDumpSubstrateStatus(void) {
    ck_resolve_once();

    if (g_hasSubstrate) {
        CKLog(@"[rt] Substrate/ElleKit 可用（MSHookFunction=%p MSHookMessageEx=%p）",
              (void *)g_MSHookFunction, (void *)g_MSHookMessageEx);
    } else {
        CKLog(@"[rt] 无 Substrate/ElleKit → C 函数 hook 全部跳过，ObjC hook 降级为 method_setImplementation");
    }

    if (g_MSHookFunction && !g_MSHookMessageEx) {
        CKLog(@"[rt] 注意：只有 MSHookFunction，ObjC hook 同样走降级");
    }
}
