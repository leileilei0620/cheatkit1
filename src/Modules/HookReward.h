//
//  Modules/HookReward.h
//

#ifndef HOOKREWARD_H
#define HOOKREWARD_H
#import <Foundation/Foundation.h>

// 安装全部激励回调 hook（自动探测已加载的 SDK）
void CKInstallRewardHooks(void);

// 单个 SDK
void CKInstallPangleReward(void);   // 穿山甲 CSJ / Pangle
void CKInstallGDTReward(void);      // 优量汇 GDT
void CKInstallAdMobReward(void);    // Google AdMob
void CKInstallAppLovinReward(void); // AppLovin
void CKInstallIronSourceReward(void);

// 通用兜底：扫描所有含 reward 的类并打印签名
void CKDumpRewardClasses(void);

#endif
