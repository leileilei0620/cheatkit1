//
//  Common/Overlay.h —— 进程内悬浮窗
//
//  作用：把「模块到底有没有跑」这件事变成肉眼可见的数字。
//        没有浮窗的时候只能 ssh 看 log stream，很不方便。
//
//  显示内容：
//    1. Bundle ID + 运行时长      → 证明 dylib 注入成功
//    2. 识别到的广告 SDK 名单      → 证明 AdEngine 扫描跑过了
//    3. hook 数量（奖励/播放/失败） → 证明真的装上了
//    4. eCPM 改写命中 / 发奖次数   → 证明运行时真的在改数据
//    5. 最近 6 条日志              → 最直接的执行证据
//
//  交互：
//    - 拖动标题条移动
//    - 「—」收起成小圆点，「＋」展开
//    - 「✕」彻底隐藏（本进程内不再出现）
//

#ifndef CK_OVERLAY_H
#define CK_OVERLAY_H

#import <Foundation/Foundation.h>

// 安装浮窗（幂等；必须在主线程调用，内部会自动切主线程）
void CKInstallOverlay(void);

// 手动刷新一次（一般不用调，浮窗自己每秒刷）
void CKRefreshOverlay(void);

// 跑一次自检：把注入/hook/SDK/补发链的诊断打到日志区
// 自动调用：注入后 8 秒跑一次（用户还没点广告时就能看出装没装上）
void CKRunSelfCheck(void);

#endif
