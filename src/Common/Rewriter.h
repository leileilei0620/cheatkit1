//
//  Common/Rewriter.h —— 数值伪造 + 递归对象改写（不依赖任何 SDK）
//

#ifndef REWRITER_H
#define REWRITER_H
#import <Foundation/Foundation.h>

// ---------- 价格类键名（不区分大小写，包含匹配） ----------
NSArray<NSString *> *CKPriceKeys(void);
// ---------- 验证类键名 ----------
NSArray<NSString *> *CKVerifyKeys(void);
// 命中即跳过改写的键（防止破坏业务字段）
NSArray<NSString *> *CKPriceKeyBlacklist(void);

// ---------- eCPM 策略 ----------
void   CKSetEcpmPolicy(BOOL absolute, double lo, double hi, double multiplier);
// 从运行时参数表（浮窗滑块）同步策略，取数时会自动调
void   CKSyncEcpmPolicyFromParams(void);
double CKFakeEcpm(void);            // 按策略生成一个 eCPM

// ---------- 数值放大 ----------
double   CKInflateDouble(double v);
NSInteger CKInflateInteger(NSInteger v);
id       CKInflateValue(id v);      // 支持 NSNumber / NSString / NSDecimalNumber

// ---------- 递归改写 ----------
// 输入不可变容器会自动 mutableCopy 成新对象返回；标量原样返回
id CKRewriteObject(id obj, int depth);
// 单键改写（在字典遍历时用）
id CKRewriteScalarForKey(NSString *key, id value);

// 命中统计，方便日志
NSUInteger CKRewriteHitCount(void);
void       CKResetRewriteHitCount(void);

#endif
