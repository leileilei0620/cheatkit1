//
//  Common/Fingerprint.m
//

#import "Fingerprint.h"
#import <stdint.h>
#import "Log.h"
#import "HookUtil.h"
#import "FeatureFlags.h"   // 运行时开关 / 参数
#import <AdSupport/AdSupport.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <sys/sysctl.h>

#define CK_FP_KEYCHAIN_SERVICE @"com.ck.installid"

@interface CKFingerprint () {
    NSString *_idfa;
    NSString *_idfv;
    NSString *_installId;
    NSInteger _sessionCount;
}
@end

@implementation CKFingerprint

+ (instancetype)shared {
    static CKFingerprint *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [CKFingerprint new]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        // 运行时参数：启动换指纹（0=保留上次的，1=每次启动换新）
        BOOL rotate = CKParamGet(CKP_FP_ROTATE) >= 0.5;
        NSString *stored = [self _keychainGet];
        if (!stored || rotate) {
            _installId = [self _genUUID];
            [self _keychainSet:_installId];
        } else {
            _installId = stored;
        }
        _idfa = [self _genUUID];
        _idfv = [self _genUUID];
        _sessionCount = 0;
        CKLog(@"指纹初始化 installId=%@", _installId);
    }
    return self;
}

- (NSString *)_genUUID {
    return [[NSUUID UUID] UUIDString];
}

#pragma mark - 标识

- (NSString *)idfa { return _idfa ?: (_idfa = [self _genUUID]); }
- (NSString *)idfv { return _idfv ?: (_idfv = [self _genUUID]); }
- (NSString *)installId { return _installId ?: (_installId = [self _genUUID]); }

- (void)rotate {
    _idfa = [self _genUUID];
    _idfv = [self _genUUID];
    _installId = [self _genUUID];
    [self _keychainSet:_installId];
    CKLog(@"指纹已轮转 idfa=%@", _idfa);
}

#pragma mark - Keychain（App 常用它做持久追踪）

- (NSString *)_keychainGet {
    NSMutableDictionary *q = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CK_FP_KEYCHAIN_SERVICE,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    } mutableCopy];
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    if (st != errSecSuccess || !out) return nil;
    NSString *s = [[NSString alloc] initWithData:(__bridge_transfer NSData *)out
                                        encoding:NSUTF8StringEncoding];
    return s;
}

- (void)_keychainSet:(NSString *)value {
    NSDictionary *base = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CK_FP_KEYCHAIN_SERVICE,
    };
    SecItemDelete((__bridge CFDictionaryRef)base);

    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    add[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

#pragma mark - 拟真

// 数值全部走运行时参数表，浮窗里拖滑块立刻生效
- (NSTimeInterval)jitteredWatchTime {
    double lo = CKParamGet(CKP_WATCH_MIN);
    double hi = CKParamGet(CKP_WATCH_MAX);
    if (hi <= lo) hi = lo + 1.0;
    return lo + ((double)arc4random_uniform(10000) / 10000.0) * (hi - lo);
}

- (void)sleepClickDelay {
    double lo = CKParamGet(CKP_CLICK_MIN);
    double hi = CKParamGet(CKP_CLICK_MAX);
    if (hi <= lo) hi = lo + 1.0;
    uint32_t span = (uint32_t)(hi - lo);
    uint32_t ms = (uint32_t)lo + (span ? arc4random_uniform(span) : 0);
    usleep(ms * 1000);
}

@end

#pragma mark - Hooks

static IMP g_origAdvertisingId = NULL;
static IMP g_origTrackingEnabled = NULL;
static IMP g_origIdfv = NULL;

// ★ 开关在 getter 里判定：关掉指纹随机 → 直接调原实现，
//   宿主拿到真实 IDFA/IDFV，跟没装插件一样。
static inline BOOL ck_fpOn(void) { return CKFeatureGet(CKFeatureFingerprint); }

static id ck_advertisingIdentifier(id self, SEL _cmd) {
    if (!ck_fpOn() && g_origAdvertisingId) {
        return ((id (*)(id, SEL))g_origAdvertisingId)(self, _cmd);
    }
    NSString *s = [[CKFingerprint shared] idfa];
    return [[NSUUID alloc] initWithUUIDString:s];
}

static BOOL ck_isAdvertisingTrackingEnabled(id self, SEL _cmd) {
    if (!ck_fpOn() && g_origTrackingEnabled) {
        return ((BOOL (*)(id, SEL))g_origTrackingEnabled)(self, _cmd);
    }
    return YES;
}

static id ck_identifierForVendor(id self, SEL _cmd) {
    if (!ck_fpOn() && g_origIdfv) {
        return ((id (*)(id, SEL))g_origIdfv)(self, _cmd);
    }
    NSString *s = [[CKFingerprint shared] idfv];
    return [[NSUUID alloc] initWithUUIDString:s];
}

void CKInstallFingerprintHooks(void) {
#if ENABLE_FINGERPRINT
    if (CKClassExists("ASIdentifierManager")) {
        CKSwizzleInstanceMethod("ASIdentifierManager",
                               @selector(advertisingIdentifier),
                               (IMP)ck_advertisingIdentifier, &g_origAdvertisingId);
        CKSwizzleInstanceMethod("ASIdentifierManager",
                               @selector(isAdvertisingTrackingEnabled),
                               (IMP)ck_isAdvertisingTrackingEnabled, &g_origTrackingEnabled);
        CKLog(@"IDFA hook 安装完成");
    }

    CKSwizzleInstanceMethod("UIDevice", @selector(identifierForVendor),
                            (IMP)ck_identifierForVendor, &g_origIdfv);
    CKLog(@"IDFV hook 安装完成");
#endif
}
