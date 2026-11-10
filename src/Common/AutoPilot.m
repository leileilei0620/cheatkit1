//
//  Common/AutoPilot.m
//
//  ★ 设计要点：参数的唯一真相在 CKParam 表里（也就是浮窗的滑块）。
//    自动调参**不另存一份状态**，它每次读 CKParamGet、写 CKParamSet。
//    好处：
//      1. AI 调完之后，浮窗滑块会跟着动，用户能看见它做了什么
//      2. 用户手动拖滑块，AI 立刻读到新值，不会互相覆盖
//      3. 少一套持久化，少一类「重启后两边不一致」的 bug
//    只有「冻结状态 / 上次误差 / 调整计数」这些过程量在内存里。
//
//  ★ 线程模型：
//    调度用 dispatch_source（15 秒周期，跑在自己的串行队列上），
//    不依赖主线程 runloop，App 卡顿时也不会漏拍。
//

#import "AutoPilot.h"
#import "FeatureFlags.h"
#import "Rewriter.h"
#import "Stats.h"
#import "Log.h"
#import "../Config.h"
#if ENABLE_AUTOPILOT_REMOTE
#import "../Modules/AdEngine.h"      // CKDetectedSDKs
#endif

#import <dispatch/dispatch.h>
#import <math.h>
#import <pthread.h>
#import <sys/time.h>
#import <string.h>
#import <stdlib.h>

// ============================================================
//  0) 一条曲线同时推 6 个参数
// ============================================================
//
//  a=0（保守）→ a=1（激进）
//    - 倍率 1.2 起步：再低等于没改
//    - 倍率 8.0 封顶：再高 eCPM 脱离该品类正常区间，容易被聚合平台标异常
//    - 冷却 120→8 秒：8 秒是「下一支广告加载完」的物理下限，再短会拿到 nofill
//    - 观看 28→0 秒：0 表示不模拟观看，直接把播放器判完
//    - 点击延迟 1200→200 毫秒：200ms 以下机械特征太明显
//
typedef struct {
    const char *key;
    double lo;          // a=0 时的值
    double hi;          // a=1 时的值
} CKAPCurve;

static const CKAPCurve kAPCurve[] = {
    { CKP_ECPM_MUL,     1.2,    8.0   },
    { CKP_REWARD_COOL,  120.0,  8.0   },
    { CKP_WATCH_MIN,    28.0,   0.0   },
    { CKP_WATCH_MAX,    60.0,   0.5   },
    { CKP_CLICK_MIN,    1200.0, 200.0 },
    { CKP_CLICK_MAX,    3500.0, 900.0 },
};
#define CK_AP_CURVE_COUNT (int)(sizeof(kAPCurve) / sizeof(kAPCurve[0]))

// ============================================================
//  1) 过程状态（参数本身不在这里）
// ============================================================
#define CK_AP_TICK_SEC        15.0    // 采样周期
#define CK_AP_MIN_ADJUST_SEC  20.0    // 两次自动调整的最小间隔
#define CK_AP_MAX_DELTA       0.08    // 单次激进程度最大变化
#define CK_AP_MAX_RATIO       0.08    // 单次参数写入相对当前值的最大比例
#define CK_AP_NOIMPROVE_LIMIT 3       // 连续几次没改善就冻结

static pthread_mutex_t g_apLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t g_apQueue = NULL;
static dispatch_source_t g_apTimer = NULL;
static BOOL     g_running    = NO;
static BOOL     g_frozen     = NO;
static double   g_lastAdjust = 0;
static double   g_lastErr    = -1;
static double   g_lastRate   = 0;
static int      g_noImprove  = 0;
static int      g_adjustCount = 0;
static NSString *g_reason    = nil;

static double ck_ap_now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

// ============================================================
//  2) 写入（全部经过夹取）
// ============================================================

// 相对当前值限制幅度，避免一次跳太多
static double ck_ap_limit(double cur, double want) {
    if (cur == 0) return want;
    double lo = cur * (1.0 - CK_AP_MAX_RATIO);
    double hi = cur * (1.0 + CK_AP_MAX_RATIO);
    if (want < lo) return lo;
    if (want > hi) return hi;
    return want;
}

// 把激进程度铺到 6 个参数上。
//   smooth=YES 时单次幅度限制 8%（闭环内部用，防震荡）
//   smooth=NO  时一次性推到位（用户手动拨滑块用）
static void ck_ap_applyCurve(double a, BOOL smooth) {
    if (a < 0) a = 0;
    if (a > 1) a = 1;

    int applied = 0;
    for (int i = 0; i < CK_AP_CURVE_COUNT; i++) {
        const CKAPCurve *c = &kAPCurve[i];
        double want = c->lo + (c->hi - c->lo) * a;
        double cur  = CKParamGet(c->key);
        double v    = smooth ? ck_ap_limit(cur, want) : want;
        if (fabs(v - cur) < 1e-9) continue;
        CKParamSet(c->key, v);      // 内部还会夹到滑块范围内
        applied++;
    }

    // 保证 watch.max >= watch.min（否则指纹模块算时长会拿到负区间）
    double wmin = CKParamGet(CKP_WATCH_MIN);
    double wmax = CKParamGet(CKP_WATCH_MAX);
    if (wmax < wmin + 0.5) CKParamSet(CKP_WATCH_MAX, wmin + 0.5);

    if (applied > 0) {
        CKLog(@"[AI] 激进 %.2f → %d 个参数调整（倍率 %.2f 冷却 %.0fs 观看 %.0f~%.0fs）",
              a, applied,
              CKParamGet(CKP_ECPM_MUL),
              CKParamGet(CKP_REWARD_COOL),
              CKParamGet(CKP_WATCH_MIN),
              CKParamGet(CKP_WATCH_MAX));
    }
}

// ============================================================
//  3) 闭环评估
// ============================================================
#if ENABLE_AUTOPILOT_REMOTE
static void ck_ap_remote_post(void);   // 定义在文件末尾，tick 里周期调用
#endif

static void ck_ap_tick_impl(void) {
    double now = ck_ap_now();

    pthread_mutex_lock(&g_apLock);
    if (!g_running) {
        pthread_mutex_unlock(&g_apLock);
        return;
    }
    pthread_mutex_unlock(&g_apLock);

    // ★ 开关是「即时生效」语义：浮窗里关掉，下一拍就停手（定时器留着，
    //   再打开能立刻恢复，不用重启 App）。CKFeatureGet 是位运算，很便宜。
    if (!CKFeatureGet(CKFeatureAutoPilot)) {
        pthread_mutex_lock(&g_apLock);
        g_reason = @"已关闭（在浮窗里打开「AI 自动调参」才会跑）";
        pthread_mutex_unlock(&g_apLock);
        return;
    }

    pthread_mutex_lock(&g_apLock);
    BOOL frozen = g_frozen;
    double lastAdjust = g_lastAdjust;
    double lastErr = g_lastErr;
    double lastRate = g_lastRate;
    int noImprove = g_noImprove;
    int adjustCount = g_adjustCount;
    pthread_mutex_unlock(&g_apLock);

    double aggr   = CKParamGet(CKP_AP_AGGR);
    double target = CKParamGet(CKP_AP_TARGET);

#if ENABLE_AUTOPILOT_REMOTE
    // 每 4 拍（约 1 分钟）向远程大脑上报一次
    static int s_remoteTick = 0;
    if (++s_remoteTick >= 4) { s_remoteTick = 0; ck_ap_remote_post(); }
#endif

    // ---- 采集 ----
    CKStatsSnapshot s = CKStatsGet();

    // 一条 hook 都没装上：调参没有意义，只更新原因，不动参数
    int hooks = s.rewardHooks + s.playHooks + s.exactSlots;
    if (hooks == 0) {
        pthread_mutex_lock(&g_apLock);
        g_reason = @"没有装上任何 hook，暂停调参（看日志确认 SDK 是否被识别）";
        pthread_mutex_unlock(&g_apLock);
        return;
    }

    // 发奖速率（次/分钟）：累计次数 ÷ 运行分钟
    double minutes = s.uptime / 60.0;
    double rate = (minutes > 0.15) ? ((double)s.rewardsFired / minutes) : 0.0;

    // ---- 冻结 ----
    if (frozen) {
        pthread_mutex_lock(&g_apLock);
        g_reason = [NSString stringWithFormat:
            @"已冻结（连续 %d 次调整未改善，实测 %.1f/分）。点「恢复自动」解除",
            CK_AP_NOIMPROVE_LIMIT, lastRate];
        pthread_mutex_unlock(&g_apLock);
        return;
    }

    // ---- 改善判定 ----
    double err = fabs(rate - target);
    if (lastErr >= 0) {
        noImprove = (err >= lastErr - 0.02) ? (noImprove + 1) : 0;
    }

    if (noImprove >= CK_AP_NOIMPROVE_LIMIT) {
        pthread_mutex_lock(&g_apLock);
        g_frozen = YES;
        g_lastErr = err;
        g_lastRate = rate;
        g_noImprove = noImprove;
        g_reason = [NSString stringWithFormat:
            @"已冻结（连续 %d 次调整未改善，实测 %.1f/分 目标 %.1f/分）",
            CK_AP_NOIMPROVE_LIMIT, rate, target];
        pthread_mutex_unlock(&g_apLock);
        CKLog(@"[AI] 参数保持不变，避免来回震荡");
        return;
    }

    // ---- 节流 ----
    if (now - lastAdjust < CK_AP_MIN_ADJUST_SEC) {
        pthread_mutex_lock(&g_apLock);
        g_lastErr = err;
        g_lastRate = rate;
        g_noImprove = noImprove;
        g_reason = [NSString stringWithFormat:
            @"采样 %.1f/分（目标 %.1f），刚调过，等 %.0fs 再动",
            rate, target, CK_AP_MIN_ADJUST_SEC - (now - lastAdjust)];
        pthread_mutex_unlock(&g_apLock);
        return;
    }

    // ---- 决策 ----
    double delta = 0;
    NSString *why = nil;

    if (rate < target * 0.8) {
        delta = CK_AP_MAX_DELTA;
        why = [NSString stringWithFormat:@"实测 %.1f/分 < 目标 %.1f×0.8，收紧延迟类参数",
               rate, target];
    } else if (rate > target * 1.3) {
        delta = -CK_AP_MAX_DELTA;
        why = [NSString stringWithFormat:@"实测 %.1f/分 > 目标 %.1f×1.3，放松节奏避风控",
               rate, target];
    } else {
        pthread_mutex_lock(&g_apLock);
        g_lastErr = err;
        g_lastRate = rate;
        g_noImprove = noImprove;
        g_reason = [NSString stringWithFormat:
            @"实测 %.1f/分 已在目标区间（%.1f~%.1f），保持激进 %.2f",
            rate, target * 0.8, target * 1.3, aggr];
        pthread_mutex_unlock(&g_apLock);
        return;
    }

    double next = aggr + delta;
    if (next < 0) next = 0;
    if (next > 1) next = 1;

    // 已经顶到边界，再推也没用 → 冻结
    if (fabs(next - aggr) < 1e-9) {
        pthread_mutex_lock(&g_apLock);
        g_frozen = YES;
        g_lastErr = err;
        g_lastRate = rate;
        g_noImprove = noImprove;
        g_reason = [NSString stringWithFormat:
            @"已冻结（激进程度已到 %.0f%% 边界，实测 %.1f/分）", aggr * 100, rate];
        pthread_mutex_unlock(&g_apLock);
        CKLog(@"[AI] 激进程度已到边界，停止自动调整");
        return;
    }

    // 先记账再写参数（写参数会碰 NSUserDefaults，别在锁里做 IO）
    pthread_mutex_lock(&g_apLock);
    g_lastAdjust = now;
    g_lastErr = err;
    g_lastRate = rate;
    g_noImprove = noImprove;
    g_adjustCount = adjustCount + 1;
    g_reason = why;
    int n = g_adjustCount;
    pthread_mutex_unlock(&g_apLock);

    CKParamSet(CKP_AP_AGGR, next);          // 滑块会同步跳过去
    ck_ap_applyCurve(next, YES);

    // ★ why 是中文理由，必须用 %@ 传 NSString；用 %s 传 UTF8String 会乱码。
    CKLog(@"[AI] 第 %d 次调整 → 激进 %.2f（%@）", n, next, why ?: @"?");
}

static void ck_ap_tick(void *ctx) {
    @autoreleasepool {
        ck_ap_tick_impl();
    }
}


// ============================================================
//  4) 对外 API
// ============================================================
static dispatch_queue_t ck_ap_queue(void) {
    if (!g_apQueue) {
        g_apQueue = dispatch_queue_create("com.cheatkit.autopilot", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(g_apQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    }
    return g_apQueue;
}

void CKAPStart(void) {
    if (!CKFeatureGet(CKFeatureAutoPilot)) {
        CKLog(@"[AI] 开关是关的，不启动（浮窗里打开后会自动起）");
        return;
    }
    pthread_mutex_lock(&g_apLock);
    if (g_running) {
        pthread_mutex_unlock(&g_apLock);
        return;
    }
    g_running = YES;
    g_frozen  = NO;
    g_lastErr = -1;
    g_noImprove = 0;
    g_lastAdjust = 0;          // 0 = 从没调过，第一拍就可以动
    g_reason  = @"已启动，等待第一次采样";
    pthread_mutex_unlock(&g_apLock);

    double a0 = CKParamGet(CKP_AP_AGGR);
    double t0 = CKParamGet(CKP_AP_TARGET);
    CKLog(@"[AI] 自动调参启动：激进 %.2f，目标 %.1f 次/分，采样 %.0fs", a0, t0, CK_AP_TICK_SEC);

    // 启动时按当前激进程度铺一次曲线（单调收敛，不跳变）
    ck_ap_applyCurve(a0, YES);

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ck_ap_queue());
    if (!t) {
        CKLog(@"[AI] 定时器创建失败，自动调参未生效");
        pthread_mutex_lock(&g_apLock);
        g_running = NO;
        pthread_mutex_unlock(&g_apLock);
        return;
    }

    uint64_t interval = (uint64_t)(CK_AP_TICK_SEC * NSEC_PER_SEC);
    uint64_t leeway   = (uint64_t)(2.0 * NSEC_PER_SEC);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, interval), interval, leeway);
    dispatch_source_set_event_handler_f(t, ck_ap_tick);
    dispatch_resume(t);

    pthread_mutex_lock(&g_apLock);
    g_apTimer = t;
    pthread_mutex_unlock(&g_apLock);
}

void CKAPStop(void) {
    pthread_mutex_lock(&g_apLock);
    dispatch_source_t t = g_apTimer;
    g_apTimer = NULL;
    g_running = NO;
    g_reason  = @"已停止";
    pthread_mutex_unlock(&g_apLock);

    if (t) dispatch_source_cancel(t);
    CKLog(@"[AI] 自动调参已停止");
}

BOOL CKAPRunning(void) {
    pthread_mutex_lock(&g_apLock);
    BOOL r = g_running && !g_frozen;
    pthread_mutex_unlock(&g_apLock);
    return r;
}

void CKAPApplyCurveNow(double a) {
    if (a < 0) a = 0;
    if (a > 1) a = 1;

    pthread_mutex_lock(&g_apLock);
    g_frozen = NO;          // 手动调了就等于「恢复自动」
    g_noImprove = 0;
    g_lastErr = -1;
    pthread_mutex_unlock(&g_apLock);

    CKParamSet(CKP_AP_AGGR, a);
    CKLog(@"[AI] 手动激进 %.2f → 一次性铺开 6 个参数", a);
    ck_ap_applyCurve(a, NO);    // 手动不受 8% 限制
}

void CKAPResume(void) {
    pthread_mutex_lock(&g_apLock);
    BOOL wasFrozen = g_frozen;
    g_frozen = NO;
    g_noImprove = 0;
    g_lastErr = -1;
    g_lastAdjust = 0;
    g_reason = @"已恢复自动（手动解除冻结）";
    pthread_mutex_unlock(&g_apLock);

    if (wasFrozen) CKLog(@"[AI] 已解除冻结，下一轮重新评估");
}

void CKAPTickNow(void) {
    dispatch_async(ck_ap_queue(), ^{
        @autoreleasepool {
            ck_ap_tick_impl();
        }
    });
}

NSString *CKAPStatusLine(void) {
    pthread_mutex_lock(&g_apLock);
    double r = g_lastRate;
    int n = g_adjustCount;
    BOOL frozen = g_frozen;
    BOOL running = g_running;
    pthread_mutex_unlock(&g_apLock);

    // 开关关着时，定时器可能还在（为了能秒开），但语义上就是「没在调」
    if (!CKFeatureGet(CKFeatureAutoPilot)) running = NO;

    double a = CKParamGet(CKP_AP_AGGR);
    double t = CKParamGet(CKP_AP_TARGET);

    CKStatsSnapshot s = CKStatsGet();
    NSMutableString *line = [NSMutableString string];

    if (!running) {
        [line appendString:@"AI 已关闭"];
    } else if (frozen) {
        [line appendFormat:@"AI 冻结 激进%.2f 实测%.1f/分", a, r];
    } else {
        [line appendFormat:@"AI 激进%.2f 目标%.1f 实测%.1f/分", a, t, r];
    }

    [line appendFormat:@" 倍率%.1f", CKParamGet(CKP_ECPM_MUL)];
    if (n > 0) [line appendFormat:@" 调%d次", n];
    if (s.uptime > 0 && s.uptime < 60) [line appendString:@" （采样中）"];

    return line;
}

NSString *CKAPLastReason(void) {
    pthread_mutex_lock(&g_apLock);
    NSString *r = g_reason ?: @"";
    pthread_mutex_unlock(&g_apLock);
    return r;
}

// ============================================================
//  5) 远程大脑（可选，默认关）
// ============================================================
//
//  只管解析和应用，不联网。返回成功应用的参数个数。
//  远程给的值同样过「幅度限制 + 范围夹取」，改不坏本地配置。
NSInteger CKAPApplyRemoteJSON(NSData *json) {
    if (!json || json.length == 0) return -1;

    NSError *err = nil;
    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:&err];
    if (!root || ![root isKindOfClass:[NSDictionary class]]) {
        CKLog(@"[AI] 远程配置不是 JSON 对象，忽略");
        return -1;
    }

    NSDictionary *params = nil;
    id p = [(NSDictionary *)root objectForKey:@"params"];
    if ([p isKindOfClass:[NSDictionary class]]) {
        params = p;             // {"params":{...}}
    } else if ([root count] > 0) {
        params = root;          // 也接受平坦的 {"ecpm.multiplier":4.2}
    }
    if (!params) return -1;

    NSInteger applied = 0;
    for (NSString *key in params) {
        if (![key isKindOfClass:[NSString class]]) continue;

        const CKParamDef *def = CKParamDefFor(key.UTF8String);
        if (!def) {
            CKLog(@"[AI] 远程给了未知参数，忽略: %@", key);
            continue;
        }

        id v = [params objectForKey:key];
        double want = 0;
        if ([v isKindOfClass:[NSNumber class]])       want = [v doubleValue];
        else if ([v isKindOfClass:[NSString class]])  want = [(NSString *)v doubleValue];
        else continue;
        if (!isfinite(want)) continue;

        double cur = CKParamGet(def->key);
        double clamped = ck_ap_limit(cur, want);
        CKParamSet(def->key, clamped);      // 内部再夹到 [lo,hi]
        applied++;
        CKLog(@"[AI] 远程参数 %@: %.2f → %.2f", key, cur, CKParamGet(def->key));
    }

    if (applied > 0) {
        pthread_mutex_lock(&g_apLock);
        g_reason = [NSString stringWithFormat:@"应用了 %ld 个远程参数", (long)applied];
        pthread_mutex_unlock(&g_apLock);
    }
    return applied;
}

#if ENABLE_AUTOPILOT_REMOTE
static BOOL g_apRemoteBusy = NO;

static void ck_ap_remote_post(void) {
    @autoreleasepool {
        if (g_apRemoteBusy) return;

        NSString *urlStr = @(AUTOPILOT_ENDPOINT);
        if (urlStr.length == 0) return;

        g_apRemoteBusy = YES;

        CKStatsSnapshot s = CKStatsGet();
        NSDictionary *payload = @{
            @"bundle":  CKCurrentBundleID() ?: @"unknown",
            @"sdks":    CKDetectedSDKs() ?: @[],
            @"hook":    @{ @"reward": @(s.rewardHooks), @"play": @(s.playHooks),
                           @"exact": @(s.exactSlots) },
            @"ecpm":    @(s.ecpmHits),
            @"reward":  @(s.rewardsFired),
            @"uptime":  @(s.uptime),
            @"aggr":    @(CKParamGet(CKP_AP_AGGR)),
            @"target":  @(CKParamGet(CKP_AP_TARGET)),
            @"params":  @{
                @(CKP_ECPM_MUL):    @(CKParamGet(CKP_ECPM_MUL)),
                @(CKP_REWARD_COOL): @(CKParamGet(CKP_REWARD_COOL)),
                @(CKP_WATCH_MIN):   @(CKParamGet(CKP_WATCH_MIN)),
                @(CKP_WATCH_MAX):   @(CKParamGet(CKP_WATCH_MAX)),
            },
        };

        NSError *jerr = nil;
        NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jerr];
        if (!body) { g_apRemoteBusy = NO; return; }

        NSMutableURLRequest *req =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 8.0;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = body;

        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 8.0;
        NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

        [[sess dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
            @autoreleasepool {
                if (!data || e) {
                    CKLog(@"[AI] 远程大脑请求失败: %@", e.localizedDescription ?: @"无数据");
                    g_apRemoteBusy = NO;
                    [sess finishTasksAndInvalidate];
                    return;
                }
                NSInteger n = CKAPApplyRemoteJSON(data);
                CKLog(@"[AI] 远程大脑返回，应用 %ld 个参数", (long)n);
                g_apRemoteBusy = NO;
                [sess finishTasksAndInvalidate];
            }
        }] resume];
    }
}
#endif
