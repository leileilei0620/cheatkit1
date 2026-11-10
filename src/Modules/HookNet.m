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
#import "../vendor/substrate.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
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
// 注意：不能覆盖所有 delegate 的同一个 IMP，否则链式调用会串。
// 这里按“首次遇到的 delegate 实现”为 orig，其余类直接放行。
typedef void (*DidReceiveChallenge_t)(id, SEL, NSURLSession *, NSURLSessionTask *,
                                      NSURLAuthenticationChallenge *,
                                      void (^)(NSURLSessionAuthChallengeDisposition,
                                               NSURLCredential *));
static DidReceiveChallenge_t orig_didReceiveChallenge = NULL;

static void ck_didReceiveChallenge(id self, SEL _cmd, NSURLSession *session,
                                   NSURLSessionTask *task,
                                   NSURLAuthenticationChallenge *challenge,
                                   void (^completion)(NSURLSessionAuthChallengeDisposition,
                                                      NSURLCredential *)) {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust] && ck_netOn()) {
        NSURLCredential *cred = [NSURLCredential credentialForTrust:
                                 challenge.protectionSpace.serverTrust];
        CKLog(@"[pin] 放行 serverTrust: %@", challenge.protectionSpace.host);
        completion(NSURLSessionAuthChallengeUseCredential, cred);
        return;
    }
    // 开关关掉时也走这里 → 系统默认校验（pinning 生效）
    completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

static void ck_install_session_delegate_hook(void) {
    SEL sel = @selector(URLSession:didReceiveChallenge:completionHandler:);
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int hooked = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Method m = class_getInstanceMethod(classes[i], sel);
        if (!m) continue;
        if (method_getImplementation(m) == (IMP)ck_didReceiveChallenge) continue;
        method_setImplementation(m, (IMP)ck_didReceiveChallenge);
        hooked++;
    }
    free(classes);
    CKLog(@"[pin] URLSession delegate hook: %d 个", hooked);
}

// ---- A3: 自定义 TrustManager（只探测，打印供人工确认） ----
static void ck_install_custom_trust_hook(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;
    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        if (ck_strcasestr(name, "TrustManager") || ck_strcasestr(name, "Pinning") ||
            ck_strcasestr(name, "SSLHelper") || ck_strcasestr(name, "CertificatePinner")) {
            CKLog(@"[pin] 自定义校验类: %s", name);
            for (NSString *s in CKListMethods(name, NO)) {
                CKLog(@"[pin]    - %@", s);
            }
        }
    }
    free(classes);
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
    // A1 —— SecTrust 层（最底层，覆盖 NSURLSession / CFNetwork / AFNetworking）
    void *h1 = dlsym(RTLD_DEFAULT, "SecTrustEvaluate");
    if (h1) MSHookFunction(h1, (void *)ck_SecTrustEvaluate, (void **)&orig_SecTrustEvaluate);

    void *h2 = dlsym(RTLD_DEFAULT, "SecTrustEvaluateWithError");
    if (h2) MSHookFunction(h2, (void *)ck_SecTrustEvaluateWithError,
                           (void **)&orig_SecTrustEvaluateWithError);

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
