//
//  Common/Log.h
//

#ifndef LOG_H
#define LOG_H
#import <Foundation/Foundation.h>
#import "../Config.h"

void CKLog(NSString *fmt, ...);

// 只在目标进程里生效的判断
BOOL CKIsTargetProcess(void);
// 当前 bundle id
NSString *CKCurrentBundleID(void);

// 最近 N 条日志（给浮窗用；新的在前）。N 超过缓冲容量时返回全部
NSArray<NSString *> *CKRecentLogs(NSUInteger n);

#endif
