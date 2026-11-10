//
//  Common/Overlay.m —— 进程内悬浮窗（状态面板 + 设置面板）
//
//  两个面板：
//    1. 状态面板（默认显示）
//       实时数字：注入成功没、认出哪家 SDK、装了多少 hook、改了多少次、发了几次奖
//    2. 设置面板（点 ⚙ 打开）
//       每个功能一个开关，每个数值一个滑块，改完立刻生效（个别需重启，会标注）
//
//  踩过的坑（改之前务必看）：
//    1. UIWindow 要自己持有强引用，否则出作用域就被释放，窗口立刻消失
//    2. windowLevel 必须高于 alert，否则被游戏/广告的全屏视图盖住
//    3. 不能抢 keyWindow：重写 canBecomeKeyWindow 返回 NO
//    4. ★ 必须做触摸穿透：窗口是全屏透明的，hitTest 命中 self 就返回 nil，
//       否则游戏全屏区域点不动
//    5. ★ 不能设 rootViewController：它的 view 会铺满全屏参与 hitTest，
//       穿透逻辑直接失效
//    6. ★ 拖动判定用自身坐标，位移用父坐标（混用会导致拖动完全失效）
//    7. closeSelf 要延到下一个 runloop 再清引用，否则 use-after-free
//

#import "Overlay.h"
#import "Stats.h"
#import "Log.h"
#import "FeatureFlags.h"
#import "AutoPilot.h"
#import "../Config.h"
#import "../Modules/AdEngine.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <string.h>        // strcmp（AI 曲线滑块判定）
#import <math.h>          // round / lround

static UIColor *ck_green(void) { return [UIColor colorWithRed:0.2 green:0.95 blue:0.55 alpha:1.0]; }
static UIColor *ck_dim(void)   { return [UIColor colorWithWhite:0.72 alpha:1.0]; }

// ============================================================
//  窗口：不抢 key + 触摸穿透
// ============================================================
//  空 rootViewController：iOS 13+ 带 scene 的 UIWindow 如果 rootViewController 为 nil，
//  部分系统版本会跳过布局/着色，窗口「存在但不显示」——这是最常见的「没浮窗」原因。
//  所以补一个透明 VC，但把它的 view 关掉交互，否则它铺满全屏会吞掉点击，
//  导致 hitTest 的穿透判定失效（返回的是 rvc.view，不是 self）。
@interface CKOverlayRootVC : UIViewController
@end

@implementation CKOverlayRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = NO;   // ★ 关键：不吞事件
}
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
@end

@interface CKOverlayWindow : UIWindow
@end

@implementation CKOverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFocused   { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self) return nil;                                  // 点在卡片外
    if (self.rootViewController && v == self.rootViewController.view) return nil;
    return v;
}
@end

// ============================================================
//  通用行：开关行
// ============================================================
@interface CKToggleRow : UIView
@property (nonatomic, strong) UILabel  *nameLabel;
@property (nonatomic, strong) UILabel  *hintLabel;
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, assign) CKFeature feature;
@end

@implementation CKToggleRow

- (instancetype)initWithFrame:(CGRect)frame feature:(CKFeature)f {
    if ((self = [super initWithFrame:frame])) {
        _feature = f;
        CGFloat w = frame.size.width;

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 3, w - 92, 17)];
        _nameLabel.font = [UIFont systemFontOfSize:12];
        _nameLabel.textColor = [UIColor whiteColor];
        _nameLabel.text = CKFeatureName(f);
        [self addSubview:_nameLabel];

        _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 19, w - 92, 14)];
        _hintLabel.font = [UIFont systemFontOfSize:9];
        _hintLabel.textColor = CKFeatureIsLive(f) ? ck_green() : [UIColor orangeColor];
        _hintLabel.text = CKFeatureIsLive(f) ? @"即时生效" : @"需重启 App";        [self addSubview:_hintLabel];

        _sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 52, 4, 51, 31)];
        _sw.transform = CGAffineTransformMakeScale(0.72, 0.72);
        _sw.on = CKFeatureGet(f);
        _sw.onTintColor = ck_green();
        [_sw addTarget:self action:@selector(swChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_sw];
    }
    return self;
}

- (void)swChanged {
    CKFeatureSet(_feature, _sw.on);
    // ★ 这里刻意**不**销毁自己的窗口。
    //   原因：设置面板本身就挂在浮窗里，把浮窗关掉等于把面板也关了，
    //   用户再想打开就没入口了（只能重启 App 才能回来，体验很差）。
    //   所以「悬浮窗」开关的语义是：关掉 → 下次启动不再出现；
    //   本次运行想临时收起来，用标题条上的「✕」。
    if (_feature == CKFeatureOverlay && !_sw.on) {
        CKLog(@"[浮窗] 已关闭，下次启动 App 不再显示（本次运行仍保留，用 ✕ 可临时隐藏）");
    }
#if ENABLE_AUTOPILOT
    // ★ AI 开关的语义是「即时生效」：打开就立刻起闭环，关掉下一拍自然停
    if (_feature == CKFeatureAutoPilot) {
        if (_sw.on) {
            CKAPStart();
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CKAPCurveApplied" object:nil];
        } else {
            CKLog(@"[浮窗] AI 自动调参已关，参数保持当前值不再自动变");
        }
    }
#endif
}

@end

// ============================================================
//  通用行：滑块行
// ============================================================
@interface CKSliderRow : UIView
@property (nonatomic, strong) UILabel  *nameLabel;
@property (nonatomic, strong) UILabel  *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, assign) const CKParamDef *def;
@end

@implementation CKSliderRow

- (instancetype)initWithFrame:(CGRect)frame param:(const CKParamDef *)d {
    if ((self = [super initWithFrame:frame])) {
        _def = d;
        CGFloat w = frame.size.width;

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 2, w - 96, 16)];
        _nameLabel.font = [UIFont systemFontOfSize:11];
        _nameLabel.textColor = ck_dim();
        _nameLabel.text = @(d->title);
        [self addSubview:_nameLabel];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 92, 2, 92, 16)];
        _valueLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        _valueLabel.textColor = ck_green();
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_valueLabel];

        _slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 20, w, 24)];
        _slider.minimumValue = (float)d->lo;
        _slider.maximumValue = (float)d->hi;
        _slider.value = (float)CKParamGet(d->key);
        _slider.minimumTrackTintColor = ck_green();
        [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_slider];

        [self updateValueLabel];
    }
    return self;
}

- (void)updateValueLabel {
    double v = _def->isInt ? (double)(long)lround(CKParamGet(_def->key))
                           : CKParamGet(_def->key);
    _valueLabel.text = _def->isInt ? [NSString stringWithFormat:@"%ld", (long)v]
                                   : [NSString stringWithFormat:@"%.2f", v];
}

- (void)sliderChanged {
    double v = _slider.value;
    // 按步进取整，避免 28.0000001 这种
    if (_def->step > 0) {
        v = round(v / _def->step) * _def->step;
        _slider.value = (float)v;
    }
    CKParamSet(_def->key, v);
    [self updateValueLabel];

#if ENABLE_AUTOPILOT
    // ★ 拖「AI 激进程度」时把曲线一次性铺开，其余滑块跟着动
    //   所以拖完要通知设置面板重刷一遍滑块位置，否则显示的还是旧值。
    if (strcmp(_def->key, CKP_AP_AGGR) == 0) {
        CKAPApplyCurveNow(v);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CKAPCurveApplied" object:nil];
    }
#endif
}

@end

// ============================================================
//  设置面板
// ============================================================
@interface CKSettingsView : UIView
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray *rows;
#if ENABLE_AUTOPILOT
@property (nonatomic, strong) UILabel *apLabel;
// 私有方法前置声明：避免调用点早于定义时产生
// "instance method not found (return type defaults to 'id')" 警告
- (void)doTickAllSliders;
- (void)refreshAPLabel;
- (void)onCurveApplied;
#endif
@end

@implementation CKSettingsView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.86];
        self.layer.cornerRadius = 10.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = ck_green().CGColor;
        self.clipsToBounds = YES;
        _rows = [NSMutableArray array];

        CGFloat w = frame.size.width;
        CGFloat h = frame.size.height;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, w - 60, 20)];
        title.font = [UIFont boldSystemFontOfSize:13];
        title.textColor = ck_green();
        title.text = @"功能开关 / 参数";
        [self addSubview:title];

        // 关闭按钮（回到状态面板）
        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        back.frame = CGRectMake(w - 40, 4, 32, 28);
        [back setTitle:@"←" forState:UIControlStateNormal];
        [back setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        back.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:back];

        // 滚动区
        _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 32, w, h - 32)];
        _scroll.showsVerticalScrollIndicator = YES;
        [self addSubview:_scroll];

        CGFloat y = 4;
        CGFloat innerW = w - 20;

        // ---- 功能开关 ----
        UILabel *sec1 = [[UILabel alloc] initWithFrame:CGRectMake(10, y, innerW, 16)];
        sec1.font = [UIFont boldSystemFontOfSize:11];
        sec1.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        sec1.text = @"— 功能开关 —";
        [_scroll addSubview:sec1];
        y += 20;

        for (int i = 0; i < CKFeatureCount; i++) {
            CKToggleRow *r = [[CKToggleRow alloc] initWithFrame:CGRectMake(10, y, innerW, 34)
                                                        feature:(CKFeature)i];
            [_scroll addSubview:r];
            [_rows addObject:r];
            y += 36;
        }

        // ---- 数值参数 ----
        y += 6;
        UILabel *sec2 = [[UILabel alloc] initWithFrame:CGRectMake(10, y, innerW, 16)];
        sec2.font = [UIFont boldSystemFontOfSize:11];
        sec2.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        sec2.text = @"— 数值参数（拖动实时生效）—";
        [_scroll addSubview:sec2];
        y += 20;

        for (size_t i = 0; i < kCKParamCount; i++) {
            CKSliderRow *r = [[CKSliderRow alloc] initWithFrame:CGRectMake(10, y, innerW, 46)
                                                          param:&kCKParams[i]];
            [_scroll addSubview:r];
            [_rows addObject:r];
            y += 48;
        }

        // ---- AI 自动调参 ----
#if ENABLE_AUTOPILOT
        y += 6;
        UILabel *sec3 = [[UILabel alloc] initWithFrame:CGRectMake(10, y, innerW, 16)];
        sec3.font = [UIFont boldSystemFontOfSize:11];
        sec3.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        sec3.text = @"— AI 自动调参 —";
        [_scroll addSubview:sec3];
        y += 20;

        UILabel *apHint = [[UILabel alloc] initWithFrame:CGRectMake(10, y, innerW, 30)];
        apHint.numberOfLines = 0;
        apHint.font = [UIFont systemFontOfSize:10];
        apHint.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
        apHint.text = @"上面的「AI 激进程度」一条曲线同时推倍率/冷却/观看/点击 6 个参数。"
                       "开着会自动朝目标速率收敛；关掉就是纯手动。";
        [_scroll addSubview:apHint];
        y += 34;

        UIButton *apResume = [UIButton buttonWithType:UIButtonTypeSystem];
        apResume.frame = CGRectMake(10, y, (innerW - 8) / 2, 32);
        [apResume setTitle:@"恢复自动" forState:UIControlStateNormal];
        [apResume setTitleColor:ck_green() forState:UIControlStateNormal];
        apResume.titleLabel.font = [UIFont systemFontOfSize:12];
        apResume.layer.borderWidth = 0.5;
        apResume.layer.borderColor = ck_green().CGColor;
        apResume.layer.cornerRadius = 6;
        [apResume addTarget:self action:@selector(doAPResume) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:apResume];

        UIButton *apTick = [UIButton buttonWithType:UIButtonTypeSystem];
        apTick.frame = CGRectMake(10 + (innerW + 8) / 2, y, (innerW - 8) / 2, 32);
        [apTick setTitle:@"立即调整" forState:UIControlStateNormal];
        [apTick setTitleColor:ck_green() forState:UIControlStateNormal];
        apTick.titleLabel.font = [UIFont systemFontOfSize:12];
        apTick.layer.borderWidth = 0.5;
        apTick.layer.borderColor = ck_green().CGColor;
        apTick.layer.cornerRadius = 6;
        [apTick addTarget:self action:@selector(doAPTick) forControlEvents:UIControlEventTouchUpInside];
        [_scroll addSubview:apTick];
        y += 40;

        _apLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, y, innerW, 30)];
        _apLabel.numberOfLines = 0;
        _apLabel.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
        _apLabel.textColor = ck_dim();
        [_scroll addSubview:_apLabel];
        y += 34;
#endif

        // ---- 重置 ----
        y += 6;
        UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
        reset.frame = CGRectMake(10, y, innerW, 34);
        [reset setTitle:@"恢复出厂默认" forState:UIControlStateNormal];
        [reset setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        reset.titleLabel.font = [UIFont systemFontOfSize:12];
        reset.layer.borderWidth = 0.5;
        reset.layer.borderColor = [UIColor orangeColor].CGColor;
        reset.layer.cornerRadius = 6;
        [reset addTarget:self action:@selector(doReset) forControlEvents:UIControlEventTouchUpInside];

        // ---- 自检（不用查 Console，点一下把诊断打到浮窗日志区）----
        y += 40;
        UIButton *diag = [UIButton buttonWithType:UIButtonTypeSystem];
        diag.frame = CGRectMake(10, y, innerW, 32);
        [diag setTitle:@"自检" forState:UIControlStateNormal];
        [diag setTitleColor:[UIColor colorWithRed:0.4 green:0.9 blue:0.6 alpha:1.0]
                   forState:UIControlStateNormal];
        diag.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        diag.layer.borderColor = [UIColor colorWithRed:0.3 green:0.8 blue:0.5 alpha:0.8].CGColor;
        diag.layer.borderWidth = 1;
        diag.layer.cornerRadius = 6;
        [diag addTarget:self action:@selector(doSelfCheck) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:diag];
        y += 40;
        [_scroll addSubview:reset];
        y += 42;

        _scroll.contentSize = CGSizeMake(w, y);

#if ENABLE_AUTOPILOT
        // 拖「AI 激进程度」会让 6 个参数一起变，这里监听并重刷其余滑块
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onCurveApplied)
                                                     name:@"CKAPCurveApplied"
                                                   object:nil];
#endif
    }
    return self;
}

#if ENABLE_AUTOPILOT
- (void)onCurveApplied {
    [self doTickAllSliders];
    [self refreshAPLabel];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
#endif

- (void)goBack {
    self.hidden = YES;
    // 通知状态面板刷新（顺便让它显示出来）
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CKOverlayShowMain" object:nil];
}

// ---- 自检：把所有关键诊断一次性打到浮窗日志区 ----
//   用户不用连 Console，点一下就能看「卡在哪一步」。
- (void)doSelfCheck {
    CKStatsSnapshot st = CKStatsGet();
    NSArray *sdks = CKDetectedSDKs();

    CKLog(@"[自检] ===== CheatKit 自检 =====");
    CKLog(@"[自检] 进程 %@  运行 %.0fs", CKCurrentBundleID(), st.uptime);
    CKLog(@"[自检] 广告类 已知%d 兜底%d", st.knownClasses, st.genericClasses);
    CKLog(@"[自检] hook 奖励%d 播放%d 失败%d 跳过%d 精确槽%d",
          st.rewardHooks, st.playHooks, st.failHooks, st.skipped, st.exactSlots);
    CKLog(@"[自检] SDK %@", sdks.count ? [sdks componentsJoinedByString:@","] : @"未识别");
    CKLog(@"[自检] 补发 排程%d 尝试%d 成功%d 原因:%@",
          CKStatsScheduleCount(), CKStatsAttemptCount(), st.rewardsFired,
          CKStatsLastRewardReason());
    CKLog(@"[自检] 开关 奖励%@ eCPM%@ 指纹%@ 网络%@",
          CKFeatureGet(CKFeatureRewardForce) ? @"开" : @"关",
          CKFeatureGet(CKFeatureEcpmTamper) ? @"开" : @"关",
          CKFeatureGet(CKFeatureFingerprint) ? @"开" : @"关",
          CKFeatureGet(CKFeatureNetTamper) ? @"开" : @"关");

    // 一句话结论
    NSString *verdict = nil;
    if (st.rewardHooks + st.playHooks == 0) {
        verdict = @"没装上任何广告 hook → 这个 App 用的 SDK 不在指纹表里，或广告还没初始化";
    } else if (CKStatsScheduleCount() == 0) {
        verdict = @"hook 装上了但没触发 → 广告还没播，或播完回调名不在关键词表";
    } else if (CKStatsAttemptCount() == 0) {
        verdict = @"排程了但定时器没跑 → 主线程被阻塞（检查是否卡在加载）";
    } else if (st.rewardsFired == 0) {
        verdict = @"投递了但没成功 → delegate 找不到，把浮窗里的 adObj 类名发我";
    } else {
        verdict = @"全链路通了，奖励已发出";
    }
    CKLog(@"[自检] 结论：%@", verdict);
}

- (void)doReset {
    for (size_t i = 0; i < kCKParamCount; i++) {
        CKParamSet(kCKParams[i].key, kCKParams[i].def);
    }
    for (id r in _rows) {
        if ([r isKindOfClass:[CKSliderRow class]]) {
            CKSliderRow *s = (CKSliderRow *)r;
            s.slider.value = (float)CKParamDefault(s.def->key);
            [s updateValueLabel];
        }
    }
    CKLog(@"[浮窗] 参数已恢复默认");
#if ENABLE_AUTOPILOT
    [self refreshAPLabel];
#endif
}

#if ENABLE_AUTOPILOT
- (void)doAPResume {
    CKAPResume();
    [self doTickAllSliders];
    [self refreshAPLabel];
    CKLog(@"[浮窗] AI 已恢复自动");
}

- (void)doAPTick {
    CKAPTickNow();
    // 采样是异步的（在 AI 队列上跑），1.5 秒后再刷一次标签
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self doTickAllSliders];
        [self refreshAPLabel];
    });
}

- (void)doTickAllSliders {
    for (id r in _rows) {
        if ([r isKindOfClass:[CKSliderRow class]]) {
            CKSliderRow *s = (CKSliderRow *)r;
            s.slider.value = (float)CKParamGet(s.def->key);
            [s updateValueLabel];
        }
    }
}

- (void)refreshAPLabel {
    if (!_apLabel) return;
    _apLabel.text = [NSString stringWithFormat:@"%@\n%@",
                     CKAPStatusLine(), CKAPLastReason()];
}
#endif

// 每次显示时同步一次开关状态（可能在别处改过）
- (void)syncSwitches {
    for (id r in _rows) {
        if ([r isKindOfClass:[CKToggleRow class]]) {
            CKToggleRow *t = (CKToggleRow *)r;
            t.sw.on = CKFeatureGet(t.feature);
        }
    }
#if ENABLE_AUTOPILOT
    [self refreshAPLabel];
#endif
}

@end

// ============================================================
//  状态面板
// ============================================================
@interface CKOverlayView : UIView
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UILabel  *bodyLabel;
@property (nonatomic, strong) UILabel  *logLabel;
@property (nonatomic, strong) UIButton *gearBtn;
@property (nonatomic, strong) UIButton *collapseBtn;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) NSTimer  *timer;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGRect  frameAtDragStart;
@property (nonatomic, strong) CKSettingsView *settings;
- (void)toggleCollapse;   // 外部（安装逻辑）也要能调，必须在这里声明
- (void)refresh;
@end

static CKOverlayWindow *g_window = nil;
static CKOverlayView   *g_view   = nil;

@implementation CKOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
        self.layer.cornerRadius = 10.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = ck_green().CGColor;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;

        CGFloat w = frame.size.width;

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, w - 108, 18)];
        _titleLabel.font = [UIFont boldSystemFontOfSize:12];
        _titleLabel.textColor = ck_green();
        _titleLabel.text = @"CheatKit";
        [self addSubview:_titleLabel];

        // ⚙ 设置
        _gearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _gearBtn.frame = CGRectMake(w - 92, 2, 30, 26);
        [_gearBtn setTitle:@"⚙" forState:UIControlStateNormal];
        [_gearBtn setTitleColor:ck_green() forState:UIControlStateNormal];
        _gearBtn.titleLabel.font = [UIFont systemFontOfSize:16];
        [_gearBtn addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_gearBtn];

        // — 收起
        _collapseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _collapseBtn.frame = CGRectMake(w - 62, 2, 28, 26);
        [_collapseBtn setTitle:@"—" forState:UIControlStateNormal];
        [_collapseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _collapseBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [_collapseBtn addTarget:self action:@selector(toggleCollapse) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_collapseBtn];

        // ✕ 关闭
        _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeBtn.frame = CGRectMake(w - 32, 2, 28, 26);
        [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [_closeBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0]
                        forState:UIControlStateNormal];
        _closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_closeBtn addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_closeBtn];

        // 数据区
        _bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 26, w - 20, 116)];
        _bodyLabel.numberOfLines = 0;
        _bodyLabel.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
        _bodyLabel.textColor = [UIColor whiteColor];
        _bodyLabel.text = @"初始化...";
        [self addSubview:_bodyLabel];

        // 日志区
        _logLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 122, w - 20, frame.size.height - 128)];
        _logLabel.numberOfLines = 0;
        _logLabel.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
        _logLabel.textColor = ck_dim();
        _logLabel.text = @"";
        [self addSubview:_logLabel];

        // 设置面板（同尺寸覆盖，默认隐藏）
        _settings = [[CKSettingsView alloc] initWithFrame:CGRectMake(-1, -1, 320, 430)];
        _settings.hidden = YES;
        [self addSubview:_settings];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(showMain)
                                                     name:@"CKOverlayShowMain"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(hideAll)
                                                     name:@"CKOverlayShouldHide"
                                                   object:nil];

        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ---- 面板切换 ----
- (void)openSettings {
    if (_collapsed) [self toggleCollapse];       // 先展开
    [_settings syncSwitches];
    _settings.hidden = NO;
    // 设置面板比状态面板高，临时放大自身
    CGRect f = self.frame;
    f.size = CGSizeMake(320, 430);
    // 别跑出屏幕
    CGRect scr = [UIScreen mainScreen].bounds;
    if (f.origin.x + f.size.width > scr.size.width) f.origin.x = scr.size.width - f.size.width - 6;
    if (f.origin.y + f.size.height > scr.size.height) f.origin.y = scr.size.height - f.size.height - 6;
    self.frame = f;
    [_settings setFrame:CGRectMake(-1, -1, 320, 430)];
}

- (void)showMain {
    _settings.hidden = YES;
    CGRect f = self.frame;
    f.size = CGSizeMake(280, 268);
    self.frame = f;
    [self layoutSubviews];
    [self refresh];
}

- (void)hideAll {
    [self closeSelf];
}

// ---- 拖动 ----
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint local = [t locationInView:self];
    if (local.y > 28) return;                   // 只有标题条能拖
    _dragStart = [t locationInView:self.superview];
    _frameAtDragStart = self.frame;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (CGPointEqualToPoint(_dragStart, CGPointZero)) return;
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self.superview];
    CGRect f = _frameAtDragStart;
    f.origin.x += (p.x - _dragStart.x);
    f.origin.y += (p.y - _dragStart.y);
    self.frame = f;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragStart = CGPointZero;
}

// ---- 收起 / 展开 ----
- (void)toggleCollapse {
    _collapsed = !_collapsed;
    _settings.hidden = YES;
    if (_collapsed) {
        self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, 136, 30);
        _bodyLabel.hidden = YES;
        _logLabel.hidden  = YES;
        _gearBtn.hidden   = YES;
        _titleLabel.text  = @"CheatKit ▸";
        [_collapseBtn setTitle:@"＋" forState:UIControlStateNormal];
    } else {
        self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, 280, 268);
        _bodyLabel.hidden = NO;
        _logLabel.hidden  = NO;
        _gearBtn.hidden   = NO;
        _titleLabel.text  = @"CheatKit";
        [_collapseBtn setTitle:@"—" forState:UIControlStateNormal];
        [self layoutSubviews];
        [self refresh];
    }
}

- (void)closeSelf {
    [self.timer invalidate];
    self.timer = nil;

    // 延到下一个 runloop 再清引用，避免在本方法栈帧里把自己释放掉
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeFromSuperview];
        if (g_window) {
            g_window.hidden = YES;
            g_window = nil;      // ARC 下只置空，不能 release
        }
        g_view = nil;
        // 注意：这里**不**动 CKFeatureOverlay 开关
        //   ✕ 只是「本次运行先关掉」，重启 App 还会出来
        //   要彻底不显示，去设置面板里把「悬浮窗」开关关掉
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.frame.size.width;
    CGFloat h = self.frame.size.height;
    _titleLabel.frame   = CGRectMake(10, 6, w - 108, 18);
    _gearBtn.frame      = CGRectMake(w - 92, 2, 30, 26);
    _collapseBtn.frame  = CGRectMake(w - 62, 2, 28, 26);
    _closeBtn.frame     = CGRectMake(w - 32, 2, 28, 26);
    _bodyLabel.frame    = CGRectMake(10, 26, w - 20, 116);
    _logLabel.frame     = CGRectMake(10, 146, w - 20, h - 152);
}

// ---- 每秒刷新 ----
- (void)refresh {
    CKStatsSnapshot s = CKStatsGet();

    NSArray *sdks = CKDetectedSDKs();
    NSString *sdkLine = sdks.count ? [sdks componentsJoinedByString:@", "] : @"（未识别）";
    if (sdkLine.length > 42) sdkLine = [[sdkLine substringToIndex:42] stringByAppendingString:@"…"];

    // 开关状态摘要：开的显示首字，简洁
    NSString *flags = [NSString stringWithFormat:@"%@%@%@%@",
        CKFeatureGet(CKFeatureRewardForce) ? @"奖" : @"·",
        CKFeatureGet(CKFeatureEcpmTamper)  ? @"价" : @"·",
        CKFeatureGet(CKFeatureFingerprint) ? @"指" : @"·",
        CKFeatureGet(CKFeatureNetTamper)   ? @"网" : @"·"];

    NSMutableString *b = [NSMutableString string];
    [b appendFormat:@"%@  ×%.1f\n", CKCurrentBundleID(), CKParamGet(CKP_ECPM_MUL)];
    [b appendFormat:@"SDK %@\n", sdkLine];
    [b appendFormat:@"扫描 %d/%d  槽 %d\n", s.knownClasses, s.genericClasses, s.exactSlots];
    [b appendFormat:@"hook 奖%d 播%d 失%d 跳%d\n",
        s.rewardHooks, s.playHooks, s.failHooks, s.skipped];
    [b appendFormat:@"eCPM %d 次   发奖 %d 次\n", s.ecpmHits, s.rewardsFired];
    // ★ 补发诊断行：不查 Console 也能看出卡在哪一步
    //   schedule/attempt/fired：排程了几次 / 尝试投递几次 / 成功几次
    //   三个数一起看就能定位：排程 0 → 播完回调没抓到；
    //   排程>0 但 attempt 0 → 定时器没跑；attempt>0 但 fired 0 → 找不到 delegate
    [b appendFormat:@"补发 排%d 试%d 成%d  %@\n",
        CKStatsScheduleCount(), CKStatsAttemptCount(), s.rewardsFired,
        CKStatsLastRewardReason()];
#if ENABLE_AUTOPILOT
    [b appendFormat:@"%@\n", CKAPStatusLine()];
#endif
    [b appendFormat:@"开关 %@   运行 %.0fs", flags, s.uptime];

    _bodyLabel.text = b;

    // 9 条：自检一次会打 8 行，要能一口气看全
    NSArray<NSString *> *logs = CKRecentLogs(9);
    if (logs.count) _logLabel.text = [logs componentsJoinedByString:@"\n"];
}

@end

// ============================================================
//  安装
// ============================================================
static BOOL g_installed = NO;
static int  g_retryIdx  = 0;

static void ck_overlay_retry(void);   // 前置声明

// 重试间隔（秒）：累计约 15 秒，覆盖冷启动 → 首帧 → 广告 SDK 初始化
static const double kCKOverlayRetryDelay[] = { 0.3, 0.8, 1.5, 2.5, 4.0, 6.0 };
#define CK_OVERLAY_RETRY_MAX (int)(sizeof(kCKOverlayRetryDelay) / sizeof(kCKOverlayRetryDelay[0]))

// ★ 关键：iOS 13+ 用 initWithFrame: 创建的 UIWindow **根本不会显示**
//   （窗口没挂到任何 UIWindowScene 上，系统不绘制）。
//   所以必须拿到 scene；拿不到就重试，绝不退回 initWithFrame:。
static UIWindowScene *ck_find_window_scene(void) {
    Class appCls = objc_getClass("UIApplication");
    if (!appCls) return nil;
    UIApplication *app = (UIApplication *)[appCls performSelector:@selector(sharedApplication)];
    if (!app) return nil;

    UIWindowScene *any = nil;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        // 优先前台活跃的
        if (sc.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)sc;
        if (!any) any = (UIWindowScene *)sc;
    }
    if (any) return any;

    // 再退一步：从 App 已有的 window 上取场景
    // （游戏自己建的 window 一定挂在正确的 scene 上）
    for (UIWindow *w in app.windows) {
        if (w.windowScene) return w.windowScene;
    }
    return nil;
}

// 返回 YES 表示已成功建出窗口
static BOOL ck_overlay_build(void) {
    if (g_window || g_view) return YES;
    if (!g_installed) return NO;

    Class appCls = objc_getClass("UIApplication");
    if (!appCls) {
        CKLog(@"[浮窗] 没有 UIApplication（Extension / 守护进程），跳过");
        return NO;
    }
    UIApplication *app = (UIApplication *)[appCls performSelector:@selector(sharedApplication)];
    if (!app) {
        CKLog(@"[浮窗] sharedApplication 为 nil，跳过");
        return NO;
    }

    UIWindowScene *scene = ck_find_window_scene();

    // ------------------------------------------------------------
    //  路线 A：拿到 scene → 建独立 window（首选，最干净）
    // ------------------------------------------------------------
    if (scene) {
        CGRect screen = scene.coordinateSpace.bounds;
        if (screen.size.width < 100 || screen.size.height < 100) {
            screen = [UIScreen mainScreen].bounds;
        }
        CGFloat w = 280.0, h = 268.0;
        CGRect frame = CGRectMake(screen.size.width - w - 12, 64, w, h);

        g_window = [[CKOverlayWindow alloc] initWithWindowScene:scene];
        g_window.frame = screen;
        g_window.backgroundColor = [UIColor clearColor];
        g_window.opaque = NO;
        g_window.windowLevel = UIWindowLevelAlert + 100;
        g_window.hidden = NO;
        g_window.userInteractionEnabled = YES;

        // ★ 必须有 rootViewController，否则「窗口存在但不绘制」
        //   它的 view 关了 userInteractionEnabled，不会吞点击，穿透仍然生效
        g_window.rootViewController = [[CKOverlayRootVC alloc] init];

        g_view = [[CKOverlayView alloc] initWithFrame:frame];
        g_view.autoresizingMask = UIViewAutoresizingNone;
        [g_window addSubview:g_view];
        [g_window bringSubviewToFront:g_view];

        // 不用 makeKeyAndVisible：虽然 canBecomeKeyWindow=NO 挡得住，
        // 但某些 App 会因为 keyWindow 变化重建键盘。hidden=NO 已足够。
        g_window.hidden = NO;

        __weak CKOverlayView *weakView = g_view;
        g_view.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       repeats:YES
                                                         block:^(NSTimer *t) {
            [weakView refresh];
        }];

        CKLog(@"[浮窗] 已显示（独立窗口）level=%.0f scene=%s",
              g_window.windowLevel, class_getName([scene class]));
        return YES;
    }

    // ------------------------------------------------------------
    //  路线 B：没有 scene（App 还没建好 / 非标准）→ 直接挂到它自己的 window 上
    //          这条兜底几乎必中，因为此时 App 一定已经有 window 了
    // ------------------------------------------------------------
    UIWindow *host = nil;
    for (UIWindow *w in app.windows) {
        if (w.hidden) continue;
        if (w.windowLevel > 100) continue;        // 跳过键盘之类的高层窗口
        host = w;
        if (w.isKeyWindow) break;
    }
    if (!host) {
        CKLog(@"[浮窗] 还没有可用的 UIWindowScene / UIWindow（第 %d 次尝试）",
              g_retryIdx + 1);
        return NO;
    }

    CGRect b = host.bounds;
    if (b.size.width < 100 || b.size.height < 100) b = [UIScreen mainScreen].bounds;
    CGFloat w = 280.0, h = 268.0;
    CGRect frame = CGRectMake(b.size.width - w - 12, 64, w, h);

    g_view = [[CKOverlayView alloc] initWithFrame:frame];
    g_view.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleBottomMargin;
    [host addSubview:g_view];
    [host bringSubviewToFront:g_view];

    __weak CKOverlayView *weakView = g_view;
    __weak UIWindow     *weakHost = host;
    g_view.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   repeats:YES
                                                     block:^(NSTimer *t) {
        // 宿主 window 常会自己 addSubview 把面板压下去，每秒重新置顶一次
        if (weakHost && weakView) [weakHost bringSubviewToFront:weakView];
        [weakView refresh];
    }];

    CKLog(@"[浮窗] 已显示（挂到宿主 window，无 scene 兜底）");
    return YES;
}

static void ck_overlay_retry(void) {
    if (g_view) return;            // 路线 B 里 g_window 是 nil，只有 g_view，别漏判
    if (g_retryIdx >= CK_OVERLAY_RETRY_MAX) {
        CKLog(@"[浮窗] 重试 %d 次仍失败。查：① 该 App 是否不用 UIWindowScene；"
              @"② 注入是否早于 App 启动完成；③ 游戏是否在频繁切换场景",
              CK_OVERLAY_RETRY_MAX);
        return;
    }
    double d = kCKOverlayRetryDelay[g_retryIdx++];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!ck_overlay_build()) ck_overlay_retry();
    });
}

void CKInstallOverlay(void) {
    if (g_installed) return;

    // ★ 这里刻意不再「开关关了就完全不装」。
    //   原因：浮窗本身就是唯一的控制面板，一旦彻底不装，用户再也没法把开关打开，
    //   只能卸载重装。之前版本 ✕ 会把 feat.overlay 写进 NSUserDefaults，
    //   结果就是「装好了但永远没有浮窗」这个死锁。
    //   现在改成：开关关掉只影响「启动时是否展开」，面板一定存在。
    BOOL expanded = CKFeatureGet(CKFeatureOverlay);
    g_installed = YES;
    g_retryIdx = 0;

    void (^build)(void) = ^{
        if (!ck_overlay_build()) { ck_overlay_retry(); return; }
        if (!expanded && g_view) {
            [g_view toggleCollapse];        // 收成小条，点 ＋ 可展开
            CKLog(@"[浮窗] 以收起状态启动（设置里打开「悬浮窗」可默认展开）");
        }
    };

    if ([NSThread isMainThread]) build();
    else dispatch_async(dispatch_get_main_queue(), build);

    // 场景后到的情况：App 切到前台时再试一次（幂等）
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (g_window && g_view) { [g_view refresh]; return; }
        g_retryIdx = 0;
        if (!ck_overlay_build()) ck_overlay_retry();
    }];
}

void CKRefreshOverlay(void) {
    if (!g_view) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view refresh]; });
}
