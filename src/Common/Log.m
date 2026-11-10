//
//  Common/Log.m
//

#import "Log.h"
#import <stdarg.h>
#import <UIKit/UIKit.h>
#import <pthread.h>

// ============================================================
//  日志环形缓冲（给浮窗用）
//  不依赖文件，只在内存里留最近 32 条
// ============================================================
#define CK_LOG_KEEP 32

static NSMutableArray<NSString *> *g_logs = nil;
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;

static void ck_pushLog(NSString *msg) {
    if (!msg) return;
    pthread_mutex_lock(&g_logLock);
    if (!g_logs) g_logs = [NSMutableArray arrayWithCapacity:CK_LOG_KEEP];
    [g_logs insertObject:msg atIndex:0];              // 新的在前
    while (g_logs.count > CK_LOG_KEEP) [g_logs removeLastObject];
    pthread_mutex_unlock(&g_logLock);
}

NSArray<NSString *> *CKRecentLogs(NSUInteger n) {
    pthread_mutex_lock(&g_logLock);
    NSArray *copy = g_logs ? [g_logs copy] : @[];
    pthread_mutex_unlock(&g_logLock);
    if (n == 0 || n >= copy.count) return copy;
    return [copy subarrayWithRange:NSMakeRange(0, n)];
}

void CKLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
#if VERBOSE_LOG
    NSLog(@"%@%@", LOG_PREFIX, msg);
#endif
    // 无论 VERBOSE_LOG 开关如何，浮窗都要能看到最近动态
    ck_pushLog(msg);
}

NSString *CKCurrentBundleID(void) {
    static NSString *bid = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    });
    return bid;
}

// 是否系统进程（SpringBoard / 系统 App / 守护进程）
static BOOL ck_isSystemProcess(NSString *bid) {
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    NSString *excl = EXCLUDE_BUNDLE_PREFIXES;
    if (excl.length > 0 && [bid hasPrefix:excl]) return YES;
    // 无 bundle id 的多半是 daemon
    if ([bid isEqualToString:@"unknown"]) return YES;
    return NO;
}

// 是否命中敏感 App（银行 / 支付 / 钱包）
static BOOL ck_isSensitiveApp(NSString *bid) {
#if SKIP_SENSITIVE_APPS
    NSString *low = [bid lowercaseString];
    NSArray *kw = @[SENSITIVE_KEYWORDS];
    for (NSString *k in kw) {
        if ([low containsString:k]) return YES;
    }
#else
    (void)bid;
#endif
    return NO;
}

BOOL CKIsTargetProcess(void) {
    static BOOL isTarget = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = CKCurrentBundleID();
        if (ck_isSystemProcess(bid)) { isTarget = NO; return; }

#if CK_GENERIC_MODE
        // 通用模式：所有第三方 App 都装，敏感类应用跳过
        isTarget = !ck_isSensitiveApp(bid);
#else
        // 定向模式：只装白名单
        NSArray *targets = @[TARGET_BUNDLE_IDS];
        isTarget = [targets containsObject:bid];
#endif
    });
    return isTarget;
}
