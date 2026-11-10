//
//  Common/FeatureFlags.m
//
//  ★ 性能要求（很重要）：
//    这些 getter 会出现在极热路径上 —— stat()/open()/dlsym() 里查开关，
//    NSJSONSerialization 每序列化一次都要查 eCPM 倍率。
//    [NSUserDefaults boolForKey:] 每次都要走 plist 缓存+字典查找，几十纳秒到微秒级，
//    放在 stat() 里就是灾难。
//
//    所以：**内存缓存 + 位图**。首次访问时灌一次，之后就是一次位运算/一次数组读。
//    CKFeatureSet / CKParamSet 时同步更新缓存，所以浮窗里改动立刻反映。
//

#import "FeatureFlags.h"
#import "Log.h"
#import <pthread.h>
#import <stdint.h>
#import <string.h>

static NSString *ck_key(const char *k) {
    return [NSString stringWithFormat:@"ck.%s", k];
}

// ============================================================
//  功能开关：位图缓存
// ============================================================
static BOOL ck_factoryDefault(CKFeature f) {
    switch (f) {
        case CKFeatureRewardForce:    return ENABLE_REWARD_FORCE ? YES : NO;
        case CKFeatureEcpmTamper:     return ENABLE_ECPM_INFLATE ? YES : NO;
        case CKFeatureFingerprint:    return ENABLE_FINGERPRINT ? YES : NO;
        case CKFeatureOverlay:        return ENABLE_OVERLAY ? YES : NO;
        case CKFeatureAntiJailbreak:  return ENABLE_ANTI_JAILBREAK ? YES : NO;
        case CKFeatureAntiDebug:      return ENABLE_ANTI_DEBUG ? YES : NO;
        case CKFeatureDyldHide:       return ENABLE_DYLD_HIDE ? YES : NO;
        case CKFeatureNetTamper:      return ENABLE_NET_TAMPER ? YES : NO;
        default: return NO;
    }
}

static const char *ck_featureKey(CKFeature f) {
    switch (f) {
        case CKFeatureRewardForce:   return "feat.reward";
        case CKFeatureEcpmTamper:    return "feat.ecpm";
        case CKFeatureFingerprint:   return "feat.fingerprint";
        case CKFeatureOverlay:       return "feat.overlay";
        case CKFeatureAntiJailbreak: return "feat.antijb";
        case CKFeatureAntiDebug:     return "feat.antidbg";
        case CKFeatureDyldHide:      return "feat.dyldhide";
        case CKFeatureNetTamper:     return "feat.nettamper";
        default: return "feat.unknown";
    }
}

static uint32_t       g_featMask = 0;
static BOOL           g_featLoaded = NO;
static pthread_mutex_t g_featLock = PTHREAD_MUTEX_INITIALIZER;

static void ck_featLoad(void) {
    pthread_mutex_lock(&g_featLock);
    if (!g_featLoaded) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        uint32_t mask = 0;
        for (int i = 0; i < CKFeatureCount; i++) {
            NSString *k = ck_key(ck_featureKey((CKFeature)i));
            BOOL on = ([d objectForKey:k] == nil)
                      ? ck_factoryDefault((CKFeature)i)
                      : [d boolForKey:k];
            if (on) mask |= (1u << i);
        }
        g_featMask = mask;
        g_featLoaded = YES;
    }
    pthread_mutex_unlock(&g_featLock);
}

BOOL CKFeatureGet(CKFeature f) {
    if (f < 0 || f >= CKFeatureCount) return NO;
    if (!g_featLoaded) ck_featLoad();
    return (g_featMask >> f) & 1u;      // 热路径：一次位运算
}

void CKFeatureSet(CKFeature f, BOOL on) {
    if (f < 0 || f >= CKFeatureCount) return;
    ck_featLoad();
    if (on) g_featMask |=  (1u << f);
    else    g_featMask &= ~(1u << f);
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:ck_key(ck_featureKey(f))];
    [[NSUserDefaults standardUserDefaults] synchronize];
    CKLog(@"[开关] %@ -> %@", CKFeatureName(f), on ? @"开" : @"关");
}

NSString *CKFeatureName(CKFeature f) {
    switch (f) {
        case CKFeatureRewardForce:   return @"强制发奖";
        case CKFeatureEcpmTamper:    return @"eCPM 篡改";
        case CKFeatureFingerprint:   return @"指纹随机";
        case CKFeatureOverlay:       return @"悬浮窗";
        case CKFeatureAntiJailbreak: return @"越狱绕过";
        case CKFeatureAntiDebug:     return @"反调试";
        case CKFeatureDyldHide:      return @"镜像隐藏";
        case CKFeatureNetTamper:     return @"网络篡改";
        default: return @"?";
    }
}

BOOL CKFeatureIsLive(CKFeature f) {
    switch (f) {
        case CKFeatureRewardForce:
        case CKFeatureEcpmTamper:
        case CKFeatureFingerprint:
        case CKFeatureOverlay:
            return YES;      // trampoline 里实时判定
        default:
            return NO;       // 装 hook 时机类，改了要重启 App
    }
}

// ============================================================
//  参数表
// ============================================================
const CKParamDef kCKParams[] = {
    { CKP_ECPM_MODE,    "eCPM 模式",     0,  1,     1,   ECPM_ABSOLUTE,          YES },
    { CKP_ECPM_MIN,     "区间下界",      1,  200,   0.5, ECPM_MIN,               NO  },
    { CKP_ECPM_MAX,     "区间上界",      1,  300,   0.5, ECPM_MAX,               NO  },
    { CKP_ECPM_MUL,     "收益倍率",      1,  20,    0.1, REVENUE_MULTIPLIER,     NO  },
    { CKP_REWARD_COOL,  "发奖冷却(秒)",  0,  300,   5,   REWARD_COOLDOWN_SEC,    YES },
    { CKP_REWARD_DELAY, "补发延迟(秒)",  0,  10,    0.1, 0.6,                    NO  },
    { CKP_WATCH_MIN,    "最短观看(秒)",  0,  60,    1,   WATCH_TIME_MIN,         NO  },
    { CKP_WATCH_MAX,    "最长观看(秒)",  0,  120,   1,   WATCH_TIME_MAX,         NO  },
    { CKP_CLICK_MIN,    "点击延迟下限",  0,  5000,  10,  CLICK_DELAY_MIN_MS,     YES },
    { CKP_CLICK_MAX,    "点击延迟上限",  0,  8000,  10,  CLICK_DELAY_MAX_MS,     YES },
    { CKP_FP_ROTATE,    "启动换指纹",    0,  1,     1,   ROTATE_EVERY_LAUNCH,    YES },
};
const size_t kCKParamCount = sizeof(kCKParams) / sizeof(kCKParams[0]);

// 参数值缓存：与 kCKParams 下标一一对应，首次访问灌满
static double          g_paramCache[sizeof(kCKParams) / sizeof(kCKParams[0])];
static BOOL            g_paramLoaded = NO;
static pthread_mutex_t g_paramLock = PTHREAD_MUTEX_INITIALIZER;

static void ck_paramLoad(void) {
    pthread_mutex_lock(&g_paramLock);
    if (!g_paramLoaded) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        for (size_t i = 0; i < kCKParamCount; i++) {
            NSString *k = ck_key(kCKParams[i].key);
            g_paramCache[i] = ([d objectForKey:k] == nil)
                              ? kCKParams[i].def
                              : [d doubleForKey:k];
        }
        g_paramLoaded = YES;
    }
    pthread_mutex_unlock(&g_paramLock);
}

// 下标查找（参数只有 11 个，线性扫很快，且只在热路径外调用一次后可缓存）
static int ck_paramIndex(const char *key) {
    if (!key) return -1;
    for (size_t i = 0; i < kCKParamCount; i++) {
        if (strcmp(kCKParams[i].key, key) == 0) return (int)i;
    }
    return -1;
}

const CKParamDef *CKParamDefFor(const char *key) {
    int i = ck_paramIndex(key);
    return (i < 0) ? NULL : &kCKParams[i];
}

double CKParamDefault(const char *key) {
    const CKParamDef *d = CKParamDefFor(key);
    return d ? d->def : 0;
}

double CKParamGet(const char *key) {
    int i = ck_paramIndex(key);
    if (i < 0) return 0;
    if (!g_paramLoaded) ck_paramLoad();
    return g_paramCache[i];          // 热路径：一次数组读
}

void CKParamSet(const char *key, double v) {
    int i = ck_paramIndex(key);
    if (i < 0) return;
    const CKParamDef *d = &kCKParams[i];
    if (v < d->lo) v = d->lo;        // 夹范围，防止倍率被设成 0 或负数
    if (v > d->hi) v = d->hi;

    ck_paramLoad();
    g_paramCache[i] = v;
    [[NSUserDefaults standardUserDefaults] setDouble:v forKey:ck_key(key)];
    [[NSUserDefaults standardUserDefaults] synchronize];
    CKLog(@"[参数] %s = %g", key, v);
}

void CKDumpFeatures(void) {
    CKLog(@"[配置] ---- 功能开关 ----");
    for (int i = 0; i < CKFeatureCount; i++) {
        CKLog(@"[配置] %@ : %@ (%@)",
              CKFeatureName((CKFeature)i),
              CKFeatureGet((CKFeature)i) ? @"开" : @"关",
              CKFeatureIsLive((CKFeature)i) ? @"即时生效" : @"重启后生效");
    }
    CKLog(@"[配置] ---- 数值参数 ----");
    for (size_t i = 0; i < kCKParamCount; i++) {
        CKLog(@"[配置] %s = %g", kCKParams[i].key, CKParamGet(kCKParams[i].key));
    }
}
