//
//  Common/SubstrateRT.h —— 运行时解析 Substrate / ElleKit（不产生符号依赖）
//
//  ★ 为什么必须有这一层：
//    build_dylib.sh 用 -undefined dynamic_lookup 链接，任何对 MSHookFunction /
//    MSHookMessageEx 的【直接调用】都会在二进制里留下未定义符号。
//    dyld 在加载 dylib 时就要解析这些符号：
//      有 Substrate/ElleKit  → 正常
//      没有（TrollStore 裸注入）→ 立刻 abort
//                                 "Symbol not found: _MSHookFunction"
//                               连 constructor 都跑不到，表现为「注入即闪退」
//
//    所以这里全部改成 dlsym 取函数指针：
//      - 取到了   → 走 inline hook
//      - 取不到   → ObjC 方法降级用 method_setImplementation，C 函数 hook 跳过
//    二进制里不再有任何 Substrate 符号引用，加载阶段永远不会因它崩。
//

#ifndef SUBSTRATE_RT_H
#define SUBSTRATE_RT_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

// 是否找到了 Substrate / ElleKit（inline hook 能力）
BOOL CKHasSubstrate(void);

// C 函数 inline hook。
//   成功返回 YES；无 Substrate 或目标为空返回 NO（调用方继续走降级路径）。
BOOL CKInlineHook(void *symbol, void *replacement, void **origOut);

// ObjC 方法替换（实例方法）。
//   优先走 MSHookMessageEx（保留 super 链）；没有 Substrate 时降级 method_setImplementation。
BOOL CKHookInstanceMethod(Class cls, SEL sel, IMP imp, IMP *origOut);

// ObjC 方法替换（类方法）。
BOOL CKHookClassMethod(Class cls, SEL sel, IMP imp, IMP *origOut);

// 打印当前能力（有/无 Substrate、各个符号是否解析成功）
void CKDumpSubstrateStatus(void);

#ifdef __cplusplus
}
#endif

#endif // SUBSTRATE_RT_H
