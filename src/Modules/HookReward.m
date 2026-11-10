//
//  Modules/HookReward.m
//  精确激励回调 hook —— 已知 SDK 的确定性入口（AdEngine 关键词扫描之外的双保险）
//
//  分工：
//    AdEngine   —— 靠类名指纹 + 方法形状，自动接管未知/混淆 SDK，主动补发奖励
//    HookReward —— 靠写死的真实 SEL 表，精确接管已知 SDK 的官方回调
//
//  强度：AdEngine 负责"猜得到的都接管"，HookReward 负责"写死的必然命中"。
//

#import "HookReward.h"
#import "AdEngine.h"
#import "../Common/Log.h"
#import "../Common/HookUtil.h"
#import "../Common/Stats.h"
#import "../Common/FeatureFlags.h"   // 运行时开关
#import "../Config.h"
#import <objc/runtime.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import "../vendor/ck_compat.h" // strcasestr / strncasecmp 自带实现

// ============================================================
//  精确 hook 表：每个 SEL 标明意图
//    CKKindReward —— 参数里的 BOOL（verify/valid）强制 YES
//    CKKindPlay   —— 广告开始播，排程补发奖励
// ============================================================
typedef enum { CKKindReward = 1, CKKindPlay = 2 } CKKind;

typedef struct {
    const char *clsName;   // 目标类；NULL 表示全局按 SEL 扫
    const char *selName;
    CKKind      kind;
} CKExactRule;

static const CKExactRule kExactRules[] = {
    // ---------- 穿山甲 / Pangle ----------
    { "BURewardedVideoAd",        "rewardedVideoAdServerRewardDidSucceed:verify:", CKKindReward },
    { "BURewardedVideoAd",        "rewardedVideoAdDidRewardEffective:",            CKKindReward },
    { "BURewardedVideoAd",        "rewardedVideoAdDidPlayFinish:didFailWithError:", CKKindPlay },
    { "BURewardedVideoAdManager", "rewardedVideoAdServerRewardDidSucceed:verify:", CKKindReward },
    { "BURewardedVideoAdManager", "rewardedVideoAdDidPlayFinish:didFailWithError:", CKKindPlay },
    { "BUAdRewardedVideoManager", "rewardedVideoAdServerRewardDidSucceed:verify:", CKKindReward },
    { "PAGRewardedAd",            "adDidReward:",                                  CKKindReward },
    { "PAGRewardedAd",            "ad:didReward:",                                 CKKindReward },

    // ---------- 优量汇 / GDT ----------
    { "GDTRewardVideoAd",         "gdt_rewardVideoAdDidRewardEffective:info:",     CKKindReward },
    { "GDTRewardVideoAd",         "gdt_rewardVideoAdDidPlayFinish:",               CKKindPlay },
    { "GDTRewardedVideoAd",       "gdt_rewardVideoAdDidRewardEffective:info:",     CKKindReward },
    { "GDTRewardedVideoAd",       "gdt_rewardVideoAdDidPlayFinish:",               CKKindPlay },

    // ---------- 快手联盟 ----------
    { "KSRewardedVideoAd",        "rewardVideoAdDidRewardEffective:info:",         CKKindReward },
    { "KSRewardedVideoAd",        "rewardVideoAdDidComplete:",                     CKKindPlay },
    { "KSAdRewardVideoAd",        "rewardVideoAdDidRewardEffective:info:",         CKKindReward },

    // ---------- 百度联盟 ----------
    { "BaiduMobAdRewardVideo",    "rewardedAdDidSuccessful:",                      CKKindReward },
    { "BaiduMobAdRewardVideo",    "rewardedAdDidReward:",                          CKKindReward },
    { "BaiduMobAdRewardVideo",    "rewardedAdDidClose:",                           CKKindPlay },

    // ---------- Google AdMob ----------
    { "GADRewardedAd",            "rewardedAd:userDidEarnReward:",                 CKKindReward },
    { "GADRewardedInterstitialAd","rewardedInterstitialAd:userDidEarnReward:",     CKKindReward },

    // ---------- AppLovin / MAX ----------
    { "ALAdReward",               "didReceiveRewardForPlacement:",                 CKKindReward },
    { "MARewardedAd",             "didReceiveRewardForPlacement:",                 CKKindReward },

    // ---------- IronSource / LevelPlay ----------
    { "ISRewardedVideoAd",        "rewardedVideoDidReceiveReward:",                CKKindReward },
    { "LPMRewardedAd",            "didReceiveRewardForAd:",                        CKKindReward },

    // ---------- Mintegral ----------
    { "MTGRewardVideoAd",         "rewardVideoAdDidReceiveReward:",                CKKindReward },
    { "MTRewardedVideoAd",        "rewardVideoAdDidReceiveReward:",                CKKindReward },

    // ---------- UnityAds ----------
    { "UADSRewardedAd",           "rewardedAdDidComplete:",                        CKKindReward },

    // ---------- Vungle / Liftoff ----------
    { "VNGRewardedAd",            "rewardedAdDidReward:",                          CKKindReward },

    // ---------- Sigmob ----------
    { "SMRewardedVideoAd",        "sigmob_rewardVideoAdDidRewardEffective:info:",  CKKindReward },

    // ---------- Chartboost ----------
    { "CHBRewarded",              "didCompleteRewardedVideo:withReward:",          CKKindReward },

    // ---------- TopOn / AnyThink ----------
    { "ATRewardedVideoAd",        "rewardedVideoDidRewardSuccessForPlacements:withExtra:", CKKindReward },
    { "ATRewardedVideoAd",        "rewardedVideoDidStartPlayingForPlacements:extra:",      CKKindPlay },

    // ---------- TradPlus ----------
    { "TradPlusRewardedVideoAd",  "tpRewardedVideoDidReward:reward:",              CKKindReward },

    // ---------- GroMore ----------
    { "GMRewardedVideoAd",        "rewardedVideoAdDidRewardEffective:info:",       CKKindReward },

    // ============================================================
    //  ★ 播放器 / 倒计时层（从 AdAccel 样本逆向出来的真实类名）
    //
    //  为什么必须有这一段：
    //    奖励类只是「收尾发通知」，真正掐表判断「看够 15 秒了」的是
    //    播放器和倒计时对象。只 hook 奖励类的话，用户在 App 内正常看完
    //    广告当然会发奖；但要想「不看完也发奖」，必须接管播放器这条链。
    // ============================================================

    // ---------- 字节系播放器 ----------
    { "BUPlayer",                 "playerDidFinishPlaying:",                       CKKindPlay },
    { "BU_ZFPlayer",              "playerDidFinishPlaying:",                       CKKindPlay },
    { "BU_ZFPlayerView",          "playerDidFinishPlaying:",                       CKKindPlay },
    { "BUVideoEngine",            "videoEngineDidFinish:",                         CKKindPlay },
    { "TTAVPlayer",               "playerDidFinishPlaying:",                       CKKindPlay },
    { "TTPlayer",                 "playerDidFinishPlaying:",                       CKKindPlay },
    { "TVLPlayer",                "playerDidFinishPlaying:",                       CKKindPlay },
    { "TVLPlayerInternal",        "playerDidFinishPlaying:",                       CKKindPlay },

    // ---------- 优量汇 / 快手 公共播放组件 ----------
    { "TKVideoPlayer",            "playerDidFinishPlaying:",                       CKKindPlay },
    { "TKVideoPlayer",            "videoPlayerDidFinishPlaying:",                   CKKindPlay },
    { "TKTimer",                  "timerDidFinish:",                               CKKindPlay },
    { "KSVideoAd",                "videoAdDidPlayFinish:",                         CKKindPlay },
    { "KSVideoAd",                "videoAdDidComplete:",                           CKKindPlay },

    // ---------- 倒计时（掐表的核心） ----------
    { "GDTAutoCountTimer",        "countTimerDidFinish:",                          CKKindPlay },
    { "GDTAutoCountTimer",        "countDownFinished:",                            CKKindPlay },
    { "KSAdCountdown",            "countdownDidFinish:",                           CKKindPlay },
    { "BaiduMobAdCountdown",      "countdownDidFinish:",                           CKKindPlay },
    { "WindCountdown",            "countdownDidFinish:",                           CKKindPlay },

    // ---------- H5 / 可玩广告（Web 层计时） ----------
    { "KSAdWebReward",            "webViewDidFinishLoad:",                         CKKindPlay },
    { "GDTRewardVideoAd",         "gdt_rewardVideoAdDidPlayFinish:",               CKKindPlay },
};
static const size_t kRuleCount = sizeof(kExactRules) / sizeof(kExactRules[0]);

// ============================================================
//  slot 表：按 (Class, SEL) 存原实现，避免串号
// ============================================================
typedef struct {
    Class  cls;
    SEL    sel;
    IMP    orig;
    CKKind kind;
    BOOL   used;
} CKExactSlot;

#define CK_MAX_EXACT 512
static CKExactSlot g_exact[CK_MAX_EXACT];
static int g_exactCount = 0;
static pthread_mutex_t g_exactLock = PTHREAD_MUTEX_INITIALIZER;

static CKExactSlot *ck_findExact(id self, SEL sel) {
    Class c = object_getClass(self);
    pthread_mutex_lock(&g_exactLock);
    for (; c != Nil; c = class_getSuperclass(c)) {
        for (int i = 0; i < g_exactCount; i++) {
            if (g_exact[i].used && g_exact[i].sel == sel && g_exact[i].cls == c) {
                pthread_mutex_unlock(&g_exactLock);
                return &g_exact[i];
            }
        }
    }
    pthread_mutex_unlock(&g_exactLock);
    return NULL;
}

// ============================================================
//  trampoline：只覆盖 0 / 1 / 2 参三种形状
//
//  ★ 运行时开关在此判定：CKFeatureRewardForce 关掉时
//    既不改 BOOL 参数、也不排程补发，纯透传原实现，
//    等价于没装 hook，浮窗里一关立刻生效。
// ============================================================
static inline BOOL ck_rewardForceOn(void) { return CKFeatureGet(CKFeatureRewardForce); }

static void ck_ex_0(id self, SEL _cmd) {
    CKExactSlot *s = ck_findExact(self, _cmd);
    if (!s) return;
    if (s->kind == CKKindPlay && ck_rewardForceOn()) CKTryScheduleReward(self, 1.0);
    ((void (*)(id, SEL))s->orig)(self, _cmd);
}

static void ck_ex_1(id self, SEL _cmd, id a) {
    CKExactSlot *s = ck_findExact(self, _cmd);
    if (!s) return;
    if (s->kind == CKKindPlay && ck_rewardForceOn()) CKTryScheduleReward(self, 1.0);
    ((void (*)(id, SEL, id))s->orig)(self, _cmd, a);
}

static void ck_ex_1b(id self, SEL _cmd, BOOL b) {
    CKExactSlot *s = ck_findExact(self, _cmd);
    if (!s) return;
    if (ck_rewardForceOn() && !b) {
        CKLog(@"[精确] -%s verify NO -> YES", sel_getName(_cmd));
        b = YES;
    }
    ((void (*)(id, SEL, BOOL))s->orig)(self, _cmd, b);
}

static void ck_ex_2(id self, SEL _cmd, id a, id b) {
    CKExactSlot *s = ck_findExact(self, _cmd);
    if (!s) return;
    if (s->kind == CKKindReward && ck_rewardForceOn()) {
        // ★ 这里刻意「只登记、不补发」。
        //   原实现在奖励回调里又调 CKTryScheduleReward 投递一次，
        //   而紧接着的 orig(...) 会让 SDK 自己再发一次 —— 同一支广告发两次奖。
        //   游戏侧收到第二次回调时，奖励弹窗/全屏广告正在 dismiss，
        //   就会出现「领奖闪退」（典型是 present/dismiss 撞车或 UI 被释放后再刷）。
        //   这里只把 delegate 记下来，供播放器层补发时回落使用。
        CKLog(@"[精确] 奖励回调 -%s（原生已发奖，不再补投）", sel_getName(_cmd));
        id d = CKDelegateFromAdObject(self);
        if (d) CKRegisterRewardDelegate(d);
    }
    ((void (*)(id, SEL, id, id))s->orig)(self, _cmd, a, b);
}

static void ck_ex_2b(id self, SEL _cmd, id a, BOOL b) {
    CKExactSlot *s = ck_findExact(self, _cmd);
    if (!s) return;
    if (ck_rewardForceOn()) {
        if (!b) { CKLog(@"[精确] -%s verify NO -> YES", sel_getName(_cmd)); b = YES; }
        if (s->kind == CKKindReward) {
            // ★ 同上：只登记 delegate，不二次补发（否则一支广告发两次奖）
            id d = CKDelegateFromAdObject(self);
            if (d) CKRegisterRewardDelegate(d);
        }
    }
    ((void (*)(id, SEL, id, BOOL))s->orig)(self, _cmd, a, b);
}

static void ck_ex_2ib(id self, SEL _cmd, NSInteger a, BOOL b) {
    CKExactSlot *s = ck_findExact(self, _cmd);
    if (!s) return;
    if (ck_rewardForceOn()) b = YES;
    ((void (*)(id, SEL, NSInteger, BOOL))s->orig)(self, _cmd, a, b);
}

static IMP ck_exactTrampoline(const char *enc) {
    if (!enc || enc[0] != 'v') return NULL;
    const char *p = enc + 1;
    if (*p != '@') return NULL; p++;
    if (*p != ':') return NULL; p++;

    // 统计参数类型（跳修饰符）
    char types[4] = {0};
    int n = 0;
    while (*p && n < 4) {
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' ||
               *p == 'O' || *p == 'R' || *p == 'V' || *p == 'A') p++;
        if (!*p) break;
        if (*p == '@') { types[n++] = '@'; p++; }
        else if (*p == 'c' || *p == 'B') { types[n++] = 'B'; p++; }
        else if (strchr("iqIslLQSC", *p)) { types[n++] = 'I'; p++; }
        else if (*p == '{' || *p == '[') {
            char open = *p, close = (*p == '{') ? '}' : ']';
            int d = 0;
            while (*p) {
                if (*p == open) d++;
                else if (*p == close) { d--; if (!d) { p++; break; } }
                p++;
            }
            types[n++] = '?';
        } else { types[n++] = '?'; p++; }
    }

    if (n == 0) return (IMP)ck_ex_0;
    if (n == 1 && types[0] == '@') return (IMP)ck_ex_1;
    if (n == 1 && types[0] == 'B') return (IMP)ck_ex_1b;
    if (n == 2 && types[0] == '@' && types[1] == '@') return (IMP)ck_ex_2;
    if (n == 2 && types[0] == '@' && types[1] == 'B') return (IMP)ck_ex_2b;
    if (n == 2 && types[0] == 'I' && types[1] == 'B') return (IMP)ck_ex_2ib;
    return NULL;
}

// ============================================================
//  安装单条规则
// ============================================================
static void ck_applyRule(const CKExactRule *r) {
    SEL sel = NSSelectorFromString(@(r->selName));

    if (r->clsName) {
        // 指定类
        Class cls = objc_getClass(r->clsName);
        if (!cls) return;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;

        const char *enc = method_getTypeEncoding(m);
        IMP tramp = ck_exactTrampoline(enc);
        if (!tramp) { CKLog(@"[精确] 形状不支持，跳过 %s -%s", r->clsName, r->selName); return; }

        IMP cur = method_getImplementation(m);
        if (cur == tramp) return;

        pthread_mutex_lock(&g_exactLock);
        for (int i = 0; i < g_exactCount; i++) {
            if (g_exact[i].used && g_exact[i].cls == cls && g_exact[i].sel == sel) {
                pthread_mutex_unlock(&g_exactLock);
                return;
            }
        }
        if (g_exactCount >= CK_MAX_EXACT) { pthread_mutex_unlock(&g_exactLock); return; }
        CKExactSlot *s = &g_exact[g_exactCount++];
        s->cls = cls; s->sel = sel; s->orig = cur; s->kind = r->kind; s->used = YES;
        pthread_mutex_unlock(&g_exactLock);

        method_setImplementation(m, tramp);
        CKLog(@"[精确] hook %s -%s", r->clsName, r->selName);
        return;
    }

    // 全局按 SEL 扫（类名不固定的 delegate）
    unsigned int cn = 0;
    Class *classes = objc_copyClassList(&cn);
    if (!classes) return;
    int hooked = 0;
    for (unsigned int i = 0; i < cn; i++) {
        Method m = class_getInstanceMethod(classes[i], sel);
        if (!m) continue;
        const char *enc = method_getTypeEncoding(m);
        IMP tramp = ck_exactTrampoline(enc);
        if (!tramp) continue;
        IMP cur = method_getImplementation(m);
        if (cur == tramp) continue;

        pthread_mutex_lock(&g_exactLock);
        BOOL dup = NO;
        for (int k = 0; k < g_exactCount; k++) {
            if (g_exact[k].used && g_exact[k].cls == classes[i] && g_exact[k].sel == sel) { dup = YES; break; }
        }
        if (dup || g_exactCount >= CK_MAX_EXACT) {
            pthread_mutex_unlock(&g_exactLock);
            continue;
        }
        CKExactSlot *s = &g_exact[g_exactCount++];
        s->cls = classes[i]; s->sel = sel; s->orig = cur; s->kind = r->kind; s->used = YES;
        pthread_mutex_unlock(&g_exactLock);

        method_setImplementation(m, tramp);
        hooked++;
    }
    free(classes);
    if (hooked) CKLog(@"[精确] 全局扫 %s: %d 个类", r->selName, hooked);
}

// ============================================================
//  dump：所有含 reward/verify/ecpm 的方法
// ============================================================
void CKDumpRewardClasses(void) {
#if VERBOSE_LOG
    int found = 0;
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;

    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *clsName = class_getName(cls);
        if (!clsName) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (!methods) continue;

        BOOL hit = NO;
        for (unsigned int j = 0; j < methodCount; j++) {
            const char *msel = sel_getName(method_getName(methods[j]));
            if (!msel) continue;
            if (ck_strcasestr(msel, "reward") || ck_strcasestr(msel, "ecpm") ||
                ck_strcasestr(msel, "verify") || ck_strcasestr(msel, "effective")) {
                if (!hit) { CKLog(@"[dump] 类 %s", clsName); hit = YES; found++; }
                CKLog(@"[dump]    - %s  enc=%s", msel, method_getTypeEncoding(methods[j]));
            }
        }
        free(methods);
    }
    free(classes);
    CKLog(@"[dump] 共命中 %d 个类", found);
#endif
}

// ============================================================
//  单个 SDK 入口（保留旧接口，内部统一走规则表）
// ============================================================
static void ck_applyByPrefix(const char *prefix) {
    for (size_t i = 0; i < kRuleCount; i++) {
        if (kExactRules[i].clsName &&
            ck_strncasecmp_eq(kExactRules[i].clsName, prefix, strlen(prefix))) {
            ck_applyRule(&kExactRules[i]);
        }
    }
    // 同名 SEL 的全局兜底
    for (size_t i = 0; i < kRuleCount; i++) {
        if (kExactRules[i].clsName &&
            ck_strncasecmp_eq(kExactRules[i].clsName, prefix, strlen(prefix))) {
            CKExactRule g = { NULL, kExactRules[i].selName, kExactRules[i].kind };
            ck_applyRule(&g);
        }
    }
}

void CKInstallPangleReward(void)   { ck_applyByPrefix("BU"); ck_applyByPrefix("PAG"); }
void CKInstallGDTReward(void)      { ck_applyByPrefix("GDT"); }
void CKInstallAdMobReward(void)    { ck_applyByPrefix("GAD"); }
void CKInstallAppLovinReward(void) { ck_applyByPrefix("AL"); ck_applyByPrefix("MA"); }
void CKInstallIronSourceReward(void){ ck_applyByPrefix("IS"); ck_applyByPrefix("LPM"); }

// ============================================================
//  统一入口
// ============================================================
void CKInstallRewardHooks(void) {
#if ENABLE_REWARD_FORCE
    int ok = 0;
    for (size_t i = 0; i < kRuleCount; i++) {
        if (kExactRules[i].clsName && !objc_getClass(kExactRules[i].clsName)) continue;
        ck_applyRule(&kExactRules[i]);
        ok++;
    }
    CKLog(@"[精确] 规则 %zu 条，可用 %d 条，已装 slot %d 个", kRuleCount, ok, g_exactCount);
    CKStatsSetExactSlots(g_exactCount);   // 浮窗展示

#if ENABLE_SDK_SCAN
    CKDumpRewardClasses();
#endif
    CKLog(@"激励回调 hook 安装完成");
#endif
}
