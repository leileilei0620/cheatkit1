//
//  CheatKit.m —— 入口（通用版 / 裸 dylib）
//
//  加载策略：
//    被注入进任意进程后立刻判断要不要干活：
//      系统进程 → 只装反检测，其余不动（保护注入环境本身）
//      敏感 App → 直接返回，什么都不做
//      其他第三方 App → 全套模块
//
//  ★ 不用 Logos（%ctor / %hook）：
//    改用 __attribute__((constructor))，纯 clang 就能编，
//    不需要 Theos，也不需要 Logos 预处理。
//

#import <Foundation/Foundation.h>
#import <stdint.h>   // int64_t（dispatch_time 参数）
#import <unistd.h>   // getpid
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>   // dispatch_after / dispatch_get_main_queue 显式声明，
                                // 不依赖 Foundation 的间接包含链（Linux 交叉编译更稳）

#import "Config.h"
#import "Common/Log.h"
#import "Common/Stats.h"
#import "Common/Overlay.h"
#import "Common/FeatureFlags.h"
#import "Common/SubstrateRT.h"     // 运行时 hook 能力探测
#import "Common/Fingerprint.h"
#import "Common/AntiDetect.h"
#import "Modules/AdEngine.h"
#import "Modules/HookReward.h"
#import "Modules/HookEcpm.h"
#import "Modules/HookAntiRoot.h"
#import "Modules/HookNet.h"

// ============================================================
//  延迟启动：等 App 首帧之后再装 hook
//  冷启动阶段类还没加载完，太早扫类会漏
// ============================================================
static void ck_bootstrap_target_app(void) {
    CKStatsMarkStart();
    CKLog(@"========== CheatKit 启动 ==========");
    CKLog(@"Bundle: %@", CKCurrentBundleID());

    // 先把运行时开关/参数读一遍，下面各模块安装时就按用户设置走
    CKDumpFeatures();

    // ★ 探测 hook 能力：有没有 Substrate/ElleKit 决定后面哪些 hook 能装
    CKDumpSubstrateStatus();

    // ★ 浮窗提到最前面装：
    //   1. 注入成功 = 立刻能看到面板，不用等后面几秒的类扫描
    //   2. 万一后面某个模块装 hook 时崩了，面板已经在那儿了，
    //      能看出停在哪一步（状态面板会显示最后一条日志）
    //   数字一开始是 0，后面各模块装完自己会往上灌。
    CKInstallOverlay();

    // 顺序有讲究：先铺环境，再上功能
    CKInstallAntiDetect();       // 越狱检测 + 反调试 + dyld 隐藏
    CKInstallFingerprintHooks(); // 设备指纹
    CKInstallAntiRootHooks();    // App 自有风控探针
    CKInstallNetHooks();         // pinning（必须在抓包前）
    CKInstallEcpmHooks();        // 价格篡改（模型层 + 序列化层）

    // 通用广告引擎：自动识别 SDK 并按方法形状接管
    CKInstallAdEngine();

    // 精细 hook（已知 SDK 的确定性入口，双保险）
    CKInstallRewardHooks();

#if ENABLE_SDK_SCAN
    CKDumpAdSDKs();
#endif

    CKLog(@"========== 就绪，SDK: %@ ==========",
          [CKDetectedSDKs() componentsJoinedByString:@", "]);
}

static void ck_bootstrap_system(void) {
    // 系统进程只装反检测：保证 App 启动前注入环境已经伪装好
    CKInstallAntiDetect();
}

// 首次界面出现后再装业务 hook，避免与 SDK 初始化争用
//
// ★ 必须去重：通知 与 3 秒兜底 两条路都可能触发。
//   重复执行 ck_bootstrap_target_app 会把所有 hook 装两遍
//   （trampoline 套 trampoline），轻则数字翻倍，重则闪退。
static BOOL g_bootstrapped = NO;

static void ck_bootstrap_once(void) {
    if (g_bootstrapped) return;
    g_bootstrapped = YES;
    ck_bootstrap_target_app();
}

static void ck_schedule_bootstrap(void) {
    __block id observer = nil;
    observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        ck_bootstrap_once();
    }];

    // 兜底：3 秒内没收到通知也装（后台型 / 非 UIKit App）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ck_bootstrap_once();
    });
}

// ============================================================
//  入口：进程加载 dylib 时自动执行
// ============================================================
__attribute__((constructor))
static void CheatKitInit(void) {
    @autoreleasepool {
        NSString *bid = CKCurrentBundleID();

        // ★ 第一行日志必须在这里打：证明 dylib 真的被注入进来了。
        //   后面的所有判断（系统进程 / 敏感 App / 延迟启动）都可能 return，
        //   如果不在构造期打一条，用户「没浮窗」时根本分不清是
        //   「没注入」还是「注入了但被跳过」。
        CKLog(@"[注入] pid=%d bundle=%@", getpid(), bid);

        // 系统进程（SpringBoard、daemon、系统 App）
        BOOL sys = [bid isEqualToString:@"com.apple.springboard"] ||
                   [bid hasPrefix:EXCLUDE_BUNDLE_PREFIXES] ||
                   [bid isEqualToString:@"unknown"];
        if (sys) {
            ck_bootstrap_system();
            return;
        }

        // 敏感 App（银行 / 支付）不碰
        if (!CKIsTargetProcess()) {
            CKLog(@"[注入] 命中敏感 App 关键词，跳过");
            return;
        }

        ck_schedule_bootstrap();
    }
}
