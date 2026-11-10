//
//  Common/Rewriter.m —— 数值伪造 + 递归对象改写
//

#import "Rewriter.h"
#import "Log.h"
#import "FeatureFlags.h"
#import "../Config.h"

// ============================================================
//  键名表
// ============================================================
NSArray<NSString *> *CKPriceKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            // 千次展示价
            @"ecpm", @"e_cpm", @"ecpmvalue", @"ecpm_price",
            // 收益
            @"revenue", @"income", @"earn", @"earnings", @"profit",
            @"payout", @"settle_price", @"settleprice", @"settleamount",
            @"estimated_earnings", @"estimatedearnings", @"value_micros",
            // 竞价
            @"bid_price", @"bidprice", @"bidfloor", @"bid_floor",
            @"cpm", @"win_price", @"winprice", @"second_price",
            @"price_cny", @"price_usd"
        ];
    });
    return keys;
}

NSArray<NSString *> *CKVerifyKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"valid", @"isvalid", @"is_valid", @"verify", @"verified",
                 @"isverified", @"is_verified", @"verified_status",
                 @"reward_valid", @"rewardvalid", @"effective", @"iseffective"];
    });
    return keys;
}

NSArray<NSString *> *CKPriceKeyBlacklist(void) {
    // 命中这些的键即使包含 price 也不改，避免破坏商品/订单字段
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"order", @"sku", @"goods", @"product", @"cart",
                 @"coupon", @"discount", @"shipping", @"tax", @"total",
                 @"balance", @"refund", @"unit_price", @"list_price"];
    });
    return keys;
}

// ============================================================
//  策略
// ============================================================
static BOOL   g_absMode = YES;
static double g_lo = 28.0, g_hi = 46.0, g_mul = 3.2;

void CKSetEcpmPolicy(BOOL absolute, double lo, double hi, double multiplier) {
    g_absMode = absolute;
    if (lo > 0 && hi > lo) { g_lo = lo; g_hi = hi; }
    if (multiplier > 0) g_mul = multiplier;
}

// 从运行时参数表同步（浮窗里拖滑块后调这个，立刻生效）
void CKSyncEcpmPolicyFromParams(void) {
    CKSetEcpmPolicy(CKParamGet(CKP_ECPM_MODE) >= 0.5,
                    CKParamGet(CKP_ECPM_MIN),
                    CKParamGet(CKP_ECPM_MAX),
                    CKParamGet(CKP_ECPM_MUL));
}

double CKFakeEcpm(void) {
    CKSyncEcpmPolicyFromParams();          // 每次取都读最新值，滑块改了立刻反映
    if (!g_absMode) return 0;              // 倍数模式下由调用方决定
    if (g_hi <= g_lo) return g_lo;
    double r = (double)arc4random_uniform(100000) / 100000.0;
    return g_lo + r * (g_hi - g_lo);
}

double CKInflateDouble(double v) {
    CKSyncEcpmPolicyFromParams();
    if (g_absMode) {
        // 绝对值模式：直接给一个落在区间内的值（千次展示价口径）
        return CKFakeEcpm();
    }
    // 倍数模式：真实值放大；真实值缺失时退回伪造值
    if (v <= 0) return CKFakeEcpm() / 1000.0;
    return v * g_mul;
}

NSInteger CKInflateInteger(NSInteger v) {
    CKSyncEcpmPolicyFromParams();
    if (g_absMode) return (NSInteger)(CKFakeEcpm() * 100.0);   // 常见单位：分
    if (v <= 0) return (NSInteger)(CKFakeEcpm() * 100.0);
    return (NSInteger)((double)v * g_mul);
}

// ============================================================
//  命中统计
// ============================================================
static NSUInteger g_hits = 0;
NSUInteger CKRewriteHitCount(void) { return g_hits; }
void CKResetRewriteHitCount(void) { g_hits = 0; }

// ============================================================
//  单键判断
// ============================================================
static BOOL ck_keyMatchesAny(NSString *key, NSArray<NSString *> *list) {
    NSString *low = [key lowercaseString];
    for (NSString *k in list) {
        if ([low containsString:k]) return YES;
    }
    return NO;
}

static BOOL ck_isPriceKey(NSString *key) {
    NSString *low = [key lowercaseString];
    if (ck_keyMatchesAny(low, CKPriceKeyBlacklist())) return NO;
    return ck_keyMatchesAny(low, CKPriceKeys());
}

static BOOL ck_isVerifyKey(NSString *key) {
    return ck_keyMatchesAny([key lowercaseString], CKVerifyKeys());
}

// ============================================================
//  标量改写
// ============================================================
id CKRewriteScalarForKey(NSString *key, id value) {
    if (![key isKindOfClass:[NSString class]] || !value) return value;

    // 1) 验证类 → 恒真
    if (ck_isVerifyKey(key)) {
        if ([value isKindOfClass:[NSNumber class]]) {
            NSNumber *n = (NSNumber *)value;
            const char *t = [n objCType];
            if (t && (t[0] == 'c' || t[0] == 'B')) {
                g_hits++;
                return @YES;
            }
            if ([n boolValue] == NO || [n integerValue] == 0) {
                g_hits++;
                return @1;
            }
            return value;
        }
        if ([value isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)value lowercaseString];
            if ([s isEqualToString:@"0"] || [s isEqualToString:@"false"] ||
                [s isEqualToString:@"no"] || [s isEqualToString:@"fail"] ||
                [s isEqualToString:@"failed"] || [s isEqualToString:@"invalid"]) {
                g_hits++;
                return @"1";
            }
        }
        return value;
    }

    // 2) 价格类 → 放大/伪造
    if (ck_isPriceKey(key)) {
        if ([value isKindOfClass:[NSNumber class]]) {
            NSNumber *n = (NSNumber *)value;
            const char *t = [n objCType] ?: "d";
            if (t[0] == 'd' || t[0] == 'f') {
                double nv = CKInflateDouble([n doubleValue]);
                g_hits++;
                CKLog(@"[改写] %@: %@ -> %.4f", key, n, nv);
                return @(nv);
            }
            NSInteger nv = CKInflateInteger([n integerValue]);
            g_hits++;
            CKLog(@"[改写] %@: %@ -> %ld", key, n, (long)nv);
            return @(nv);
        }
        if ([value isKindOfClass:[NSDecimalNumber class]]) {
            double nv = CKInflateDouble([(NSDecimalNumber *)value doubleValue]);
            g_hits++;
            return [NSDecimalNumber decimalNumberWithString:
                    [NSString stringWithFormat:@"%.4f", nv]];
        }
        if ([value isKindOfClass:[NSString class]]) {
            double real = [(NSString *)value doubleValue];
            if (real != 0 || [(NSString *)value isEqualToString:@"0"]) {
                double nv = CKInflateDouble(real);
                g_hits++;
                return [NSString stringWithFormat:@"%.4f", nv];
            }
        }
    }
    return value;
}

// ============================================================
//  递归改写
// ============================================================
id CKRewriteObject(id obj, int depth) {
    if (!obj || depth > 8) return obj;

    // ---- 字典 ----
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)obj count]];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            id nv = CKRewriteScalarForKey([k isKindOfClass:[NSString class]] ? k : nil, v);
            if (nv == v) nv = CKRewriteObject(v, depth + 1);   // 容器继续深入
            out[k] = nv ?: [NSNull null];
        }];
        return out;
    }

    // ---- 数组 ----
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *src = (NSArray *)obj;
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:src.count];
        for (id v in src) {
            id nv = CKRewriteObject(v, depth + 1);
            [out addObject:nv ?: [NSNull null]];
        }
        return out;
    }

    return obj;
}
