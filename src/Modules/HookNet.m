//
//  Modules/HookNet.m
//  SSL Pinning 绕过 + URL 层改写 + 响应篡改
//

#import "HookNet.h"
#import "../Common/Log.h"
#import "../Common/HookUtil.h"
#import "../Common/Rewriter.h"
#import "../Common/FeatureFlags.h"   // 运行时开关
#import "../Config.h"
#import "../Common/SubstrateRT.h"    // 运行时解析（裸注入不崩）
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>       // CKNetSlot 槽表加锁
#import "../vendor/ck_compat.h"

// ============================================================
//  A. 通用 Pinning 绕过
//     A1. SecTrustEvaluate / SecTrustEvaluateWithError / SecTrustEvaluateWithError 变体
//     A2. NSURLSession delegate: -URLSession:didReceiveChallenge:...
//     A3. 自定义 TrustManager 类探测
// ============================================================

typedef OSStatus (*SecTrustEvaluate_t)(SecTrustRef, SecTrustResultType *);
static SecTrustEvaluate_t orig_SecTrustEvaluate = NULL;

// ★ 运行时开关：关掉就把原实现调回去，pinning 校验恢复正常
static inline BOOL ck_netOn(void) { return CKFeatureGet(CKFeatureNetTamper); }

static OSStatus ck_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    if (!ck_netOn() && orig_SecTrustEvaluate) {
        return orig_SecTrustEvaluate(trust, result);
    }
    if (result) *result = kSecTrustResultProceed;
    return errSecSuccess;
}

typedef bool (*SecTrustEvaluateWithError_t)(SecTrustRef, CFErrorRef *);
static SecTrustEvaluateWithError_t orig_SecTrustEvaluateWithError = NULL;

static bool ck_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    if (!ck_netOn() && orig_SecTrustEvaluateWithError) {
        return orig_SecTrustEvaluateWithError(trust, error);
    }
    if (error) *error = NULL;
    return true;
}

// ---- A2: NSURLSession delegate ----
//
// ★ 这个函数曾经把 App 点崩（EXC_CRASH / SIGABRT）：
//     0 CoreFoundation  __exceptionPreprocess
//     1 libobjc         objc_exception_throw
//     2 CoreFoundation  +[NSObject(NSObject) _copyDescription]
//     3 CoreFoundation  ___forwarding___
//     4 CoreFoundation  _CF_forwarding_prep_0
//     5 CheatKit.dylib  ck_didReceiveChallenge
//   原因：同一个 IMP 被挂到多个类上，某些类的方法签名里
//   challenge / completion 的真实类型与我们假设的不一致
//   （KVO 动态子类、AFNetworking 的包装类、广告 SDK 自建 delegate），
//   一取属性就触发 unrecognized selector。
//
//   加固措施（三层）：
//     1. 每个类单独记 orig，不在挑战是 serverTrust 时调用它 —— 保持原行为
//     2. 取 challenge / completion 之前做 isKindOfClass 与空判
//     3. 签名对不上（参数个数/类型不同）的类直接跳过不 hook
typedef void (*DidReceiveChallenge_t)(id, SEL, NSURLSession *, NSURLSessionTask *,
                                      NSURLAuthenticationChallenge *,
                                      void (^)(NSURLSessionAuthChallengeDisposition,
                                               NSURLCredential *));

#define CK_NET_SLOTS 128
typedef struct { Class cls; DidReceiveChallenge_t orig; } CKNetSlot;
static CKNetSlot g_netSlots[CK_NET_SLOTS];
static int g_netSlotCount = 0;
static pthread_mutex_t g_netLock = PTHREAD_MUTEX_INITIALIZER;

static DidReceiveChallenge_t ck_netOrigFor(id self) {
    if (!self) return NULL;
    Class c = object_getClass(self);
    for (;;) {
        pthread_mutex_lock(&g_netLock);
        for (int i = 0; i < g_netSlotCount; i++) {
            if (g_netSlots[i].cls == c) {
                DidReceiveChallenge_t o = g_netSlots[i].orig;
                pthread_mutex_unlock(&g_netLock);
                return o;
            }
        }
        pthread_mutex_unlock(&g_netLock);
        c = class_getSuperclass(c);
        if (!c) break;
    }
    return NULL;
}

static void ck_netRecord(Class cls, DidReceiveChallenge_t orig) {
    pthread_mutex_lock(&g_netLock);
    if (g_netSlotCount < CK_NET_SLOTS) {
        g_netSlots[g_netSlotCount].cls  = cls;
        g_netSlots[g_netSlotCount].orig = orig;
        g_netSlotCount++;
    }
    pthread_mutex_unlock(&g_netLock);
}

static void ck_didReceiveChallenge(id self, SEL _cmd, NSURLSession *session,
                                   NSURLSessionTask *task,
                                   NSURLAuthenticationChallenge *challenge,
                                   void (^completion)(NSURLSessionAuthChallengeDisposition,
                                                      NSURLCredential *)) {
    DidReceiveChallenge_t orig = ck_netOrigFor(self);

    // ★★ 最后一道防线：整个过程包 @try。
    //   这个函数跑在 CFNetwork 的后台 NSOperationQueue 上，
    //   ObjC 异常在这里没人捕获 → std::terminate → abort →
    //   EXC_CRASH / SIGABRT（实测崩溃就是这个：
    //     __exceptionPreprocess → objc_exception_throw →
    //     +[NSObject _copyDescription] → ___forwarding___ →
    //     _CF_forwarding_prep_0 → ck_didReceiveChallenge）。
    //   宁可放弃这一次放行，也不能把整个 App 带走。
    @try {
        // 第一道防线：不是预期的类型，直接交还原实现，绝不自己编 completion
        if (!completion || !challenge ||
            ![challenge isKindOfClass:[NSURLAuthenticationChallenge class]]) {
            if (orig) orig(self, _cmd, session, task, challenge, completion);
            return;
        }

        // 只在 serverTrust + 开关打开 且 challenge 结构可信时才放行
        if (ck_netOn() && [challenge respondsToSelector:@selector(protectionSpace)]) {
            NSURLProtectionSpace *ps = challenge.protectionSpace;
            if ([ps isKindOfClass:[NSURLProtectionSpace class]] &&
                [ps.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
                ps.serverTrust) {
                NSURLCredential *cred = [NSURLCredential credentialForTrust:ps.serverTrust];
                if (cred) {
                    CKLog(@"[pin] 放行 serverTrust: %@", ps.host ?: @"?");
                    completion(NSURLSessionAuthChallengeUseCredential, cred);
                    return;
                }
            }
        }

        // 其余情况（Basic/Digest/ClientCertificate，或开关关着）全部交还原实现
        if (orig) {
            orig(self, _cmd, session, task, challenge, completion);
        } else {
            completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
    }
    @catch (NSException *e) {
        CKLog(@"[pin] didReceiveChallenge 异常已吞掉（%@: %@），回落默认处理",
              (e.name ?: @"?"), (e.reason ?: @"?"));
        if (orig) {
            @try { orig(self, _cmd, session, task, challenge, completion); }
            @catch (NSException *e2) { (void)e2; }
        } else if (completion) {
            completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
    }
}

static void ck_install_session_delegate_hook(void) {
#if !ENABLE_NET_SESSION_HOOK_SAFE && !ENABLE_NET_SESSION_HOOK_ALL
    CKLog(@"[pin] URLSession delegate hook 全部关闭");
    return;
#else
    SEL sel = @selector(URLSession:didReceiveChallenge:completionHandler:);
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    // ★ 为什么不能无差别 hook 全进程：
    //   这个 SEL 不只广告 SDK 实现，Security.framework / CFNetwork / WebKit /
    //   各种网络库的私有类都实现了它。把它们全部替换成同一个 IMP 后，
    //   SecTrust 会被并发重复评估 —— 实测崩溃栈就是
    //     getMethodNoSuper_nolock → class_getInstanceMethod
    //   与 CFNetwork 线程里的 __SecTrustEvaluateFastAsync_block_invoke 撞车，
    //   EXC_BAD_ACCESS / SIGBUS / KERN_PROTECTION_FAILURE。
    //   所以默认只接管「本 App + 本 App 的 Frameworks」里的类。
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];

    int hooked = 0, skipped = 0, badsig = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];

        // ★★ 必须只处理「自己实现了这个方法」的类。
        //   class_getInstanceMethod 会沿父类链查找：如果 A 没实现、
        //   父类 B 实现了，它返回的是 B 的 Method，method_setImplementation
        //   改的就成了 B —— 所有 B 的子类一起中招，签名还未必一致，
        //   于是 _CF_forwarding_prep_0 / unrecognized selector 崩溃。
        //   实测栈：objc_exception_throw ← _copyDescription ← ___forwarding___
        //           ← ck_didReceiveChallenge
        unsigned int ownCount = 0;
        Method *ownList = class_copyMethodList(cls, &ownCount);
        BOOL implementedHere = NO;
        if (ownList) {
            for (unsigned int k = 0; k < ownCount; k++) {
                if (method_getName(ownList[k]) == sel) { implementedHere = YES; break; }
            }
            free(ownList);
        }
        if (!implementedHere) continue;

        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        if (method_getImplementation(m) == (IMP)ck_didReceiveChallenge) continue;

        // ★ 签名校验：数清参数个数，别去硬匹配 encoding 字符串
        //   （不同 SDK/编译器产出的偏移写法不一致，硬匹配会误杀正常类）
        //   self + _cmd + session + task + challenge + completion = 6 个
        NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 6) { badsig++; continue; }
        // 返回类型必须是 void
        const char *rt = [sig methodReturnType];
        if (!rt || rt[0] != 'v') { badsig++; continue; }

#if ENABLE_NET_SESSION_HOOK_ALL
        // 全量模式：连系统类一起换（仅供调试，会崩）
        DidReceiveChallenge_t prev = (DidReceiveChallenge_t)method_getImplementation(m);
        ck_netRecord(cls, prev);
        method_setImplementation(m, (IMP)ck_didReceiveChallenge);
        hooked++;
#else
        // 安全模式：只碰 App 自己镜像里的类
        const char *imageName = class_getImageName(cls);
        BOOL own = NO;
        if (imageName && bundlePath) {
            NSString *p = [NSString stringWithUTF8String:imageName];
            if (p && [p hasPrefix:bundlePath]) own = YES;
        }
        if (!own) { skipped++; continue; }

        // ★ 记下这个类自己的原实现，trampoline 里按 self 精确找回
        DidReceiveChallenge_t prev = (DidReceiveChallenge_t)method_getImplementation(m);
        ck_netRecord(cls, prev);
        method_setImplementation(m, (IMP)ck_didReceiveChallenge);
        hooked++;
#endif
    }
    free(classes);
    CKLog(@"[pin] URLSession delegate hook: %d 个（跳过系统类 %d / 签名不符 %d）",
          hooked, skipped, badsig);
#endif
}

// ---- A3: 自定义 TrustManager（只探测，打印供人工确认） ----
static void ck_install_custom_trust_hook(void) {
    // ★ 同样只扫 App 自身镜像：
    //   对全进程数千个类调 class_getInstanceMethod / 列方法，
    //   等于在高频线程活跃时反复进 objc runtime 锁，得不偿失。
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int found = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *imageName = class_getImageName(cls);
        if (!imageName || !bundlePath) continue;
        NSString *p = [NSString stringWithUTF8String:imageName];
        if (!p || ![p hasPrefix:bundlePath]) continue;

        const char *name = class_getName(cls);
        if (!name) continue;
        if (ck_strcasestr(name, "TrustManager") || ck_strcasestr(name, "Pinning") ||
            ck_strcasestr(name, "SSLHelper") || ck_strcasestr(name, "CertificatePinner")) {
            CKLog(@"[pin] 自定义校验类: %s", name);
            for (NSString *s in CKListMethods(name, NO)) {
                CKLog(@"[pin]    - %@", s);
            }
            found++;
        }
    }
    free(classes);
    CKLog(@"[pin] 自定义校验类扫描完成: %d 个", found);
}

// ============================================================
//  B. URL 层改写（默认关闭，避免影响业务请求）
// ============================================================
static IMP g_origSetURL = NULL;
static void ck_setURL(id self, SEL _cmd, NSURL *url) {
    ((void (*)(id, SEL, NSURL *))g_origSetURL)(self, _cmd, url);
}

// ============================================================
//  C. 响应层：completionHandler 里的 data 改写
// ============================================================
typedef void (*DataTaskCompletion_t)(id, SEL, NSData *, NSURLResponse *, NSError *);
static DataTaskCompletion_t orig_dataCompletion = NULL;

static void ck_dataCompletion(id self, SEL _cmd, NSData *data,
                              NSURLResponse *resp, NSError *err) {
    if (ck_netOn() && data.length > 0 && data.length < 256 * 1024) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (json) {
            id rewritten = CKRewriteObject(json, 0);
            NSData *newData = [NSJSONSerialization dataWithJSONObject:rewritten
                                                              options:0 error:NULL];
            if (newData && ![newData isEqualToData:data]) {
                CKLog(@"[net] 响应改写 %lu -> %lu bytes",
                      (unsigned long)data.length, (unsigned long)newData.length);
                data = newData;
            }
        }
    }
    if (orig_dataCompletion)
        orig_dataCompletion(self, _cmd, data, resp, err);
}

// ============================================================
//  安装
// ============================================================
void CKInstallNetHooks(void) {
#if ENABLE_NET_TAMPER
#if ENABLE_NET_TRUST_HOOK
    // A1 —— SecTrust 层（最底层，覆盖 NSURLSession / CFNetwork / AFNetworking）
    // ★ 默认关闭：inline hook 有「打补丁瞬间线程正在执行」的窗口，
    //   系统 TLS 握手线程常驻，撞上就是野跳转。需要时再手动开。
    void *h1 = dlsym(RTLD_DEFAULT, "SecTrustEvaluate");
    if (h1 && !CKInlineHook(h1, (void *)ck_SecTrustEvaluate,
                            (void **)&orig_SecTrustEvaluate)) {
        orig_SecTrustEvaluate = NULL;
        CKLog(@"[net] SecTrustEvaluate 跳过（无 Substrate）");
    }

    void *h2 = dlsym(RTLD_DEFAULT, "SecTrustEvaluateWithError");
    if (h2 && !CKInlineHook(h2, (void *)ck_SecTrustEvaluateWithError,
                            (void **)&orig_SecTrustEvaluateWithError)) {
        orig_SecTrustEvaluateWithError = NULL;
        CKLog(@"[net] SecTrustEvaluateWithError 跳过（无 Substrate）");
    }
#else
    CKLog(@"[net] SecTrust inline hook 未启用（ENABLE_NET_TRUST_HOOK=0）");
#endif

    // A2 / A3
    ck_install_session_delegate_hook();
    ck_install_custom_trust_hook();

    // B —— 只保存原实现，不主动降级（需要时改 ck_setURL 内部）
    Class reqCls = objc_getClass("NSMutableURLRequest");
    if (reqCls) {
        Method mURL = class_getInstanceMethod(reqCls, @selector(setURL:));
        if (mURL) {
            g_origSetURL = method_getImplementation(mURL);
        }
    }

    CKLog(@"[net] 安装完成");
#endif
}
