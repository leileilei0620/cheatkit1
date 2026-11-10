//
//  vendor/substrate.h —— 最小 Substrate / ElleKit 兼容声明
//
//  为什么自带这份头文件：
//    1. Theos 的 iPhoneOS SDK 里没有 substrate.h，GitHub Actions 上编译会直接报
//       'substrate.h' file not found
//    2. 我们不想在 CI 里额外下载 libsubstrate.dylib 去链接
//
//  做法：
//    - 编译期只声明原型，配合 -undefined dynamic_lookup，链接阶段不要求符号存在
//    - 运行期由越狱环境的 Substrate / ElleKit 提供实现
//      （Dopamine 自带 ElleKit，ElleKit 提供 MSHookFunction 等 Substrate 兼容符号）
//
//  如果你的环境完全没有 Substrate 兼容层（例如纯 TrollStore 无注入框架），
//  CheatKit 会在第一次 hook 时因符号缺失而跳过，不会崩。
//

#ifndef CK_VENDOR_SUBSTRATE_H
#define CK_VENDOR_SUBSTRATE_H

#include <objc/runtime.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 函数指针修补（Inline Hook）----
// symbol : 目标函数地址
// replace: 替换实现
// result : 回传原实现（可为 NULL）
void MSHookFunction(void *symbol, void *replace, void **result);

// ---- Objective-C 方法替换 ----
// 等价于 method_setImplementation，但会处理 super 调用链
void MSHookMessageEx(Class _class, SEL sel, IMP imp, IMP *result);

// ---- 符号与镜像查询 ----
void *MSFindSymbol(void *image, const char *name);
void *MSGetImageByName(const char *file);

// ---- 部分新版本 ElleKit 提供的别名，声明一下方便可选使用 ----
void *MSHookMemory(void *target, const void *data, size_t size);

#ifdef __cplusplus
}
#endif

#endif // CK_VENDOR_SUBSTRATE_H
