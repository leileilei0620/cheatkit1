//
//  Modules/HookEcpm.m
//  eCPM / 收益数据篡改 —— 通用版
//
//  三条路径同时挂：
//   1) 价格模型层 —— GADAdValue / BU*EcpmInfo / GDT*EcpmInfo 这类承载价格的模型
//   2) 序列化层   —— NSJSONSerialization 转 Data/字符串前的最终拦截
//   3) 请求体层   —— NSMutableURLRequest setHTTPBody 改写上报数据
//
//  数值策略集中在 Common/Rewriter.m，本文件只做 hook 装配。
//
//  ⚠️ 递归雷区（已处理，改代码时别踩回去）：
//     hook 了 NSJSONSerialization 之后，任何地方再调 [NSJSONSerialization
//     dataWithJSONObject:] 都会重新进 ck_JSON_data，形成嵌套改写。
//     所以内部一律走 g_origJSON_data 直调原实现。
//

#import "HookEcpm.h"
#import "../Common/Log.h"
#import "../Common/HookUtil.h"
#import "../Common/Rewriter.h"
#import "../Common/FeatureFlags.h"   // 运行时开关
#import "../Config.h"
#import <objc/runtime.h>
#import <stdlib.h>
#import <pthread.h>

// ============================================================
//  原实现登记表
//
//  为什么不能像以前那样直接 method_setImplementation 就走：
//    浮窗里要能「关掉 eCPM 篡改、立刻生效」。要不改返回值的唯一办法
//    就是记住原 IMP，开关关掉时转调它。所以 hook 时先把
//    (Class, SEL, orig IMP, 返回类型) 存下来。
// ============================================================
typedef struct {
    Class cls;
    SEL   sel;
    IMP   orig;
    char  ret;      // 返回类型首字符
} CKEcpmSlot;

#define CK_ECPM_SLOTS 256
static CKEcpmSlot     g_ecpmSlots[CK_ECPM_SLOTS];
static int            g_ecpmSlotCount = 0;
static pthread_mutex_t g_ecpmLock = PTHREAD_MUTEX_INITIALIZER;

static void ck_ecpmRecord(Class cls, SEL sel, IMP orig, char ret) {
    pthread_mutex_lock(&g_ecpmLock);
    for (int i = 0; i < g_ecpmSlotCount; i++) {
        if (g_ecpmSlots[i].cls == cls && sel_isEqual(g_ecpmSlots[i].sel, sel)) {
            g_ecpmSlots[i].orig = orig;
            pthread_mutex_unlock(&g_ecpmLock);
            return;
        }
    }
    if (g_ecpmSlotCount < CK_ECPM_SLOTS) {
        g_ecpmSlots[g_ecpmSlotCount].cls  = cls;
        g_ecpmSlots[g_ecpmSlotCount].sel  = sel;
        g_ecpmSlots[g_ecpmSlotCount].orig = orig;
        g_ecpmSlots[g_ecpmSlotCount].ret  = ret;
        g_ecpmSlotCount++;
    }
    pthread_mutex_unlock(&g_ecpmLock);
}

// 沿父类链找原实现（同一 SEL 在不同类里 IMP 不同，必须带 Class 查）
static IMP ck_ecpmOrig(id self, SEL sel) {
    Class c = object_getClass(self);
    IMP found = NULL;
    pthread_mutex_lock(&g_ecpmLock);
    for (Class k = c; k && !found; k = class_getSuperclass(k)) {
        for (int i = 0; i < g_ecpmSlotCount; i++) {
            if (g_ecpmSlots[i].cls == k && sel_isEqual(g_ecpmSlots[i].sel, sel)) {
                found = g_ecpmSlots[i].orig;
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_ecpmLock);
    return found;
}

// 开关关掉时透传原实现，没记录原实现就退回一个安全默认值
static inline BOOL ck_ecpmOn(void) { return CKFeatureGet(CKFeatureEcpmTamper); }

// ============================================================
//  A. 价格模型层
// ============================================================

// GADAdValue: - (NSDecimalNumber *)value
static id ck_GAD_value(id self, SEL _cmd) {
    if (!ck_ecpmOn()) {
        IMP o = ck_ecpmOrig(self, _cmd);
        if (o) return ((id (*)(id, SEL))o)(self, _cmd);
    }
    NSDecimalNumber *v = [NSDecimalNumber decimalNumberWithString:
                          [NSString stringWithFormat:@"%.4f", CKFakeEcpm() / 1000.0]];
    CKLog(@"[eCPM] GADAdValue.value -> %@", v);
    return v;
}

// 穿山甲：ecpm 返回 NSInteger（单位分）
static NSInteger ck_BU_ecpm_int(id self, SEL _cmd) {
    if (!ck_ecpmOn()) {
        IMP o = ck_ecpmOrig(self, _cmd);
        if (o) return ((NSInteger (*)(id, SEL))o)(self, _cmd);
    }
    NSInteger v = CKInflateInteger(0);
    CKLog(@"[eCPM] BU.ecpm -> %ld", (long)v);
    return v;
}

// 优量汇：ecpm 返回 double（单位元/千次）
static double ck_GDT_ecpm(id self, SEL _cmd) {
    if (!ck_ecpmOn()) {
        IMP o = ck_ecpmOrig(self, _cmd);
        if (o) return ((double (*)(id, SEL))o)(self, _cmd);
    }
    double v = CKFakeEcpm();
    CKLog(@"[eCPM] GDT.ecpm -> %.4f", v);
    return v;
}

// 通用：任何 "ecpm"/"revenue"/"payout" 形式的无参取值方法，按返回类型自动适配
static double ck_generic_ecpm_d(id self, SEL _cmd) {
    if (!ck_ecpmOn()) {
        IMP o = ck_ecpmOrig(self, _cmd);
        if (o) return ((double (*)(id, SEL))o)(self, _cmd);
    }
    return CKFakeEcpm();
}
static NSInteger ck_generic_ecpm_i(id self, SEL _cmd) {
    if (!ck_ecpmOn()) {
        IMP o = ck_ecpmOrig(self, _cmd);
        if (o) return ((NSInteger (*)(id, SEL))o)(self, _cmd);
    }
    return CKInflateInteger(0);
}
static id ck_generic_ecpm_o(id self, SEL _cmd) {
    if (!ck_ecpmOn()) {
        IMP o = ck_ecpmOrig(self, _cmd);
        if (o) return ((id (*)(id, SEL))o)(self, _cmd);
    }
    return [NSDecimalNumber decimalNumberWithString:
            [NSString stringWithFormat:@"%.4f", CKFakeEcpm()]];
}

// ============================================================
//  B. 序列化层
// ============================================================
static IMP g_origJSON_data = NULL;
static IMP g_origJSON_string = NULL;

static id ck_JSON_data(id self, SEL _cmd, id obj, NSJSONWritingOptions opt, NSError **err) {
    if (!g_origJSON_data) return nil;
    if (!ck_ecpmOn()) {                     // 开关关掉 → 原样序列化
        return ((id (*)(id, SEL, id, NSJSONWritingOptions, NSError **))g_origJSON_data)
               (self, _cmd, obj, opt, err);
    }
    id rewritten = CKRewriteObject(obj, 0);
    return ((id (*)(id, SEL, id, NSJSONWritingOptions, NSError **))g_origJSON_data)
           (self, _cmd, rewritten, opt, err);
}

static NSString *ck_JSON_string(id self, SEL _cmd, id obj,
                                NSJSONWritingOptions opt, NSError **err) {
    if (!g_origJSON_string) return nil;
    if (!ck_ecpmOn()) {
        return ((NSString *(*)(id, SEL, id, NSJSONWritingOptions, NSError **))g_origJSON_string)
               (self, _cmd, obj, opt, err);
    }
    id rewritten = CKRewriteObject(obj, 0);
    return ((NSString *(*)(id, SEL, id, NSJSONWritingOptions, NSError **))g_origJSON_string)
           (self, _cmd, rewritten, opt, err);
}

// ============================================================
//  C. 请求体层
// ============================================================
static IMP g_origSetHTTPBody = NULL;

static void ck_setHTTPBody(id self, SEL _cmd, NSData *body) {
    if (ck_ecpmOn() && body.length > 0 && body.length < 256 * 1024) {
        // 反序列化没被 hook，可以直接用
        id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if (json) {
            id rewritten = CKRewriteObject(json, 0);
            // 序列化必须直调原实现，否则会重入 ck_JSON_data
            NSData *newBody = nil;
            if (g_origJSON_data) {
                newBody = ((id (*)(id, SEL, id, NSJSONWritingOptions, NSError **))g_origJSON_data)
                          ([NSJSONSerialization class],
                           @selector(dataWithJSONObject:options:error:),
                           rewritten, 0, NULL);
            }
            if (newBody && ![newBody isEqualToData:body]) {
                CKLog(@"[eCPM] 请求体改写 %lu -> %lu bytes",
                      (unsigned long)body.length, (unsigned long)newBody.length);
                body = newBody;
            }
        }
    }
    if (g_origSetHTTPBody)
        ((void (*)(id, SEL, NSData *))g_origSetHTTPBody)(self, _cmd, body);
}

// ============================================================
//  装配
// ============================================================
static void ck_hookPayModelClass(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    if (!cls) return;

    // 注意：@selector(变量) 不合法，必须先转字符串
    NSString *selStr = [NSString stringWithUTF8String:selName];
    if (!selStr) return;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selStr));
    if (!m) return;

    const char *enc = method_getTypeEncoding(m);

    // 返回类型在 encoding 首位
    IMP imp;
    if (enc && (enc[0] == 'q' || enc[0] == 'i' || enc[0] == 'I' ||
                enc[0] == 'l' || enc[0] == 'Q' || enc[0] == 's' || enc[0] == 'S'))
        imp = (IMP)ck_BU_ecpm_int;
    else if (enc && (enc[0] == 'd' || enc[0] == 'f'))
        imp = (IMP)ck_GDT_ecpm;
    else if (enc && enc[0] == '@')
        imp = (IMP)ck_generic_ecpm_o;
    else
        imp = (IMP)ck_generic_ecpm_d;

    IMP cur = method_getImplementation(m);
    if (cur == imp) return;                 // 已挂，但槽可能没记（重复调用）
    // ★ 先把原 IMP 记进槽表，关开关时才有东西可透传
    ck_ecpmRecord(cls, NSSelectorFromString(selStr), cur, enc ? enc[0] : 'd');
    method_setImplementation(m, imp);
    CKLog(@"[eCPM] hook %s -%s", clsName, selName);
}

void CKInstallEcpmHooks(void) {
#if ENABLE_ECPM_INFLATE
    // 数值策略随配置生效
    CKSyncEcpmPolicyFromParams();   // 以运行时参数为准（浮窗滑块）

    // ---- A1. AdMob 价格对象 ----
    Class gad = objc_getClass("GADAdValue");
    if (gad) {
        Method m = class_getInstanceMethod(gad, @selector(value));
        if (m) {
            if (method_getImplementation(m) != (IMP)ck_GAD_value) {
                ck_ecpmRecord(gad, @selector(value), method_getImplementation(m), '@');
                method_setImplementation(m, (IMP)ck_GAD_value);
            }
            CKLog(@"[eCPM] GADAdValue.value hook 完成");
        }
    }

    // ---- A2. 各家价格类（类名 × 取值方法全量枚举） ----
    const char *priceClasses[] = {
        // 穿山甲 / Pangle
        "BUAdEcpmInfo", "BUMRewardAdEcpmInfo", "BUAdSlotEcpmInfo",
        "CSJAdEcpmInfo", "PAGAdEcpmInfo",
        // 优量汇 / GDT
        "GDTeCPMInfo", "GDTAdEcpmInfo", "GDTRewardEcpmInfo",
        // 快手
        "KSAdEcpmInfo", "KSRewardEcpmInfo",
        // 百度
        "BaiduMobAdEcpmInfo",
        // Mintegral
        "MTGAdEcpmInfo",
        // IronSource
        "ISImpressionData", "LPMImpressionData",
        // 聚合
        "ATAdEcpmInfo", "TradPlusAdEcpmInfo", "GMEcpmInfo",
        // AppLovin
        "MAAdValue", "ALAdValue",
    };
    const char *priceSels[] = { "ecpm", "eCPM", "ECPM", "revenue", "payout", "price" };

    for (size_t i = 0; i < sizeof(priceClasses) / sizeof(priceClasses[0]); i++) {
        for (size_t j = 0; j < sizeof(priceSels) / sizeof(priceSels[0]); j++) {
            ck_hookPayModelClass(priceClasses[i], priceSels[j]);
        }
    }

    // ---- B. JSON 序列化层（先装，C 段依赖它） ----
    Class jsonCls = objc_getClass("NSJSONSerialization");
    if (jsonCls) {
        Method m1 = class_getClassMethod(jsonCls, @selector(dataWithJSONObject:options:error:));
        if (m1) {
            g_origJSON_data = method_getImplementation(m1);
            method_setImplementation(m1, (IMP)ck_JSON_data);
            CKLog(@"[eCPM] NSJSONSerialization data hook 完成");
        }
        Method m2 = class_getClassMethod(jsonCls, @selector(stringWithJSONObject:options:error:));
        if (m2) {
            g_origJSON_string = method_getImplementation(m2);
            method_setImplementation(m2, (IMP)ck_JSON_string);
            CKLog(@"[eCPM] NSJSONSerialization string hook 完成");
        }
    }

    // ---- C. 请求体 ----
    Class reqCls = objc_getClass("NSMutableURLRequest");
    if (reqCls) {
        Method mb = class_getInstanceMethod(reqCls, @selector(setHTTPBody:));
        if (mb) {
            g_origSetHTTPBody = method_getImplementation(mb);
            method_setImplementation(mb, (IMP)ck_setHTTPBody);
            CKLog(@"[eCPM] setHTTPBody hook 完成");
        }
    }

    CKLog(@"[eCPM] 安装完成（模式=%@，区间 %.1f~%.1f，倍数 %.2f）",
          CKParamGet(CKP_ECPM_MODE) >= 0.5 ? @"绝对值" : @"倍数",
          CKParamGet(CKP_ECPM_MIN), CKParamGet(CKP_ECPM_MAX), CKParamGet(CKP_ECPM_MUL));
#endif
}

// 兼容旧接口
double CKInflateRevenue(double real) { return CKInflateDouble(real); }
