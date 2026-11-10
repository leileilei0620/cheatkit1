//
//  Modules/AdEngine.h —— 通用广告引擎（不绑定任何单一 SDK）
//
//  设计目标：装到任何接了广告的 App 上都能工作
//   1) SDK 指纹表：类名前缀 ≥3 字符匹配，覆盖 17 家主流广告 SDK
//   2) 形状 hook：解析 method type encoding，按参数形状选 trampoline
//   3) 主动发奖：检测到广告开始播放后，延时向 delegate 投递成功回调
//
//  与 HookReward 的分工：
//   AdEngine   —— 自动/概率命中，负责未知与混淆过的 SDK
//   HookReward —— 写死 SEL 表，负责已知 SDK 的确定性入口
//

#ifndef ADENGINE_H
#define ADENGINE_H
#import <Foundation/Foundation.h>

// 安装通用引擎（幂等，可重复调用）
void CKInstallAdEngine(void);

// 打印本进程里识别到的所有广告 SDK 及其回调方法（调试用）
void CKDumpAdSDKs(void);

// 已识别 SDK 名单，如 @"穿山甲/Pangle"、@"优量汇/GDT"
NSArray<NSString *> *CKDetectedSDKs(void);

// 主动触发一次发奖（给已有 session 用；一般不用手调）
void CKFireRewardForAllSessions(void);

// ---- 供 HookReward 复用的底层能力 ----

// SEL 是否像奖励/验证回调
BOOL CKSelectorLooksLikeReward(const char *sel);

// 立即（delaySec 后）向 ad 对象的 delegate 投递奖励回调，内部做去重
void CKTryScheduleReward(id adObj, double delaySec);

// 直接投递一次，不管去重（去重标记由调用方负责）
BOOL CKInvokeDelegateReward(id adObj);

#endif
