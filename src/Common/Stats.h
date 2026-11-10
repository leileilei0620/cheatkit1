//
//  Common/Stats.h —— 运行期统计（浮窗数据源）
//
//  各模块只负责往这里写数字，浮窗只负责读。
//  这样浮窗和业务逻辑完全解耦：关掉浮窗不影响任何 hook。
//
//  线程模型：
//    - 写入可能发生在任意线程（hook 回调），用简单 int 递增
//    - arm64 上对齐的 32 位读写是原子的，不需要加锁
//    - 读取方（浮窗，主线程）只是展示，允许短暂偏旧
//

#ifndef CK_STATS_H
#define CK_STATS_H

#import <Foundation/Foundation.h>

typedef struct {
    // 广告引擎扫描结果
    int knownClasses;      // 命中 SDK 指纹表的类
    int genericClasses;    // 走词根兜底的类
    int rewardHooks;       // 装上的奖励类回调
    int playHooks;         // 装上的播放类回调
    int failHooks;         // 装上的失败类回调
    int skipped;           // 形状不支持 / 重复 / 槽位满

    // 精确规则（HookReward）
    int exactSlots;

    // 改写与发奖
    int ecpmHits;          // CKRewriteObject 命中次数
    int rewardsFired;      // 成功投递的奖励回调次数

    // 运行时长（秒）
    double uptime;
} CKStatsSnapshot;

void CKStatsMarkStart(void);
void CKStatsSetAdScan(int known, int generic);
void CKStatsSetHookResult(int reward, int play, int fail, int skipped);
void CKStatsSetExactSlots(int n);
void CKStatsCountRewardFired(void);
CKStatsSnapshot CKStatsGet(void);

// ---- 补发链诊断（浮窗「补发 排/试/成」那一行） ----
//   schedule：ck_scheduleReward 被调用几次（= 抓到几次播完回调）
//   attempt ：真正执行投递几次（= 定时器跑起来几次）
//   reason   ：最后一次失败的原因，成功则是「成功」
// 这三个数组合起来能直接定位断点，不用翻 Console。
void   CKStatsCountSchedule(void);
void   CKStatsCountAttempt(void);
void   CKStatsSetRewardReason(NSString *reason);
int    CKStatsScheduleCount(void);
int    CKStatsAttemptCount(void);
NSString *CKStatsLastRewardReason(void);

#endif
