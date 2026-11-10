//
//  Common/Fingerprint.h
//  设备指纹随机化：IDFA / IDFV / AndroidID 等价物 / Keychain 持久 ID
//

#ifndef FINGERPRINT_H
#define FINGERPRINT_H
#import <Foundation/Foundation.h>

@interface CKFingerprint : NSObject
+ (instancetype)shared;

// 当前（伪造的）标识
- (NSString *)idfa;
- (NSString *)idfv;
- (NSString *)installId;

// 换一套
- (void)rotate;

// 拟真计时
- (NSTimeInterval)jitteredWatchTime;
- (void)sleepClickDelay;

@end

// 安装
void CKInstallFingerprintHooks(void);
#endif
