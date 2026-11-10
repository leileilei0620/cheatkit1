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
