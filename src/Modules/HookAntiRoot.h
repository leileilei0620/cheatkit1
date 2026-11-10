//
//  Modules/HookAntiRoot.h
//  App 自有风控的通用对抗：签名校验 / 环境探针 / 埋点上报
//

#ifndef HOOKANTIROOT_H
#define HOOKANTIROOT_H
#import <Foundation/Foundation.h>

// 安装探针 hook + bundle 完整性对抗
void CKInstallAntiRootHooks(void);

// 固定签名返回值（可选）。传 nil 恢复真实值
void CKPinSignature(NSString *sig);

#endif
