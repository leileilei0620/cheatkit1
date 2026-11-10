//
//  Config.h —— 全局配置
//  通用版：不绑定单一 App，自动适配装进来的任何广告 SDK
//

#ifndef CONFIG_H
#define CONFIG_H

// ============================================================
// 1. 注入范围
// ============================================================
// CK_GENERIC_MODE = 1  通用模式：所有第三方 App 都注入（系统 App 自动跳过）
// CK_GENERIC_MODE = 0  定向模式：只注入下面 TARGET_BUNDLE_IDS 里的 App
#define CK_GENERIC_MODE          1

// 定向模式时生效（通用模式下不用管）
#define TARGET_BUNDLE_IDS \
    @"com.example.targetapp"

// 通用模式下额外排除的 App（前缀匹配）。系统 App 已自动排除
#define EXCLUDE_BUNDLE_PREFIXES \
    @"com.apple."

// 通用模式下是否跳过含这些关键字的 App（银行/支付类，避免误伤）
#define SKIP_SENSITIVE_APPS      1
#define SENSITIVE_KEYWORDS \
    @"bank", @"pay", @"wallet", @"alipay", @"tenpay", @"unionpay"

// ============================================================
// 2. 功能开关
// ============================================================
#define ENABLE_REWARD_FORCE      1   // 强制触发激励回调（核心）
#define ENABLE_ECPM_INFLATE      1   // eCPM / 收益篡改
#define ENABLE_FINGERPRINT       1   // 设备指纹随机化
#define ENABLE_ANTI_JAILBREAK    1   // 越狱检测绕过
#define ENABLE_ANTI_DEBUG        1   // 反调试绕过
#define ENABLE_DYLD_HIDE         1   // dyld 镜像表摘除
#define ENABLE_NET_TAMPER        1   // 网络响应篡改
#define ENABLE_SDK_SCAN          0   // 启动时 dump 所有广告相关类（调试用，正式版关）
#define ENABLE_OVERLAY           1   // 进程内悬浮窗：实时显示注入/hook/改写状态

// ---- 危险 hook 分级（★ 默认全关，闪退就是它们引起的）-------------------
// ENABLE_NET_SESSION_HOOK
//   1 = 按 SEL 扫全进程所有类的 -URLSession:didReceiveChallenge:completionHandler:
//       并替换实现。会命中 Security / CFNetwork / WebKit 内部类，
//       已证实导致 SIGBUS（KERN_PROTECTION_FAILURE，SecTrust 被并发重复评估）。
//   0 = 只处理本 App 与 Frameworks 目录下的类（游戏自己的 delegate），安全。
#define ENABLE_NET_SESSION_HOOK_SAFE   1   // 安全版：只 hook 非系统类（推荐）
#define ENABLE_NET_SESSION_HOOK_ALL    0   // 全量版：连系统类一起 hook（会崩，别开）

// ENABLE_NET_TRUST_HOOK
//   1 = inline hook SecTrustEvaluate / SecTrustEvaluateWithError。
//       需要 Substrate/ElleKit；裸注入下自动跳过。手机会常驻 TLS 握手线程，
//       在线程正执行该函数时打补丁 = 半条指令 → 跳到野地址，风险高。
#define ENABLE_NET_TRUST_HOOK          0

// ENABLE_DYLD_INFOARRAY_PATCH
//   1 = mprotect 改 dyld_all_image_infos->infoArray（结构体层摘除镜像）。
//       __DATA_CONST 页受 codesign 保护，mprotect 常失败；即便成功，
//       dyld 内部与 CrashReporter 遍历该数组时会读到已换掉的指针 → SIGBUS。
//   0 = 只用 _dyld_image_count / _dyld_get_image_name 函数层隐藏（安全）。
#define ENABLE_DYLD_INFOARRAY_PATCH    0

// ENABLE_CFUNC_HOOK  —— C 函数 inline hook 总闸（★ 默认 0）
//
//   这一组 hook 包括 stat / lstat / access / fopen / open / realpath /
//   dlsym / fork / sandbox_check / ptrace / sysctl / getppid / getenv /
//   _dyld_image_count / _dyld_get_image_name。
//
//   为什么默认关：
//     inline hook 是「把目标函数开头几条指令改写成跳转」。改的那一瞬间，
//     如果别的线程正好执行到该函数前几条指令 → 跳到半条指令上 → SIGBUS。
//     libsystem 的 stat/fopen/dlsym 是全进程最高频的函数（每个线程都在调），
//     裸注入（TrollFools，没有 Substrate/ElleKit 的 trampoline 保护）下
//     这个窗口几乎必然被撞上。
//
//     实测崩溃栈（真机 idiom iOS 16.3.1）：
//        0 dyld  strlen
//        1 dyld  strcpy
//        2 dyld  dyld4::APIs::dlsym(void*, char const*)
//        3 CheatKit  CKInstallJailbreakBypass
//     地址落在另一个系统库的 __TEXT（r-x，只读）→ KERN_PROTECTION_FAILURE。
//     也就是说 dlsym 被打补丁后，dyld 内部解析路径时写到了只读页。
//
//   1 = 允许安装（只有确认手机有 ElleKit/Substrate 时才开）
//   0 = 全部跳过，一次 dlsym 都不调用（当前默认，最稳）
#define ENABLE_CFUNC_HOOK              0

// ============================================================
// 3. SDK 覆盖（通用引擎会自己探测，这里是精细 hook 的开关）
// ============================================================
#define SDK_PANGLE               1   // 穿山甲 / Pangle / CSJ（字节）
#define SDK_GDT                  1   // 优量汇 / 广点通（腾讯）
#define SDK_KUAISHOU             1   // 快手联盟
#define SDK_BAIDU                1   // 百度联盟
#define SDK_ADMOB                1   // Google AdMob
#define SDK_APPLOVIN             1   // AppLovin
#define SDK_IRONSOURCE           1   // IronSource / LevelPlay
#define SDK_MINTEGRAL            1   // Mintegral（汇量）
#define SDK_UNITYADS             1   // Unity Ads
#define SDK_VUNGLE               1   // Vungle / Liftoff
#define SDK_SIGMOB               1   // Sigmob
#define SDK_CHARTBOOST           1   // Chartboost
#define SDK_TOPTON               1   // TopOn / AnyThink（聚合）
#define SDK_TRADPLUS             1   // TradPlus（聚合）
#define SDK_GROMORE              1   // GroMore（穿山甲聚合）
#define SDK_MAX                  1   // MAX / AppLovin 聚合
#define SDK_GENERIC              1   // 万能兜底：关键词扫描（必须有）

// ============================================================
// 4. 数值策略
// ============================================================
// eCPM 模式：0=倍数放大（跟随真实值），1=绝对值伪造（随机落在区间内）
#define ECPM_ABSOLUTE            1

// 绝对值模式区间（元 / 千次展示）
#define ECPM_MIN                 28.0
#define ECPM_MAX                 46.0

// 倍数模式系数
#define REVENUE_MULTIPLIER       3.2

// 观看时长区间（秒）—— 低于 15 秒容易被判无效
#define WATCH_TIME_MIN           15.0
#define WATCH_TIME_MAX           32.0

// 每次冷启动是否换指纹（1=每次都换，0=按轮次）
#define ROTATE_EVERY_LAUNCH      1

// 轮转周期：多少次会话后换一次指纹
#define ROTATE_AFTER_N_SESSIONS  5

// ============================================================
// 5. 拟真参数
// ============================================================
// 点击/拉起间隔抖动（毫秒）
#define CLICK_DELAY_MIN_MS       320
#define CLICK_DELAY_MAX_MS       1650

// 单位：秒。同一设备连续两次激励的最小冷却
#define REWARD_COOLDOWN_SEC      45

// 连续触发上限（0=不限）。防止一次会话刷太狠
#define REWARD_MAX_PER_SESSION   0

// ============================================================
// 6. 调试
// ============================================================
#define VERBOSE_LOG              1   // 1=输出到 NSLog，正式版改 0
#define LOG_PREFIX               @"[CheatKit] "

#endif
