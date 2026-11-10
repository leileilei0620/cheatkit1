# CheatKit

iOS 小游戏通用广告模块 —— **裸 dylib**，直接注入，覆盖 17 家广告 SDK。

产物就是 `CheatKit.dylib` 一个文件，`install_name` 为 `@executable_path/Frameworks/CheatKit.dylib`，和同类注入插件同一种形态：

- **TrollStore / TrollFools**：直接把 dylib 拖进目标 App，不用越狱机改系统
- **rootless 越狱（Dopamine）**：放进 `/var/jb/Library/MobileSubstrate/DynamicLibraries/` 配 plist，由 ElleKit 全进程注入
- 不带 deb、不带安装脚本，扔进注入器就能用

---

## 一、三分钟出 dylib（GitHub 云编译，不用 Mac）

### 1. 建仓库

打开 https://github.com/new，建一个**私有**仓库，**不要**勾 "Add a README file"、**不要**勾 .gitignore。

### 2. 上传代码

资源管理器先进这个目录，点「查看」→ 勾上「**隐藏的项目**」（不勾看不到 `.github` 和 `.gitignore`，而 `.github` 就是编译入口）。

仓库首页 → **Add file** → **Upload files** → 把本项目文件夹**里面**的内容全选拖进去（不是拖文件夹本身）→ **Commit changes**。

命令行也行：

```bash
cd CheatKit
git init -b main
git add -A
git commit -m "init"
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

### 3. 跑编译

仓库页面 → **Actions** → 左侧 **Build Dylib** → 右侧 **Run workflow** → 绿色按钮。

等 3~5 分钟。绿勾之后点进这次运行，页面底部 **Artifacts** 下就是 `CheatKit-dylib.zip`，里面是 **CheatKit.dylib**。

想发正式版：本地 `git tag v2.0.0 && git push --tags`，会自动发 Release，dylib 直接挂在 Release 页。

---

## 二、为什么用 Ubuntu 而不是 macOS

| | macOS runner | Ubuntu runner |
|---|---|---|
| 启动耗时 | 1~3 分钟 | 10~20 秒 |
| 额度消耗 | 10× | 1× |
| `macos-14` | 部分账号被解析成 `macos-14-arm64-us-default` 机型池，直接 Cancelled | 无此问题 |
| 可行性 | 需要 Xcode | Theos 官方支持 Linux 交叉编译 |

关键改动（和标准 Theos 工程的区别）：

| 项 | 做法 | 原因 |
|---|---|---|
| `substrate.h` | 自带 `src/vendor/substrate.h` | 官方 iPhoneOS SDK 里没有这个头 |
| 链接 substrate | `-undefined dynamic_lookup` | GitHub 上没有 `libsubstrate.dylib`，符号运行期由 ElleKit/注入器提供 |
| 入口 | `__attribute__((constructor))` | 不依赖 Logos，纯 clang 也能编 |
| ObjC 运行时 | `-fobjc-runtime=ios-15.0` | Ubuntu 的 clang 默认 gnustep runtime，会和 ARC 冲突 |
| 链接器 | 直调 `ld64.lld`，显式给 `-arch` / `-platform_version` | clang 驱动在 Linux 上不会把 `-target` 翻译成 ld64.lld 需要的参数 |
| 合并架构 | `llvm-lipo`，架构名重复时降级单架构 | Linux 的 ld64.lld 对 arm64e 支持不完整 |

---

## 三、本地编译（可选）

macOS（装了 Xcode）：

```bash
chmod +x build_dylib.sh
./build_dylib.sh
```

Linux（装了 clang / lld / llvm，且 `$HOME/theos/sdks` 下有 iPhoneOS SDK）：

```bash
sudo apt-get install -y clang lld llvm libplist-dev libssl-dev zlib1g-dev
chmod +x build_dylib.sh
./build_dylib.sh
```

产物固定是 `build/CheatKit.dylib`。

---

## 四、配置：两层

### 4.1 运行时开关和参数（推荐，浮窗里改，立刻生效）

注入成功后面板右上角有 ⚙，点进去有 8 个开关 + 11 个滑块。改完马上按新值跑，**不用重新编译，不用重装**。

**开关（8 个）**

| 开关 | 作用 | 生效 |
|---|---|---|
| 强制发奖 | 拦奖励回调，直接把「是否有效」改成真 | 即时 |
| eCPM 改写 | 改上报给服务器的收益数字 | 即时 |
| 设备指纹 | 伪造 IDFA / IDFV / 安装 ID | 即时 |
| 悬浮窗 | 本面板是否显示 | 重启 App |
| 越狱检测绕过 | 文件/符号/scheme 层伪装 | 即时 |
| 反调试 | ptrace / sysctl 层伪装 | 即时 |
| dyld 隐藏 | 从模块列表里抹掉自己 | 即时 |
| 网络改写 | 证书校验放行 + 响应 JSON 改写 | 即时 |

**参数（11 个）**

| 参数 | 范围 | 默认 | 说明 |
|---|---|---|---|
| eCPM 模式 | 0 / 1 | 1 | 0=倍数，1=绝对值 |
| eCPM 下限 | 1~100 | 28 | 绝对值模式下的最小值 |
| eCPM 上限 | 1~200 | 46 | 绝对值模式下的最大值 |
| **收益倍率** | 1.0~10.0 | 3.2 | **只在此参数为倍数模式时生效** |
| 发奖冷却（秒） | 0~300 | 45 | 两次发奖的最小间隔 |
| 发奖延迟（秒） | 0~10 | 0.6 | 回调后多久补发 |
| 观看时长下限 | 5~60 | 15 | 拟真用 |
| 观看时长上限 | 5~90 | 32 | 拟真用 |
| 点击延迟下限（毫秒） | 0~2000 | 320 | 拟真用 |
| 点击延迟上限（毫秒） | 0~5000 | 1650 | 拟真用 |
| 指纹轮换 | 0 / 1 | 1 | 每次启动换新设备 ID |

设置存在 `NSUserDefaults`，键名 `ck.feat.*` / `ck.param.*`。设置面板底部有「恢复出厂默认」。

### 4.2 编译期默认值（`src/Config.h`）

**只有要改注入范围时才需要动它**：注入哪些 App、跳过哪些、默认开关/参数是多少。改完要重新编译。

```c
#define CK_GENERIC_MODE        1        // 1=所有第三方 App 都注入
#define TARGET_BUNDLE_IDS      @"com.example.targetapp"   // 只在定向模式用
#define EXCLUDE_BUNDLE_PREFIXES @"com.apple."             // 系统 App 跳过
#define SKIP_SENSITIVE_APPS    1        // 银行/支付类跳过
#define SENSITIVE_KEYWORDS     @[@"bank",@"pay",@"wallet",@"alipay",@"tenpay",@"unionpay"]
```

**只对某一个游戏生效**：把 `CK_GENERIC_MODE` 改 0，`TARGET_BUNDLE_IDS` 填那个游戏的 bundle id。

---

## 五、覆盖的 SDK

| SDK | 类名前缀指纹 |
|---|---|
| 穿山甲 / Pangle | `BURewarded` `BUMRewarded` `CSJRewarded` `PAGRewarded` `BUAdEcpm` |
| 优量汇 / 广点通 | `GDTReward` `GDTeCPM` `GDTAdEcpm` `GDTSDK` |
| 快手 | `KSReward` `KSAd` `KSFeed` `KSFull` `KSInterstitial` |
| 百度 | `BaiduMobAd` `BaiduMob` `BaiduApp` |
| AdMob | `GADRewarded` `GADAdValue` `GADResponseInfo` `GADRequest` |
| AppLovin | `ALAdReward` `ALReward` `MAAd` `MAAdapter` |
| IronSource | `ISRewarded` `ISAdReward` `ISImpression` `LPMRewarded` |
| Mintegral | `MTGReward` `MTReward` `MTGAd` `MTRewarded` |
| Unity Ads | `UnityAds` `UADSReward` `UADSBanner` |
| Vungle / Liftoff | `VungleAd` `VNGReward` `VungleSDK` |
| Sigmob | `SMReward` `SigmobAd` `SIGReward` |
| Chartboost | `CHBReward` `Chartboost` |
| TopOn | `ATRewarded` `ATAd` `AnyThink` `AWMReward` |
| TradPlus | `TPReward` `TradPlusAd` |
| GroMore | `GMReward` `GMEcpm` `GroMore` |
| 通用兜底 | 类名含 `reward` / `interstitial` / `adloader` / `adrequest` / `adview` / `admanager` / `adnetwork` / `adimpression` / `adrevenue` / `adcontent` / `adsdk` / `adevent` |

> **为什么前缀都 ≥3 字符**：`IS` `AL` `AT` 这类两字母前缀会把系统类（`NSString` `NSArray` `AVPlayer`）一起命中，扫类阶段就要花掉几秒。全部改成三字母以上，误伤基本为零。

两个引擎分工：

- **AdEngine** —— 认「形状」。按方法签名的参数类型自动生成转发函数，BOOL 参数 `NO→YES`、整型 `0→1`，不依赖具体类名
- **HookReward** —— 认「名字」。40 条精确规则表（`类名 + 方法名`），命中就 hook，比模糊匹配更稳

---

## 六、目录结构

```
CheatKit/
├── .github/workflows/build.yml     GitHub Actions（Ubuntu 编译裸 dylib）
├── src/
│   ├── CheatKit.m                  入口（constructor），决定要不要干活
│   ├── Config.h                    编译期默认值（注入范围 + 默认开关/参数）
│   ├── Common/
│   │   ├── Log.{h,m}               日志 + 环形缓冲（浮窗读它）
│   │   ├── Stats.{h,m}             运行计数（hook 数 / 改写次数 / 发奖次数）
│   │   ├── Overlay.{h,m}           悬浮窗：状态面板 + 设置面板
│   │   ├── FeatureFlags.{h,m}      运行时开关 / 参数（NSUserDefaults + 内存缓存）
│   │   ├── Rewriter.{h,m}          JSON 递归改写（eCPM / 验证字段）
│   │   ├── Fingerprint.{h,m}       IDFA / IDFV / 安装 ID 伪造
│   │   ├── AntiDetect.{h,m}        越狱检测绕过 / 反调试 / dyld 隐藏
│   │   └── HookUtil.h              hook 工具函数
│   ├── Modules/
│   │   ├── AdEngine.{h,m}          通用广告引擎（按方法签名自适应）
│   │   ├── HookReward.{h,m}        40 条精确规则（奖励回调）
│   │   ├── HookEcpm.{h,m}          收益字段 hook
│   │   ├── HookAntiRoot.{h,m}      越狱检测方法扫描
│   │   └── HookNet.{h,m}           证书校验放行 + 响应改写
│   └── vendor/
│       ├── substrate.h             最小 Substrate 声明（SDK 里没有）
│       └── ck_compat.h             strcasestr 等不可移植函数的自带实现
├── build_dylib.sh                  编译脚本（macOS / Linux 通用）
├── entitlements.plist              ldid 伪签名用
├── selfcheck.py                    静态自检（不用 SDK，先挡结构性错误）
└── README.md
```

---

## 七、悬浮窗（验证模块真的在跑 + 当场调参）

注入成功后面板出现在右上角。**没出现就是没注入，不用猜**。

### 7.1 状态面板

```
CheatKit            ⚙  —  ✕
com.example.game  ×3.2
SDK: 穿山甲 优量汇 快手
扫描 412 / 兜底 88
hook 奖 24 播 11 败 6
精确 40   跳过 3
eCPM 改写 128
发奖 7   运行 143s
· [eCPM] NSJSONSerialization data hook 完成
· [AdEngine] 识别 3 家 SDK
· [注入] com.example.game
开关 奖价指网   运行 143s
```

| 读数 | 不对时说明什么 |
|---|---|
| 面板完全没出现 | dylib 没被注入 → 查注入器是否成功、App 是否被判定为系统/敏感 App 跳过 |
| `SDK:` 后面是「未识别」 | 类名指纹没命中 → 翻 `src/Modules/AdEngine.m` 的 `kSdkTable` 加前缀 |
| `hook` 三个数全是 0 | 方法名不在关键词表里 → 开 `ENABLE_SDK_SCAN` 重编译，看日志 dump 出来的真实方法名 |
| `eCPM 改写 0` | 收益数据不走 JSON 序列化 → 走的是别的上报通道，需要按实际路径加 hook |
| `发奖 0` 但 hook 有数 | 代理对象（delegate）取不到 → 检查 `ck_delegateOf` 试的那 5 个 KVC 键 |
| 倍率显示 `×3.2` 但 eCPM 不变 | 模式在「绝对值」，拨到 0 才用倍率 |

### 7.2 设置面板（点 ⚙）

```
← 设置
强制发奖        [●]  即时生效
eCPM 改写       [●]  即时生效
设备指纹        [●]  即时生效
悬浮窗          [●]  需重启 App
...
eCPM 模式        1        [====|-----]
eCPM 下限        28       [==|-------]
收益倍率         3.2      [===|------]
发奖冷却         45       [==|-------]
...
     恢复出厂默认
```

拖滑块立刻生效，不用重编译。

### 7.3 操作

| 按钮 | 作用 |
|---|---|
| 标题条拖动 | 移动位置 |
| ⚙ | 打开设置面板 |
| — | 收成小条（`CheatKit ▸`），点一下展开 |
| ✕ | 本次运行隐藏（重启 App 还会出来；要彻底关去设置里关「悬浮窗」） |

### 7.4 五个设计坑（自己维护时注意）

1. **不能抢 keyWindow** → `canBecomeKeyWindow` 返回 `NO`，用 `bringSubviewToFront` 而不是 `makeKeyAndVisible`
2. **必须能触摸穿透** → `hitTest` 里把自己和透明 rootVC 的 view 都返回 `nil`，否则游戏全屏点不动
3. **不要设会铺满全屏的 rootViewController 内容** → 透明 VC 的 `view.userInteractionEnabled = NO`
4. **`windowLevel` 要够高** → `UIWindowLevelAlert + 100`，否则被广告全屏层盖住
5. **iOS 13+ 没有 `UIWindowScene` 的 window 不显示** → 拿不到 scene 就退到「挂到宿主 window 上」，别用 `initWithFrame:`

---

## 七点五、闪退排查看这里（实战验证过的三个真坑）

下面三条都是**真实崩溃日志**定位出来的，不是猜的。如果你的 dylib 注入后闪退，先对号入座。

### 坑 1：同名 dylib 被注入了两份（最常见）

**症状**：一启动就闪退，日志里镜像名是 `CheatKit (1).dylib`。

**原因**：TrollFools 之类的工具里对同一个 App 重复「注入」，会在 `Frameworks/` 下留两份：
```
idiom.app/Frameworks/CheatKit.dylib
idiom.app/Frameworks/CheatKit (1).dylib     ← 多出来的
```
两份 `constructor` 都会跑，于是所有 hook 装两遍、`objc_copyClassList` 扫两遍、
`method_setImplementation` 对同一批 Method 写两次。objc runtime 的 method cache
被并发改写 → `EXC_BAD_ACCESS` / `SIGBUS` / `KERN_PROTECTION_FAILURE`。

**修**：注入工具里删掉带 `(1)` 的那份，只留一个。
代码里也加了单实例保护（`g_cheatkit_instance_guard` 符号探测），
第二份会打日志直接退出，不会再动手。**但仍然建议手动删干净**。

### 坑 2：全进程替换 URLSession delegate（会崩）

**症状**：启动几秒后闪退，触发线程是 `com.apple.CFNetwork.Connection`。

**原因**：老版本按 SEL 扫**整个进程**所有类的
`-URLSession:didReceiveChallenge:completionHandler:` 并统一替换实现。
Security.framework、CFNetwork、WebKit 内部都实现了这个方法，
替换后 `SecTrust` 被并发重复评估 →
```
Security  __SecTrustEvaluateFastAsync_block_invoke
Security  __handle_trust_evaluate_xpc_async_block_invoke_2
```
主线程同时卡在 `class_getInstanceMethod`，两件事撞一起。

**修**：新增两个开关，默认走安全版：
```c
#define ENABLE_NET_SESSION_HOOK_SAFE   1   // 只 hook 本 App 镜像里的类（默认）
#define ENABLE_NET_SESSION_HOOK_ALL    0   // 连系统类一起 hook（会崩，别开）
```
安全版用 `class_getImageName(cls)` 和 `[NSBundle mainBundle].bundlePath` 比对前缀，
只接管 App 自己的 delegate。游戏自带的 pinning 校验类通常在 App 主二进制里，照样能绕过。

### 坑 3：mprotect 改 dyld_all_image_infos（SIGBUS）

**症状**：闪退地址落在 `__DATA_DIRTY` 且属于某个系统库，比如
```
0x1ec1479fc is in ...__DATA_DIRTY... SM=COW ...ispatch.dylib
```

**原因**：`dyld_all_image_infos` 在 `__DATA_CONST`，受 codesign 保护。
`mprotect` 经常返回 EACCES；就算成功，把 `infoArray` 换成自己的 malloc 数组后，
dyld 自身和 CrashReporter 遍历该数组时会摸到已失效的指针 → SIGBUS。

**修**：新增开关，默认关闭结构体层：
```c
#define ENABLE_DYLD_INFOARRAY_PATCH    0   // 只用函数层隐藏（默认，安全）
```
关掉后仍保留 `_dyld_image_count` / `_dyld_get_image_name` 的 Hook，
绝大多数越狱检测走的是这两个函数，够用。

### 顺带修的两件

- **bootstrap 移出主线程**：整套模块要遍历几千个类并逐个 `method_setImplementation`，
  全都拿 objc runtime 全局锁。原来跑在主线程 → 卡死 + 撞车。现在丢到
  `com.cheatkit.bootstrap` 串行队列（`QOS_CLASS_UTILITY` 优先级）。
- **SecTrust inline hook 默认关闭**（`ENABLE_NET_TRUST_HOOK 0`）：inline hook 打补丁
  那一瞬如果系统 TLS 线程正在执行该函数，会跳到半条指令上。需要时再手动开。

### 排查顺序

1. 看镜像名有没有 `(1)` → 有就先删
2. 看 `exception.type` 是 `EXC_BAD_ACCESS` 还是 `EXC_CRASH`
   - `EXC_CRASH` + `_dyld_missing_symbol_abort` → 是 Substrate 符号残留，更新到 SubstrateRT 版
   - `EXC_BAD_ACCESS` + `SIGBUS` → 对号入座上面坑 1/2/3
3. 看 `faultingThread` 的 `queue` 名字，能直接指出是哪条线程出的事
4. 把 `ENABLE_ANTI_JAILBREAK`、`ENABLE_DYLD_HIDE`、`ENABLE_NET_TAMPER` 全设 0 再跑一遍，
   能起来就逐个打开定位

---

## 八、FAQ

**装完没反应 / 没浮窗**
1. dylib 真的注入进去了吗？TrollFools 里看目标 App 是否在列表且已启用
2. rootless 越狱走 ElleKit 的话，dylib 和 plist 都得在 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`
3. App 是银行/支付类？`SKIP_SENSITIVE_APPS` 会主动跳过
4. 系统 App（`com.apple.*`）默认跳过

**App 闪退**
把「dyld 隐藏」开关关掉试。有些 App 自己也在扫 dyld，两边打架会崩。

**服务器不认（本地显示改成功了，后台收益没变）**
客户端只改了显示和上报字段。如果服务端用签名/上报回执做二次校验，客户端改不了——那是服务端逻辑。

**改了 Config.h 要重编译吗**
要。`Config.h` 是编译期宏。日常调参走浮窗，不用动它。

**运行时的设置会丢吗**
不会，存在 `NSUserDefaults`，App 重装才丢。

**Actions 报 `macos-14-arm64-us-default is not supported`**
已经不用 macOS runner 了，全走 `ubuntu-latest`。

**Actions 报 SDK 安装失败**
`theos/sdks` 仓库里 SDK 是**目录**不是压缩包，workflow 已改稀疏克隆 + 三级降级（16.5 → 15.6 → 14.5）。

**编译报 `call to undeclared function 'pthread_mutex_unlock'`**
Linux 交叉编译下 Foundation 的间接包含链断了，`src/` 下各文件已显式补 `<pthread.h>` / `<stdlib.h>` / `<objc/runtime.h>` 等头。

**编译报 `'sys/ptrace.h' file not found`**
iPhoneOS SDK 里确实没这个头。`src/Common/AntiDetect.m` 已改成 dlsym 动态取 `ptrace`，`PT_DENY_ATTACH = 31` 直接写字面量。

**编译报 `must specify -platform_version`**
Linux 的 clang 驱动不会把 `-target arm64-apple-ios15.0` 翻译成 ld64.lld 的参数。脚本已改成直调 `ld64.lld`。

---

## 九、自检

改完代码推之前先跑一次（不需要 SDK，纯静态）：

```bash
python3 selfcheck.py
```

查六项：括号配对、`@interface`/`@end` 配对、Logos 配对、`.m` 里混入 C++ 关键字、裸 `dlsym` 取 orig（hook 后会自递归）、`#import` 目标是否真实存在。

CI 里第一步就跑它，出问题不用等编译。
