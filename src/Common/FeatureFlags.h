//
//  Common/FeatureFlags.h —— 运行时功能开关 + 参数中心
//
//  为什么要这个：
//    Config.h 里的宏是编译期展开的，改一个倍率就得重新 push → 等 5 分钟 Actions
//    → 重装 deb → 重启 App。调参数的时候这个循环根本没法用。
//
//  这套东西解决的是：
//    1. 每个功能一个开关，装好之后在浮窗里点一下就开关
//    2. 倍率/区间/冷却这些数值可以拖滑块实时调
//    3. 设置存在 NSUserDefaults 里，杀进程也还在
//    4. Config.h 里的宏降级成「出厂默认值」，第一次运行时自动灌进去
//
//  开关分两类（重要）：
//    A. 即时生效 —— eCPM 篡改 / 奖励强制 / 指纹 / 浮窗自己
//       这类开关在 trampoline 内部判定，关掉= 直接调原实现，等于空转
//    B. 重启生效 —— 越狱检测绕过 / 反调试 / dyld 隐藏 / 网络篡改
//       这类是「铺环境」，hook 装上去就没法拆，只能重启 App 重新走安装流程
//       浮窗里会标注，不会骗你
//

#ifndef CK_FEATURES_H
#define CK_FEATURES_H

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <string.h>
#import "../Config.h"

// ============================================================
//  功能开关
// ============================================================
typedef NS_ENUM(NSInteger, CKFeature) {
    CKFeatureRewardForce = 0,   // 强制触发激励回调      即时生效
    CKFeatureEcpmTamper,        // eCPM / 收益篡改       即时生效
    CKFeatureFingerprint,       // 设备指纹随机化        即时生效
    CKFeatureOverlay,           // 浮窗自身              即时生效
    CKFeatureAntiJailbreak,     // 越狱检测绕过          重启生效
    CKFeatureAntiDebug,         // 反调试                重启生效
    CKFeatureDyldHide,          // dyld 镜像隐藏         重启生效
    CKFeatureNetTamper,         // 网络响应篡改          重启生效
    CKFeatureCount
};

BOOL        CKFeatureGet(CKFeature f);
void        CKFeatureSet(CKFeature f, BOOL on);
NSString   *CKFeatureName(CKFeature f);     // 中文名，给浮窗用
BOOL        CKFeatureIsLive(CKFeature f);   // YES=即时生效，NO=重启生效

// ============================================================
//  数值参数
// ============================================================
typedef struct {
    const char *key;      // 存储键
    const char *title;    // 显示名
    double      lo, hi;   // 滑块范围
    double      step;     // 滑块步进
    double      def;      // 出厂默认
    BOOL        isInt;    // 显示整数
} CKParamDef;

extern const CKParamDef kCKParams[];
extern const size_t     kCKParamCount;

double CKParamGet(const char *key);
void   CKParamSet(const char *key, double v);
double CKParamDefault(const char *key);
const  CKParamDef *CKParamDefFor(const char *key);

// 参数键常量（别直接写字符串，容易打错）
#define CKP_ECPM_MODE    "ecpm.mode"          // 0=倍数放大  1=区间伪造
#define CKP_ECPM_MIN     "ecpm.min"
#define CKP_ECPM_MAX     "ecpm.max"
#define CKP_ECPM_MUL     "ecpm.multiplier"    // ★ 核心倍率
#define CKP_REWARD_COOL  "reward.cooldown"
#define CKP_REWARD_DELAY "reward.delay"
#define CKP_WATCH_MIN    "watch.min"
#define CKP_WATCH_MAX    "watch.max"
#define CKP_CLICK_MIN    "click.min"
#define CKP_CLICK_MAX    "click.max"
#define CKP_FP_ROTATE    "fingerprint.rotate"

// 把当前所有设置打一份日志（排查用）
void CKDumpFeatures(void);

#endif
