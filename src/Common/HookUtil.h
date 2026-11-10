//
//  Common/HookUtil.h —— 纯 runtime 的 hook 工具（.m 文件里也能用）
//  不依赖 substrate 宏，方便在普通 .m 里做 swizzle
//

#ifndef HOOKUTIL_H
#define HOOKUTIL_H
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

// 类方法替换，origOut 回传原实现（可为 NULL）
static inline BOOL CKSwizzleClassMethod(const char *clsName,
                                       SEL sel,
                                       IMP newImp,
                                       IMP *origOut) {
    Class cls = objc_getClass(clsName);
    if (!cls) return NO;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

static inline BOOL CKSwizzleInstanceMethod(const char *clsName,
                                           SEL sel,
                                           IMP newImp,
                                           IMP *origOut) {
    Class cls = objc_getClass(clsName);
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

// 类是否存在
static inline BOOL CKClassExists(const char *name) {
    return objc_getClass(name) != nil;
}

// 遍历某个类的所有方法名，用于自动探测 hook 点
static inline NSArray<NSString *> *CKListMethods(const char *clsName, BOOL classMethods) {
    Class cls = objc_getClass(clsName);
    if (!cls) return @[];
    NSMutableArray *out = [NSMutableArray array];
    unsigned int count = 0;
    Method *list = classMethods ? class_copyMethodList(object_getClass(cls), &count)
                                : class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        [out addObject:NSStringFromSelector(method_getName(list[i]))];
    }
    if (list) free(list);
    return out;
}

#endif
