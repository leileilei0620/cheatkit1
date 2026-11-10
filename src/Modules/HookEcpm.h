//
//  Modules/HookEcpm.h
//

#ifndef HOOKECPM_H
#define HOOKECPM_H
#import <Foundation/Foundation.h>

// 安装 eCPM / 收益篡改（价格模型层 + 序列化层 + 请求体层）
void CKInstallEcpmHooks(void);

// 兼容旧调用名
double CKInflateRevenue(double real);

#endif
