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

// ============================================================
//  解析 ObjC 方法 type encoding
//
//  ★★★ 这里踩过一个致命坑，别再改回去 ★★★
//
//  真实的 encoding 长这样：  v24@0:8@16
//                              ↑ ↑  ↑ ↑ ↑ ↑
//                              | |  | | | └ 参数1 的栈偏移
//                              | |  | | └── 参数1 类型（id）
//                              | |  | └──── _cmd 的偏移
//                              | |  └────── _cmd
//                              | └───────── self 的偏移
//                              └─────────── 整个栈帧的字节数
//
//  也就是说 'v' 后面紧跟的是「帧大小数字」，不是 '@'。
//  旧版本写成 `if (*p != '@') return NO;` → 每个方法都在这里返回 NO
//  → 全部计入「跳过」→ 浮窗显示「hook 奖0 播0 跳3455」，
//  一个 hook 都没装上，只有 fail 计数在涨（fail 判定在解析之前）。
//
//  所以每读一个类型码之后，都要把紧跟的数字（帧大小 / 偏移）跳掉。
// ============================================================
static void ck_skip_digits(const char **pp) {
    while (**pp >= '0' && **pp <= '9') (*pp)++;
}

static BOOL ck_parseShape(const char *enc, CKShape *out) {
    if (!enc || !out) return NO;
    memset(out, 0, sizeof(*out));
    const char *p = enc;
    if (*p != 'v' && *p != 'V') return NO;
    p++;
    ck_skip_digits(&p);              // ★ 帧大小
    if (*p != '@') return NO; p++;
    ck_skip_digits(&p);
    if (*p != ':') return NO; p++;
    ck_skip_digits(&p);

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
            ck_skip_digits(&p);        // ★ 参数偏移
        } else if (t == 'c' || t == 'B') {
            k = CKArgBool; p++;
            ck_skip_digits(&p);
        } else if (strchr("iqIslLQSC", t)) {
            k = CKArgInt; p++;
            ck_skip_digits(&p);
        } else if (t == 'd' || t == 'f' || t == 'D' || t == '*') {
            p++;
            ck_skip_digits(&p);
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
        ck_skip_digits(&p);           // ★ 兜底：每个参数后都可能有偏移数字
        out->kinds[n++] = k;
    }
    out->argc = n;
    return YES;
}

// ============================================================
//  全局 slot 表 —— 双键 (Class, SEL)
// ============================================================
// 槽表里除了原实现，还要记住「这个方法的语义类别」。
// ★ 为什么必须记：trampoline 是按「参数形状」复用的，同一份 ck_h2_ii
//   既可能服务奖励回调、也可能服务播放回调。只有 slot 里存了类别，
//   trampoline 才知道该不该主动补发一次奖励。
typedef enum {
    CKSlotOther     = 0,
    CKSlotReward    = 1,   // 奖励/校验回调：只登记 delegate，绝不补发
    CKSlotPlay      = 2,   // 看完了（playFinish/complete/countdownFinish）：主动补发
    CKSlotFail      = 3,   // 失败回调：不装 hook（见 ck_hookClass）
    CKSlotPlayStart = 4    // 开始展示：只记录，不补发（否则没看完就发奖）
} CKSlotKind;

typedef struct {
    Class      cls;
    SEL        sel;
    IMP        orig;
    CKSlotKind kind;
    BOOL       used;
} CKSlot;

#define CK_MAX_SLOTS 2048
static CKSlot g_slots[CK_MAX_SLOTS];
static int    g_slotCount = 0;
static pthread_mutex_t g_slotLock = PTHREAD_MUTEX_INITIALIZER;

// 从 self 的类开始沿父类链找 (cls, sel)，覆盖继承场景
// 返回 slot 指针（而不是只返回 IMP），这样 trampoline 能同时拿到语义类别
static CKSlot *ck_slotFor(id self, SEL sel) {
    Class c = object_getClass(self);
    pthread_mutex_lock(&g_slotLock);
    for (; c != Nil; c = class_getSuperclass(c)) {
        for (int i = 0; i < g_slotCount; i++) {
            if (g_slots[i].used && g_slots[i].sel == sel && g_slots[i].cls == c) {
                CKSlot *slot = &g_slots[i];
                pthread_mutex_unlock(&g_slotLock);
                return slot;
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

// ★ 统一的后置动作：按 slot 的语义类别决定要不要主动补发一次奖励。
//
//   为什么必须有这一步（这是「看完没奖励」的根因）：
//     原实现的 trampoline 只做一件事 —— 把 BOOL 参数从 NO 改成 YES，
//     然后就转调原实现。这对「服务器已经判定发奖了，只是本地被 NO 卡住」
//     的场景有效；但真实情况是：
//       · 用户根本没看满 15 秒 → 服务器压根没下发发奖指令
//       · onRewardVerify 这种回调根本不会被调用 → hook 永远不会触发
//     所以必须由我们自己「制造」一次奖励回调：抓住播放开始/倒计时结束
//     这些真实会发生的入口，延时向 delegate 投递一次奖励回调。
//
//   语义分工（和 HookReward 的 CKKindPlay 一致）：
//     CKSlotPlay   —— 播放/倒计时入口：真正的掐表点，延时补发
//     CKSlotReward —— 奖励回调本身：只登记 delegate，绝不二次补发
//                     （否则一支广告发两次奖，游戏侧 dismiss 撞车 → 闪退）
// ============================================================
//  改 BOOL 参数前的最后一道闸
//
//  trampoline 会把 BOOL 参数从 NO 改成 YES（「必填校验没过 → 让它过」）。
//  但如果这个 SEL 本身就是失败回调（名字含 fail/error/cancel/...），
//  把它的 BOOL 从 NO 改 YES 会让 SDK 以为「成功了」，随后去取不存在的数据
//  —— 表现就是黑屏、播不动、或者拿不到广告内容。
//
//  典型踩过的坑：rewardedVideoAdDidFailWithError: 同时含 "reward" 和 "fail"，
//  旧版本按 reward 优先判定，把失败标志改成了成功。
//
//  所以这里按 SEL 名再兜一次：只要名字里带失败语义，一个参数都不改。
//  开销：每次广告回调一次 strcasestr 链，广告回调频率极低，可以忽略。
// ============================================================
static BOOL ck_safeToForceBool(SEL sel) {
    if (!sel) return NO;
    const char *n = sel_getName(sel);
    if (!n) return NO;
    static const char *blocked[] = {
        "fail", "error", "cancel", "skip", "close", "interrupt",
        "timeout", "nofill", "no_fill", "abort", "deny", "reject"
    };
    for (size_t i = 0; i < sizeof(blocked)/sizeof(blocked[0]); i++) {
        if (ck_strcasestr(n, blocked[i])) return NO;
    }
    // 复合方法（播完 + 失败）第二个参数是 NSError，改 BOOL 没有意义也不安全
    if (ck_strcasestr(n, "didfailwitherror")) return NO;
    return YES;
}

static void ck_postAction(id self, SEL sel, id arg) {
    if (!ck_rewardOn()) return;
    CKSlot *slot = ck_slotFor(self, sel);
    if (!slot) return;

    // 无论哪个类别，先把 self 上能找到的 delegate 登记掉。
    //   self 是广告对象时能直接拿到奖励 delegate；
    //   self 是播放器/倒计时对象时拿不到（播放器 delegate 是播放器协议），
    //   这时靠之前登记过的全局回落。
    id d = CKDelegateFromAdObject(self);
    if (d) CKRegisterRewardDelegate(d);

    if (slot->kind == CKSlotPlay) {
        // ★ 只有「看完了」才补发。这是唯一合法入口。
        //   用 self 而不是 arg 当目标：self 一定活着且生命周期跟着这次播放；
        //   arg 可能是 nil、error 对象、进度数字包装，挂去重标记会挂错地方。
        //   真正的 delegate 由 CKInvokeDelegateReward 三级回落去找。
        CKLog(@"[引擎] 播完 -%s，排程补发", sel_getName(sel));
        CKTryScheduleReward(self, 1.0);
    }
    // CKSlotReward：登记完 delegate 就够，绝不二次补发（否则双发→领奖闪退）
    // CKSlotPlayStart：只登记 delegate，不补发（否则广告一亮就发奖，没看完也发）
}

static void ck_h0(id self, SEL _cmd) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    ck_postAction(self, _cmd, nil);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
}
static void ck_h1b(id self, SEL _cmd, BOOL a) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    // 单参 BOOL：先把 delegate 登记好（ck_postAction 的 arg 传 nil 避免误当对象）
    if (ck_rewardOn()) {
        id d = CKDelegateFromAdObject(self);
        if (d) CKRegisterRewardDelegate(d);
        if (slot && slot->kind == CKSlotPlay) {
            CKLog(@"[引擎] 播完 -%s，排程补发", sel_getName(_cmd));
            CKTryScheduleReward(self, 1.0);
        }
    }
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, a);
}

static void ck_h1n(id self, SEL _cmd, NSInteger a) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    if (ck_rewardOn()) {
        id d = CKDelegateFromAdObject(self);
        if (d) CKRegisterRewardDelegate(d);
        if (slot && slot->kind == CKSlotPlay) {
            CKLog(@"[引擎] 播完 -%s，排程补发", sel_getName(_cmd));
            CKTryScheduleReward(self, 1.0);
        }
    }
    if (o) ((void (*)(id, SEL, NSInteger))o)(self, _cmd, a);
}

static void ck_h1(id self, SEL _cmd, id a) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a);
}
static void ck_h2_ib(id self, SEL _cmd, id a, BOOL b) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    if (ck_rewardOn() && !b && ck_safeToForceBool(_cmd)) {
        CKLog(@"[引擎] -%s 参数2 NO -> YES", sel_getName(_cmd));
        b = YES;
    }
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, a, b);
}
static void ck_h2_ii(id self, SEL _cmd, id a, id b) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a, b);
}
static void ck_h2_in(id self, SEL _cmd, id a, NSInteger b) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    if (ck_rewardOn() && b == 0 && ck_safeToForceBool(_cmd)) b = 1;
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, NSInteger))o)(self, _cmd, a, b);
}
static void ck_h3_iii(id self, SEL _cmd, id a, id b, id c) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, id, id))o)(self, _cmd, a, b, c);
}
static void ck_h3_ibi(id self, SEL _cmd, id a, BOOL b, id c) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    if (ck_rewardOn() && !b && ck_safeToForceBool(_cmd)) {
        CKLog(@"[引擎] -%s 参数2 NO -> YES", sel_getName(_cmd));
        b = YES;
    }
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, BOOL, id))o)(self, _cmd, a, b, c);
}
static void ck_h3_iib(id self, SEL _cmd, id a, id b, BOOL c) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    if (ck_rewardOn() && !c && ck_safeToForceBool(_cmd)) {
        CKLog(@"[引擎] -%s 参数3 NO -> YES", sel_getName(_cmd));
        c = YES;
    }
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, id, BOOL))o)(self, _cmd, a, b, c);
}
static void ck_h4_iiii(id self, SEL _cmd, id a, id b, id c, id d) {
    CKSlot *slot = ck_slotFor(self, _cmd);
    IMP o = slot ? slot->orig : NULL;
    ck_postAction(self, _cmd, a);
    if (o) ((void (*)(id, SEL, id, id, id, id))o)(self, _cmd, a, b, c, d);
}

// ============================================================
//  按参数形状选 trampoline
//
//  ★ 所有 trampoline 都假定「第一个参数是 id」（广告对象 / delegate / info）。
//    如果第一个参数其实是 BOOL / NSInteger，按 id 传会把 0/1 当成指针
//    → respondsToSelector 立刻野指针 → SIGSEGV。
//    所以 kinds[0] 不是 CKArgID 时直接返回 NULL（跳过这个 hook，不装）。
//
//  ★ 1 参形状还要区分 BOOL / Int，否则 `- (void)onRewardVerify:(BOOL)`
//    这种会被当成 id 传 → 同样崩。
// ============================================================
static IMP ck_pickTrampoline(CKShape sh) {
    // argc == 0 时没有参数，不需要检查
    if (sh.argc > 0 && sh.kinds[0] != CKArgID) return NULL;

    switch (sh.argc) {
        case 0: return (IMP)ck_h0;
        case 1:
            if (sh.kinds[0] == CKArgBool) return (IMP)ck_h1b;
            if (sh.kinds[0] == CKArgInt)  return (IMP)ck_h1n;
            return (IMP)ck_h1;
        case 2:
            if (sh.kinds[1] == CKArgBool) return (IMP)ck_h2_ib;
            if (sh.kinds[1] == CKArgInt)  return (IMP)ck_h2_in;
            if (sh.kinds[1] != CKArgID)   return NULL;   // 结构体/浮点，没实现
            return (IMP)ck_h2_ii;
        case 3:
            if (sh.kinds[1] == CKArgBool) return (IMP)ck_h3_ibi;
            if (sh.kinds[2] == CKArgBool) return (IMP)ck_h3_iib;
            if (sh.kinds[1] != CKArgID || sh.kinds[2] != CKArgID) return NULL;
            return (IMP)ck_h3_iii;
        case 4:
            if (sh.kinds[1] != CKArgID || sh.kinds[2] != CKArgID ||
                sh.kinds[3] != CKArgID) return NULL;
            return (IMP)ck_h4_iiii;
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

// ★★★ 关键词表的三条铁律（踩过坑，别再改回去）★★★
//
//  铁律 1：fail 类必须最先判定，且命中后「一个字都不改」。
//     反例：叫 rewardedVideoAdDidFailWithError: 的方法同时含 "reward"
//     和 "fail"。如果按 reward 处理，我们会把它第二个参数 (BOOL) 从
//     NO 改成 YES，SDK 拿到 YES 以为是「发奖成功」，接着去 doting
//     不存在的数据 → 黑屏 / 崩 / 播不下去。
//     这就是「有的广告播放失败」的直接原因。
//
//  铁律 2："show" / "present" / "render" / "expose" 是「开始展示」，
//     不是「看完」。把它们当补发点，等于广告一亮就开始发奖，
//     用户没看完也发，随后 SDK 自己再发一次 → 双发 → 领奖闪退。
//
//  铁律 3：只有「播完 / 倒计时结束」才算补发点。
//     didfinish / playfinish / complete / playend / countdownfinish /
//     timerfinish —— 这些是真实会发生的、且代表「看完了」的入口。

static BOOL ck_isFailSel(const char *sel) {
    static const char *kw[] = {
        "fail", "error", "nofill", "no_fill", "nosdk", "notfound",
        "didclose", "didclose", "close", "skip", "cancel",
        "interrupt", "timeout"
    };
    return ck_selHasAny(sel, kw, sizeof(kw)/sizeof(kw[0]));
}

// 真正会发奖 / 校验发奖的方法（会被改 BOOL 参数）
static BOOL ck_isRewardSel(const char *sel) {
    if (ck_isFailSel(sel)) return NO;      // 铁律 1：fail 永不参与
    static const char *kw[] = {
        "reward", "verify", "verified", "valid", "effective",
        "earn", "incentive", "convert"
    };
    return ck_selHasAny(sel, kw, sizeof(kw)/sizeof(kw[0]));
}

// 「看完了」——唯一允许主动补发的入口
static BOOL ck_isPlayDoneSel(const char *sel) {
    if (ck_isFailSel(sel)) return NO;      // 铁律 1
    static const char *kw[] = {
        "didfinish", "playfinish", "videofinish", "finishplaying",
        "complete", "playend", "didend", "watchfinish", "didwatch",
        "countdownfinish", "counttimerfinish", "countdownend",
        "timerfinish", "timerend", "rewardvideoend"
    };
    return ck_selHasAny(sel, kw, sizeof(kw)/sizeof(kw[0]));
}

// 「开始展示 / 开始播放」——只记录，不补发（铁律 2）
static BOOL ck_isPlayStartSel(const char *sel) {
    if (ck_isFailSel(sel)) return NO;      // 铁律 1
    static const char *kw[] = {
        "willshow", "didshow", "willpresent", "didpresent",
        "playstart", "didstart", "didplay", "videostart",
        "countdownstart", "render", "expose"
    };
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

// delegate 候选键：覆盖 17 家 SDK 的实际命名（含下划线私有写法）
static NSArray<NSString *> *ck_delegateKeys(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @"delegate", @"_delegate",
            @"rewardedVideoAdDelegate", @"rewardedAdDelegate",
            @"adDelegate", @"adViewDelegate", @"rewardDelegate",
            @"rewardVideoDelegate", @"rewardedDelegate",
            @"listener", @"adListener", @"rewardListener",
            @"callbacks", @"callback", @"handler",
            @"interstitialDelegate", @"videoDelegate",
        ];
    });
    return a;
}

// ★ 全局登记：最近一次被识别出来的「真正能收奖励回调的对象」。
//   为什么需要：HookReward 的 CKKindPlay 规则挂在播放器/倒计时上
//   （BUPlayer、TKSVideoPlayer、GDTAutoCountTimer…），这些对象的 delegate
//   是播放器协议，不是奖励协议 —— 直接拿它们去补发永远找不到方法，
//   表现就是「有的软件看完没有奖励」。
//   所以：奖励类回调命中时把 delegate 记下来，播放器层补发时回落到它。
//   ★ 必须用 __weak 而不是强引用：
//   广告 delegate 常常是某个 ViewController 或它的子对象。
//   这里如果强持有，用户关掉广告页后那个 VC 就永远释放不掉，
//   反复开广告会一路泄漏，最后 OOM 或 UI 卡死。
//   weak 在对象释放后自动变 nil，ck_lastRewardDelegate 返回 nil 时
//   调用方会走「找不到 delegate，本次跳过」的安全分支。
static __weak id g_lastRewardDelegate = nil;
static pthread_mutex_t g_delegateLock = PTHREAD_MUTEX_INITIALIZER;

void CKRegisterRewardDelegate(id delegate) {
    if (!delegate) return;
    pthread_mutex_lock(&g_delegateLock);
    g_lastRewardDelegate = delegate;            // __weak：不持有，释放后自动 nil
    pthread_mutex_unlock(&g_delegateLock);
}

static id ck_lastRewardDelegate(void) {
    pthread_mutex_lock(&g_delegateLock);
    id d = g_lastRewardDelegate;
    pthread_mutex_unlock(&g_delegateLock);
    return d;
}

static id ck_delegateOf(id adObj) {
    if (!adObj) return nil;

    // 1) KVC 直取（最常用）
    for (NSString *k in ck_delegateKeys()) {
        @try {
            id d = [adObj valueForKey:k];
            // delegate 必须实现至少一个奖励类回调才算数，否则是别的用途的 field
            if (d && d != adObj && [d respondsToSelector:@selector(respondsToSelector:)]) {
                for (NSString *name in ck_rewardSelCandidates()) {
                    if ([d respondsToSelector:NSSelectorFromString(name)]) return d;
                }
            }
        } @catch (__unused NSException *e) {}
    }

    // 2) 兜底：遍历实例变量找「实现了奖励回调的对象」
    //    有些 SDK 把 delegate 存在 ivar 里且不响应 KVC（比如 C++ 桥接层）
    //
    //    ★ 安全约束：只碰「ivar 名含 delegate/listener/callback/handler/
    //      target/observer」的字段。
    //      原因：object_getIvar 对 assign / unsafe_unretained 的 @ 类型
    //      ivar 会原样返回裸指针 —— 那个对象可能早就释放了，
    //      后面一句 respondsToSelector 就是野指针调用 → 直接 SIGSEGV。
    //      名字过滤把风险压到最低：这些字段按 SDK 惯例都是 strong/weak，
    //      runtime 会帮我们维护正确性。
    static const char *kIvarHints[] = {
        "delegate", "listener", "callback", "handler", "target", "observer"
    };
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(adObj), &n);
    if (ivars) {
        for (unsigned int i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (!t || t[0] != '@') continue;

            const char *iname = ivar_getName(ivars[i]);
            if (!iname) continue;
            BOOL nameHit = NO;
            for (size_t k = 0; k < sizeof(kIvarHints)/sizeof(kIvarHints[0]); k++) {
                if (ck_strcasestr(iname, kIvarHints[k])) { nameHit = YES; break; }
            }
            if (!nameHit) continue;

            @try {
                id v = object_getIvar(adObj, ivars[i]);
                if (!v || v == adObj) continue;
                for (NSString *name in ck_rewardSelCandidates()) {
                    if ([v respondsToSelector:NSSelectorFromString(name)]) {
                        free(ivars);
                        return v;
                    }
                }
            } @catch (__unused NSException *e) {}
        }
        free(ivars);
    }

    // 3) 最后兜底：adObj 自己就是 delegate（有的 SDK 让广告对象直接实现协议）
    for (NSString *name in ck_rewardSelCandidates()) {
        if ([adObj respondsToSelector:NSSelectorFromString(name)]) return adObj;
    }
    return nil;
}

// 把 adObj 的 delegate 解析出来并登记（供播放器层回落使用）
static id ck_delegateOfAndRemember(id adObj) {
    id d = ck_delegateOf(adObj);
    if (d) CKRegisterRewardDelegate(d);
    return d;
}

// 对外：给 HookReward 的奖励类回调用来「只登记不补发」
id CKDelegateFromAdObject(id adObj) { return ck_delegateOf(adObj); }

BOOL CKInvokeDelegateReward(id adObj) {
    if (!ck_rewardOn()) return NO;          // 开关关掉 → 不补发

    // ★ 三级回落：
    //   ① adObj 自己的 delegate（正常情况）
    //   ② 全局登记的「最近奖励 delegate」—— 播放器/倒计时触发的补发靠这条，
    //      因为播放器对象的 delegate 是播放器协议，不含奖励方法
    //   ③ adObj 自己就是 delegate
    //   原实现只有 ①，所以从播放器层（CKKindPlay）补发几乎全部失效。
    id d = ck_delegateOf(adObj);
    if (!d) d = ck_lastRewardDelegate();
    if (!d) {
        for (NSString *name in ck_rewardSelCandidates()) {
            if ([adObj respondsToSelector:NSSelectorFromString(name)]) { d = adObj; break; }
        }
    }
    if (!d) {
        CKLog(@"[补发] 找不到 delegate（adObj=%s），本次跳过",
              adObj ? class_getName(object_getClass(adObj)) : "nil");
        return NO;
    }
    CKRegisterRewardDelegate(d);            // 记住，下次播放器层触发可直接用

    for (NSString *name in ck_rewardSelCandidates()) {
        SEL sel = NSSelectorFromString(name);
        if (![d respondsToSelector:sel]) continue;

        NSMethodSignature *sig = [d methodSignatureForSelector:sel];
        if (!sig) continue;
        NSUInteger nargs = [sig numberOfArguments] - 2;
        if (nargs > 4) continue;

        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:d];
            [inv setSelector:sel];

            for (NSUInteger idx = 0; idx < nargs; idx++) {
                const char *t = [sig getArgumentTypeAtIndex:idx + 2];
                if (!t) continue;
                if (t[0] == '@') {
                    // ★ 第 0 个 @ 参数给 adObj（绝大多数 SDK 是 (ad, ...)），
                    //   后面的给 info 字典。字典里把常见键名全填上，
                    //   因为不同 SDK 取 @[@"amount"] / @[@"reward_amount"] /
                    //   @[@"rewardCount"] 各不相同，键缺失会当成 0 奖励。
                    id arg;
                    if (idx == 0) {
                        arg = adObj;
                    } else {
                        arg = @{
                            @"reward_name":   @"default",
                            @"name":          @"default",
                            @"reward_amount": @(1),
                            @"amount":        @(1),
                            @"rewardCount":   @(1),
                            @"count":         @(1),
                            @"quantity":      @(1),
                            @"ecpm":          @(CKFakeEcpm()),
                            @"revenue":       @(CKFakeEcpm()),
                            @"isValid":       @(YES),
                            @"valid":         @(YES),
                            @"verified":      @(YES),
                        };
                    }
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
            CKStatsSetRewardReason([NSString stringWithFormat:@"成功 %@", name]);
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

    // ★ 去重按「这一次播放」算，不是按对象算。
    //   原实现用 associated object 永久占位：同一个 ad 对象被复用第二次
    //   （SDK 常见做法：广告位只 new 一次，反复 show）就再也补发不出来，
    //   表现就是「有的软件看完没有奖励」。
    //   现在改成存「上次触发时间」，超过冷却时间就允许再来一次。
    static const void *kKey = &kKey;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSNumber *last = objc_getAssociatedObject(adObj, kKey);
    NSTimeInterval cool = CKParamGet(CKP_REWARD_COOL);

    // ★ 冷却改成「每个 ad 对象各自计时」，不再是全进程一个静态变量。
    //   原来一个 App 里发过奖，45 秒内切到另一个 App 的广告都会被吞掉。
    if (last && cool > 0 && (now - last.doubleValue) < cool) {
        CKLog(@"[补发] 本广告对象冷却中（剩余 %.0fs），跳过", cool - (now - last.doubleValue));
        return;
    }
    objc_setAssociatedObject(adObj, kKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CKStatsCountSchedule();
    CKLog(@"[补发] 已排程，%.1f 秒后投递", delaySec);

    // ★ 投递必须在主线程。
    //   原实现用的是 dispatch_get_global_queue —— 这是「领奖闪退」的头号原因：
    //     1. 广告 SDK 的 delegate 回调按合同都必须在主线程调用，
    //        游戏侧收到回调后会去刷 UI / 改 UIKit 状态，
    //        在后台线程碰 UIKit 直接触发 main thread checker 或野内存访问；
    //     2. 有的 SDK 在回调里 dismiss 全屏广告控制器，
    //        dismiss 一个非主线程持有的 VC → 崩溃；
    //     3. NSInvocation 里的参数是 block / weak 引用时，
    //        后台线程拿到的对象可能已被释放。
    //   统一回主线程后，行为和 SDK 自己正常发奖时完全一致。
    // ★ 找不到 delegate 时重试两次。
    //   场景：播放入口比「广告对象创建 delegate」更早触发，
    //   第一次投递必然失败。给 SDK 2~4 秒把对象建起来再试，
    //   否则这一支广告的奖励就彻底丢了（表现为「看完没奖励」）。
    static const double kRetryDelay[2] = {2.0, 4.0};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            CKStatsCountAttempt();
            if (CKInvokeDelegateReward(adObj)) return;
            CKStatsSetRewardReason(@"找不到 delegate");
            CKLog(@"[补发] 第 1 次未找到 delegate，%.0fs 后重试", kRetryDelay[0]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kRetryDelay[0] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    CKStatsCountAttempt();
                    if (CKInvokeDelegateReward(adObj)) return;
                    CKLog(@"[补发] 第 2 次仍未找到，%.0fs 后最后一次", kRetryDelay[1]);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(kRetryDelay[1] * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @autoreleasepool {
                            CKStatsCountAttempt();
                            if (!CKInvokeDelegateReward(adObj)) {
                                CKStatsSetRewardReason(@"三次均失败");
                                CKLog(@"[补发] 三次均失败，放弃这一支（delegate 未就绪）");
                            }
                        }
                    });
                }
            });
        }
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

        // ★ 四分类，顺序不能变（fail 最先，且命中即跳过）
        BOOL fail      = ck_isFailSel(sn);
        BOOL playDone  = ck_isPlayDoneSel(sn);
        BOOL reward    = ck_isRewardSel(sn);
        BOOL playStart = ck_isPlayStartSel(sn);
        if (!fail && !playDone && !reward && !playStart) continue;

        // 失败回调：只统计，一个参数都不改，也不装 hook。
        //   ★ 这是「有的广告播放失败」的修复点：
        //     rewardedVideoAdDidFailWithError: 以前被当 reward 处理，
        //     把 BOOL 从 NO 改成 YES，SDK 以为发奖成功去取数据 → 黑屏/播不动。
        if (fail && !playDone && !reward && !playStart) {
            st->fail++;
            continue;
        }

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
        // ★ 类别优先级：播完 > 奖励 > 开始展示。
        //   「播完」是最可靠的补发点，哪怕方法名里也带 reward 字样
        //   （rewardedVideoAdDidPlayFinish: 就是这种情况），
        //   它的真实语义仍然是「播放结束」，必须判成 CKSlotPlay。
        if (playDone)        slot->kind = CKSlotPlay;
        else if (reward)     slot->kind = CKSlotReward;
        else if (playStart)  slot->kind = CKSlotPlayStart;
        else                 slot->kind = CKSlotOther;
        slot->used = YES;
        pthread_mutex_unlock(&g_slotLock);

        method_setImplementation(list[i], tramp);

        if (playDone)  st->play++;
        if (reward)    st->reward++;
        if (playStart) st->play++;   // 展示类计入播放统计，浮窗上看得出装了多少
        CKLog(@"[引擎] hook %s -%s (%d 参, %s)", clsName, sn, sh.argc,
              playDone ? "播完→补发" : (reward ? "奖励→只登记" : "展示→不补发"));
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
            if (ck_isRewardSel(sn) || ck_isPlayDoneSel(sn) ||
                ck_isPlayStartSel(sn) || ck_isFailSel(sn)) {
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
