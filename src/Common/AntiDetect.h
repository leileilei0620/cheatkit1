//
//  Common/AntiDetect.h
//  越狱检测 / 反调试 / dyld 镜像隐藏
//

#ifndef ANTIDETECT_H
#define ANTIDETECT_H
#import <Foundation/Foundation.h>

// 安装全部对抗（越狱检测 + 反调试 + 镜像隐藏）
void CKInstallAntiDetect(void);

// 单独控制
void CKInstallJailbreakBypass(void);
void CKInstallAntiDebugBypass(void);
void CKInstallDyldHide(void);

#endif
