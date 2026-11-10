//
//  Modules/AdEngine.m —— 通用广告引擎
//
//  三层接管：
//   L1 指纹识别：类名前缀/关键字 → 判定属于哪家 SDK
//   L2 形状 hook：解析 method type encoding，按参数形状选对应 trampoline
//                  BOOL 参数一律改写 YES（verify/valid/effective 全中）
//                  整型参数 0 → 1（奖励数量）
//   L3 补发奖励：向 delegate 直接投递成功回调（NSInvocation，参数按签名填）
//
//  注意：trampoline 按 (Class, SEL) 双键查原实现，
//        因为同一个 SEL 在不同类里可能是不同 IMP，只按 SEL 会串。
//

#import "AdEngine.h"
#import "../Common/Log.h"
#import "../Common/HookUtil.h"
#import "../Common/Rewriter.h"
#import "../Common/Stats.h"
#import "../Common/FeatureFlags.h"   // 运行时开关：浮窗里关掉即刻空转
#import "../Config.h"
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>
#import <stdint.h>
#import <pthread.h>
#import <dispatch/dispatch.h>   // dispatch_after / dispatch_get_main_queue 显式声明
#import "../vendor/ck_compat.h" // strcasestr / strncasecmp 的自带实现（可移植）

// ============================================================
//  L1. SDK 指纹表
//  前缀一律 ≥3 字符，避免 "IS"/"AL"/"AT" 这种两字母误伤系统类
// ============================================================
typedef struct {
    const char *name;        // 展示名
    const char *prefixes;    // 类名前缀，逗号分隔
    const char *keywords;    // 类名关键字（包含匹配），逗号分隔
    int         enabled;     // 对应 Config.h 里的 SDK_* 开关
} CKSdkFingerprint;

static const CKSdkFingerprint kSdkTable[] = {
    // 字节系
    // ★ 播放器/倒计时类（BU_ZFPlayer / BUPlayer / BUExpressReward）比奖励类本身更关键：
    //   真正掐表、回报「看完」的是它们，奖励类只是收尾发通知
    {"穿山甲/Pangle", "BURewarded,BUMRewarded,CSJRewarded,PAGRewarded,BUAdEcpm,BUMAdEcpm,CSJAdEcpm,"
                      "BUNativeExpressReward,BUExpressReward,BURNativeExpressReward,"
                      "BU_ZFPlayer,BUPlayer,BUNativeExpressFullscreen,ABURewardedVideo,"
                      "CSJNativeExpress,BUVideoEngine,CSJRewardVideo",
     "RewardedVideoAd,RewardVideoAd,ExpressReward,RewardedVideo", SDK_PANGLE},
    // 腾讯
    // ★ GDTAutoCountTimer（倒计时）/ GDTBizFeedVideoPlayer（播放器）是掐表的
    {"优量汇/GDT",     "GDTReward,GDTeCPM,GDTAdEcpm,GDTSDK,GDTDLReward,GDTDLVideo,"
                      "GDTAdReward,GDTAutoCountTimer,GDTBizFeedVideoPlayer",
     "RewardVideoAd,RewardedVideoAd", SDK_GDT},
    // 快手
    // ★ KSAdCountdown（倒计时）/ KSAdWebReward（H5 激励）/ KSVideoAd 是掐表的
    {"快手联盟",       "KSAd,KSFeed,KSFull,KSInterstitial,KSReward,KSVideoAd,"
                      "KSAdReward,KSAdCountdown,KSAdWebReward,KSVideo",
     "RewardVideoAd,RewardAd,RewardedVideo", SDK_KUAISHOU},
    // 百度
    {"百度联盟",       "BaiduMobAd,BaiduMob,BaiduApp,BAIDU,BaiduMobAdReward,"
                      "BaiduMobAdVideo,BaiduMobAdCountdown",
     "RewardVideoAd,RewardedAd", SDK_BAIDU},
    // Google
    {"AdMob",          "GADRewarded,GADAdValue,GADAdNetworkResponseInfo,GADResponseInfo,GADRequest",
     "RewardedAd,RewardedInterstitial", SDK_ADMOB},
    // AppLovin
    {"AppLovin/MAX",   "ALAdReward,ALReward,ALAdPlacement,MAAd,MAInterstitial,MAAdapter,AppLovin",
     NULL, SDK_APPLOVIN},
    // IronSource
    {"IronSource",     "ISRewarded,ISAdReward,ISImpression,LPMImpression,LPMAd,IronSource",
     NULL, SDK_IRONSOURCE},
    // 汇量
    {"Mintegral",      "MTGReward,MTReward,MTGAd,MTRewarded,Mintegral",
     NULL, SDK_MINTEGRAL},
    // Unity
    {"UnityAds",       "UnityAds,UADSReward,UADSBanner",
     NULL, SDK_UNITYADS},
    // Vungle / Liftoff
    {"Vungle/Liftoff", "VungleAd,VNGReward,VungleSDK,Liftoff",
     NULL, SDK_VUNGLE},
    // Sigmob（Wind 是 Sigmob 的旧品牌名）
    {"Sigmob",         "SMReward,SigmobAd,SIGReward,Sigmob,"
                      "WindReward,WindFullscreen,WindCountdown,WindAd,SigmobFullscreen,SigmobReward",
     NULL, SDK_SIGMOB},
    // Chartboost
    {"Chartboost",     "CHBReward,Chartboost",
     NULL, SDK_CHARTBOOST},
    // 聚合
    {"TopOn/AnyThink", "ATRewarded,ATAd,AnyThink,AWMReward",
     NULL, SDK_TOPTON},
    {"TradPlus",       "TPReward,TradPlusAd,TradPlus",
     NULL, SDK_TRADPLUS},
    {"GroMore",        "GMReward,GMEcpm,GroMore",
     NULL, SDK_GROMORE},
    // ★ 通用播放器 / 计时器（不属于某一家，多 SDK 复用）
    //   TKVideoPlayer / TKTimer 是优量汇&快手的公共播放组件，
    //   TTAVPlayer / TTPlayer / TVLPlayer 是字节的。
    //   刻意【不】收 AVPlayerViewController：它是系统类，
    //   一旦被 hook，play/pause 之类的方法会被播放类关键词命中，
    //   会把 App 里所有视频播放搞坏。
    {"通用播放器",     "TKVideoPlayer,TKTimer,TTAVPlayer,TTPlayer,TVLPlayer,"
                      "TVLPlayerInternal,BU_ZFPlayerView",
     "VideoPlayer,Countdown,RewardedVideo,RewardVideo,IncentiveVideo", SDK_GENERIC},
};
static const size_t kSdkTableCount = sizeof(kSdkTable) / sizeof(kSdkTable[0]);

static NSMutableSet<NSString *> *g_detected = nil;

static BOOL ck_prefixMatch(const char *name, const char *list) {
    if (!name || !list || !*name) return NO;
    const char *p = list;
    while (*p) {
        const char *comma = strchr(p, ',');
        size_t len = comma ? (size_t)(comma - p) : strlen(p);
        if (len >= 3 && ck_strncasecmp_eq(name, p, len)) return YES;
        if (!comma) break;
        p = comma + 1;
    }
    return NO;
}

static BOOL ck_kwMatch(const char *name, const char *list) {
    if (!name || !list) return NO;
    const char *p = list;
    while (*p) {
        const char *comma = strchr(p, ',');
        size_t len = comma ? (size_t)(comma - p) : strlen(p);
        if (len > 0 && len < 96) {
            char buf[96];
            memcpy(buf, p, len);
            buf[len] = 0;
            if (ck_strcasestr(name, buf)) return YES;
        }
        if (!comma) break;
        p = comma + 1;
    }
    return NO;
}

static const char *ck_sdkOfName(const char *name) {
    if (!name) return NULL;
    for (size_t i = 0; i < kSdkTableCount; i++) {
        const CKSdkFingerprint *f = &kSdkTable[i];
        if (!f->enabled) continue;                       // Config.h 里关掉的跳过
        if (f->prefixes && ck_prefixMatch(name, f->prefixes)) return f->name;
        if (f->keywords && ck_kwMatch(name, f->keywords)) return f->name;
    }
    return NULL;
}

static BOOL ck_isAdClass(const char *name) {
    return name && ck_sdkOfName(name) != NULL;
}

// ---- 万能兜底（SDK_GENERIC）：认不出厂商时靠类名词根猜 ----
// 只在 SDK_GENERIC=1 时生效。因为后续只 hook 含 reward/play/fail 的方法，
// 误抓一个普通类也不会造成伤害，最多多几次 method_setImplementation。
static BOOL ck_genericAdClass(const char *name) {
#if SDK_GENERIC
    if (!name || name[0] == '_') return NO;
    // 明确排除的系统/UI 基类
    static const char *skip[] = {
        "UI", "NS", "CF", "CA", "MK", "WK", "SK", "AV", "PH", "GK",
        "CL", "HK", "UN", "SV", "MTL", "OS_", NULL
    };
    for (int i = 0; skip[i]; i++) {
        if (strncmp(name, skip[i], strlen(skip[i])) == 0) {
            // UI 开头的里也有 UIAdReport 这类，只在含 Ad 时才放行
            if (ck_strcasestr(name, "ad") == NULL) return NO;
            break;
        }
    }
    static const char *roots[] = {
        "reward", "interstitial", "bannerad", "adloader", "adrequest",
        "adview", "admanager", "adnetwork", "adimpression", "adrevenue",
        "adreward", "adcontent", "adsdk", "adevent",
        // 播放/计时类：必须带 ad 前缀，否则会命中满屏的视频播放器
        "adcountdown", "advideo", "adplayer", "adtimer", "adplayend", NULL
    };
    for (int i = 0; roots[i]; i++) {
        if (ck_strcasestr(name, roots[i])) return YES;
    }
    return NO;
#else
    (void)name;
    return NO;
#endif
}

static void ck_noteDetected(const char *sdk) {
    if (!sdk) return;
    if (!g_detected) g_detected = [NSMutableSet set];
    NSString *s = @(sdk);
    if (![g_detected containsObject:s]) {
        [g_detected addObject:s];
        CKLog(@"[引擎] 识别到 SDK: %@", s);
    }
}

NSArray<NSString *> *CKDetectedSDKs(void) {
    return g_detected ? g_detected.allObjects : @[];
}

// ============================================================
//  L2. 形状解析
// ============================================================
typedef enum { CKArgID = 0, CKArgBool, CKArgInt, CKArgOther } CKArgKind;

#define CK_MAX_ARGS 4
typedef struct {
    int      argc;
    CKArgKind kinds[CK_MAX_ARGS];
} CKShape;

static BOOL ck_parseShape(const char *enc, CKShape *out) {
    if (!enc || !out) return NO;
    memset(out, 0, sizeof(*out));
    const char *p = enc;
    if (*p != 'v' && *p != 'V') return NO;
    p++;
    if (*p != '@') return NO; p++;
    if (*p != ':') return NO; p++;

    int n = 0;
    while (*p && n < CK_MAX_ARGS) {
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
               *p == 'O' || *p == 'R' || *p == 'V' || *p == 'A') p++;
        char t = *p;
        if (t == 0) break;

        CKArgKind k = CKArgOther;
        if (t == '@' || t == '#') {
            k = CKArgID; p++;
            if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
        } else if (t == 'c' || t == 'B') {
            k = CKArgBool; p++;
        } else if (strchr("iqIslLQSC", t)) {
            k = CKArgInt; p++;
        } else if (t == 'd' || t == 'f' || t == 'D' || t == '*') {
            p++;
        } else if (t == '{' || t == '[') {
            char open = t, close = (t == '{') ? '}' : ']';
            int depth = 0;
            while (*p) {
                if (*p == open) depth++;
                else if (*p == close) { depth--; if (depth == 0) { p++; break; } }
                p++;
            }
        } else if (t == '^') {
            p++;
            while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
                   *p == 'O' || *p == 'R' || *p == 'V') p++;
            if (*p == '{') {
                int depth = 0;
                while (*p) {
                    if (*p == '{') depth++;
                    else if (*p == '}') { depth--; if (depth == 0) { p++; break; } }
                    p++;
                }
            } else if (*p == '@' || *p == '#') {
                p++;
                if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
            } else {
                p++;
            }
        } else {
            p++;
        }
        out->kinds[n++] = k;
    }
    out->argc = n;
    return YES;
}

// ============================================================
//  全局 slot 表 —— 双键 (Class, SEL)
// ============================================================
typedef struct {
    Class    cls;
    SEL      sel;
    IMP      orig;
    BOOL     used;
} CKSlot;

#define CK_MAX_SLOTS 2048
static CKSlot g_slots[CK_MAX_SLOTS];
static int    g_slotCount = 0;
static pthread_mutex_t g_slotLock = PTHREAD_MUTEX_INITIALIZER;

// 从 self 的类开始沿父类链找 (cls, sel)，覆盖继承场景
static IMP ck_origFor(id self, SEL sel) {
    Class c = object_getClass(self);
    pthread_mutex_lock(&g_slotLock);
    for (; c != Nil; c = class_getSuperclass(c)) {
        for (int i = 0; i < g_slotCount; i++) {
            if (g_slots[i].used && g_slots[i].sel == sel && g_slots[i].cls == c) {
                IMP imp = g_slots[i].orig;
                pthread_mutex_unlock(&g_slotLock);
                return imp;
            }
        }
    }
    pthread_mutex_unlock(&g_slotLock);
    return NULL;
}

// ============================================================
//  Trampolines
//
//  ★ 开关在这里判定：CKFeatureRewardForce 关掉时不改任何参数，
//    直接透传给原实现，等价于没装 hook。这样浮窗里一关立刻生效，
//    不用重启 App、不用重打包。
// ============================================================
static inline BOOL ck_rewardOn(void) { return CKFeatureGet(CKFeatureRewardForce); }

static void ck_h0(id self, SEL _cmd) {
    IMP o = ck_origFor(self, _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
}
static void ck_h1(id self, SEL _cmd, id a) {
    IMP o = ck_origFor(self, _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a);
}
static void ck_h2_ib(id self, SEL _cmd, id a, BOOL b) {
    IMP o = ck_origFor(self, _cmd);
    if (ck_rewardOn() && !b) {
        CKLog(@"[引擎] -%s 参数2 NO -> YES", sel_getName(_cmd));
        b = YES;
    }
    if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, a, b);
}
static void ck_h2_ii(id self, SEL _cmd, id a, id b) {
    IMP o = ck_origFor(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a, b);
}
static void ck_h2_in(id self, SEL _cmd, id a, NSInteger b) {
    IMP o = ck_origFor(self, _cmd);
    if (ck_rewardOn() && b == 0) b = 1;
    if (o) ((void (*)(id, SEL, id, NSInteger))o)(self, _cmd, a, b);
}
static void ck_h3_iii(id self, SEL _cmd, id a, id b, id c) {
    IMP o = ck_origFor(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, id))o)(self, _cmd, a, b, c);
}
static void ck_h3_ibi(id self, SEL _cmd, id a, BOOL b, id c) {
    IMP o = ck_origFor(self, _cmd);
    if (ck_rewardOn() && !b) {
        CKLog(@"[引擎] -%s 参数2 NO -> YES", sel_getName(_cmd));
        b = YES;
    }
    if (o) ((void (*)(id, SEL, id, BOOL, id))o)(self, _cmd, a, b, c);
}
static void ck_h3_iib(id self, SEL _cmd, id a, id b, BOOL c) {
    IMP o = ck_origFor(self, _cmd);
    if (ck_rewardOn() && !c) {
        CKLog(@"[引擎] -%s 参数3 NO -> YES", sel_getName(_cmd));
        c = YES;
    }
    if (o) ((void (*)(id, SEL, id, id, BOOL))o)(self, _cmd, a, b, c);
}
static void ck_h4_iiii(id self, SEL _cmd, id a, id b, id c, id d) {
    IMP o = ck_origFor(self, _cmd);
    if (o) ((void (*)(id, SEL, id, id, id, id))o)(self, _cmd, a, b, c, d);
}

static IMP ck_pickTrampoline(CKShape sh) {
    switch (sh.argc) {
        case 0: return (IMP)ck_h0;
        case 1: return (IMP)ck_h1;
        case 2:
            if (sh.kinds[1] == CKArgBool) return (IMP)ck_h2_ib;
            if (sh.kinds[1] == CKArgInt)  return (IMP)ck_h2_in;
            return (IMP)ck_h2_ii;
        case 3:
            if (sh.kinds[1] == CKArgBool) return (IMP)ck_h3_ibi;
            if (sh.kinds[2] == CKArgBool) return (IMP)ck_h3_iib;
            return (IMP)ck_h3_iii;
        case 4: return (IMP)ck_h4_iiii;
        default: return NULL;
    }
}

// ============================================================
//  关键词判定
// ============================================================
static BOOL ck_selHasAny(const char *sel, const char **kw, size_t n) {
    if (!sel) return NO;
    for (size_t i = 0; i < n; i++) if (ck_strcasestr(sel, kw[i])) return YES;
    return NO;
}

static BOOL ck_isRewardSel(const char *sel) {
    static const char *kw[] = {
        // 奖励/校验类
        "reward", "verify", "verified", "effective", "earn",
        "convert", "incentive", "success",
        // 完播类 —— 播放器/倒计时才是真正掐表的地方，
        // 这些是它们回报「看完了」的入口
        "didfinish", "playfinish", "complete",
        "playend", "didend", "watchfinish", "didwatch",
        "rewardvideoend", "videofinish"
    };
    return ck_selHasAny(sel, kw, sizeof(kw)/sizeof(kw[0]));
}
static BOOL ck_isPlaySel(const char *sel) {
    static const char *kw[] = {
        "show", "present", "render", "expose",
        "playstart", "didstart", "didplay", "videostart", "countdownstart"
    };
    return ck_selHasAny(sel, kw, sizeof(kw)/sizeof(kw[0]));
}
static BOOL ck_isFailSel(const char *sel) {
    static const char *kw[] = {"fail", "error", "nofill", "no_fill", "didclose", "skip", "cancel"};
    return ck_selHasAny(sel, kw, sizeof(kw)/sizeof(kw[0]));
}

// ============================================================
//  L3. 补发奖励
// ============================================================
static NSArray<NSString *> *ck_rewardSelCandidates(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            // 穿山甲
            @"rewardedVideoAdServerRewardDidSucceed:verify:",
            @"rewardedVideoAdDidRewardEffective:",
            @"rewardedVideoAdDidPlayFinish:didFailWithError:",
            // 优量汇
            @"gdt_rewardVideoAdDidRewardEffective:info:",
            @"gdt_rewardVideoAdDidPlayFinish:",
            // 快手
            @"rewardVideoAdDidRewardEffective:info:",
            @"rewardVideoAdDidComplete:",
            // 百度
            @"rewardedAdDidSuccessful:",
            @"rewardedAdDidReward:",
            // AdMob
            @"rewardedAd:userDidEarnReward:",
            // AppLovin
            @"didReceiveRewardForPlacement:",
            @"rewardValidationRequestForAd:didSucceedWithResponse:",
            // IronSource
            @"rewardedVideoAdDidReceiveReward:",
            // Mintegral
            @"rewardVideoAdDidReceiveReward:",
            // 通用
            @"onRewardVerify:",
            @"onRewardedVideoAdReward:",
            @"didReward:",
        ];
    });
    return a;
}

static id ck_delegateOf(id adObj) {
    if (!adObj) return nil;
    for (NSString *k in @[@"delegate", @"rewardedVideoAdDelegate",
                          @"adDelegate", @"rewardDelegate", @"listener"]) {
        @try {
            id d = [adObj valueForKey:k];
            if (d && d != adObj) return d;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

BOOL CKInvokeDelegateReward(id adObj) {
    if (!ck_rewardOn()) return NO;          // 开关关掉 → 不补发
    id d = ck_delegateOf(adObj);
    if (!d) return NO;

    for (NSString *name in ck_rewardSelCandidates()) {
        SEL sel = NSSelectorFromString(name);
        if (![d respondsToSelector:sel]) continue;

        NSMethodSignature *sig = [d methodSignatureForSelector:sel];
        if (!sig) continue;
        NSUInteger nargs = [sig numberOfArguments] - 2;
        if (nargs > 3) continue;

        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:d];
            [inv setSelector:sel];

            for (NSUInteger idx = 0; idx < nargs; idx++) {
                const char *t = [sig getArgumentTypeAtIndex:idx + 2];
                if (!t) continue;
                if (t[0] == '@') {
                    id arg = (idx == 0) ? adObj
                             : @{@"reward_name": @"default",
                                 @"reward_amount": @(1),
                                 @"ecpm": @(CKFakeEcpm())};
                    [inv setArgument:&arg atIndex:(NSInteger)(idx + 2)];
                } else if (t[0] == 'c' || t[0] == 'B') {
                    BOOL yes = YES;
                    [inv setArgument:&yes atIndex:(NSInteger)(idx + 2)];
                } else if (strchr("iqIslLQ", t[0])) {
                    NSInteger one = 1;
                    [inv setArgument:&one atIndex:(NSInteger)(idx + 2)];
                }
            }
            [inv invoke];
            CKLog(@"[补发] 投递 %s -%@ 成功", class_getName([d class]), name);
            CKStatsCountRewardFired();     // 浮窗计数
            return YES;
        } @catch (NSException *e) {
            CKLog(@"[补发] %@ 异常: %@", name, e.reason);
        }
    }
    return NO;
}

static void ck_scheduleReward(id adObj, double delaySec) {
    if (!adObj) return;
    if (!ck_rewardOn()) return;             // 开关关掉 → 不排程
    static const void *kKey = &kKey;
    if (objc_getAssociatedObject(adObj, kKey)) return;
    objc_setAssociatedObject(adObj, kKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 冷却：同一时刻太密集的补发容易被服务端判异常，用参数表里的值
    static NSTimeInterval lastFire = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval cool = CKParamGet(CKP_REWARD_COOL);
    if (cool > 0 && (now - lastFire) < cool) {
        CKLog(@"[补发] 冷却中（剩余 %.0fs），跳过", cool - (now - lastFire));
        objc_setAssociatedObject(adObj, kKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    lastFire = now;

    CKLog(@"[补发] 已排程，%.1f 秒后投递", delaySec);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        CKInvokeDelegateReward(adObj);
    });
}

void CKFireRewardForAllSessions(void) {
    CKLog(@"[补发] 手动触发（依赖播放 hook 已抓住 ad 对象）");
}

// 暴露给 HookReward.m 复用
BOOL CKSelectorLooksLikeReward(const char *sel) { return ck_isRewardSel(sel); }
void CKTryScheduleReward(id adObj, double delaySec) { ck_scheduleReward(adObj, delaySec); }

// ============================================================
//  单类安装
// ============================================================
typedef struct { int reward, play, fail, skipped; } CKStat;

static void ck_hookClass(Class cls, const char *clsName, CKStat *st) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    if (!list) return;

    for (unsigned int i = 0; i < n; i++) {
        SEL sel = method_getName(list[i]);
        const char *sn = sel_getName(sel);

        BOOL reward = ck_isRewardSel(sn);
        BOOL play   = ck_isPlaySel(sn);
        BOOL fail   = ck_isFailSel(sn);
        if (!reward && !play && !fail) continue;

        const char *enc = method_getTypeEncoding(list[i]);
        CKShape sh;
        if (!ck_parseShape(enc, &sh) || sh.argc > CK_MAX_ARGS) { st->skipped++; continue; }

        IMP tramp = ck_pickTrampoline(sh);
        if (!tramp) { st->skipped++; continue; }

        IMP orig = method_getImplementation(list[i]);
        if (orig == tramp) continue;

        pthread_mutex_lock(&g_slotLock);
        BOOL dup = NO;
        for (int k = 0; k < g_slotCount; k++) {
            if (g_slots[k].used && g_slots[k].cls == cls && g_slots[k].sel == sel) { dup = YES; break; }
        }
        if (dup || g_slotCount >= CK_MAX_SLOTS) {
            pthread_mutex_unlock(&g_slotLock);
            st->skipped++;
            continue;
        }
        CKSlot *slot = &g_slots[g_slotCount++];
        slot->cls = cls;
        slot->sel = sel;
        slot->orig = orig;
        slot->used = YES;
        pthread_mutex_unlock(&g_slotLock);

        method_setImplementation(list[i], tramp);

        if (reward) st->reward++;
        if (play)   st->play++;
        if (fail)   st->fail++;
        CKLog(@"[引擎] hook %s -%s (%d 参)", clsName, sn, sh.argc);
    }
    free(list);
}

void CKInstallAdEngine(void) {
    CKLog(@"[引擎] 扫描广告类...");
    CKStat st = {0, 0, 0, 0};

    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    int adClasses = 0;
    int genericClasses = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        const char *cn = class_getName(classes[i]);
        if (ck_isAdClass(cn)) {
            adClasses++;
            ck_noteDetected(ck_sdkOfName(cn));
            ck_hookClass(classes[i], cn, &st);
            continue;
        }
        // 认不出厂商时走词根兜底（SDK_GENERIC）
        if (ck_genericAdClass(cn)) {
            genericClasses++;
            ck_hookClass(classes[i], cn, &st);
        }
    }
    free(classes);

    CKLog(@"[引擎] 已知类 %d / 兜底类 %d / 奖励 %d / 播放 %d / 失败 %d / 跳过 %d",
          adClasses, genericClasses, st.reward, st.play, st.fail, st.skipped);
    CKLog(@"[引擎] SDK: %@", [CKDetectedSDKs() componentsJoinedByString:@", "]);

    // 供浮窗展示
    CKStatsSetAdScan(adClasses, genericClasses);
    CKStatsSetHookResult(st.reward, st.play, st.fail, st.skipped);
}

// ============================================================
//  dump
// ============================================================
void CKDumpAdSDKs(void) {
#if VERBOSE_LOG
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;
    int shown = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        const char *cn = class_getName(classes[i]);
        if (!ck_isAdClass(cn)) continue;
        const char *sdk = ck_sdkOfName(cn);
        CKLog(@"[dump] [%s] %s", sdk ? sdk : "?", cn);
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(classes[i], &mn);
        for (unsigned int j = 0; ms && j < mn; j++) {
            const char *sn = sel_getName(method_getName(ms[j]));
            if (ck_isRewardSel(sn) || ck_isPlaySel(sn) || ck_isFailSel(sn)) {
                CKLog(@"[dump]    - %s  enc=%s", sn, method_getTypeEncoding(ms[j]));
            }
        }
        if (ms) free(ms);
        if (++shown >= 300) break;
    }
    free(classes);
    CKLog(@"[dump] 共 %d 个广告类", shown);
#endif
}
