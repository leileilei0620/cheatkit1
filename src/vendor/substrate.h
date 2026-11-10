//
//  vendor/substrate.h —— 【已废弃】仅作说明，不再声明任何函数
//
//  ★ 为什么清空：
//    以前这里声明了 MSHookFunction / MSHookMessageEx 等函数原型，配合
//    build_dylib.sh 的 -undefined dynamic_lookup，任何【直接调用】都会在
//    二进制里留下未定义符号 _MSHookFunction。
//
//    dyld 在【加载 dylib 的阶段】就要解析这些符号。TrollStore / TrollFools
//    这类没有 Substrate / ElleKit 的环境解析失败，直接：
//        dyld: Symbol not found: _MSHookFunction
//        Referenced from: .../CheatKit.dylib
//        Expected in: flat namespace
//    进程立刻 abort —— 连 constructor 都跑不到，表现为「注入即闪退」。
//
//  ★ 现在怎么做：
//    全部改用 src/Common/SubstrateRT.h 提供的运行时解析：
//        CKHasSubstrate()          有没有 inline hook 能力
//        CKInlineHook(...)         C 函数 hook，没有就返回 NO
//        CKHookInstanceMethod(...) ObjC 方法，自动降级 method_setImplementation
//
//    这样二进制里零 Substrate 符号，加载阶段永远安全。
//
//  ★ 这个文件保留只为兼容历史 #import，新代码请直接用 SubstrateRT.h。
//

#ifndef CK_VENDOR_SUBSTRATE_H
#define CK_VENDOR_SUBSTRATE_H

#pragma message("vendor/substrate.h 已废弃，请改用 Common/SubstrateRT.h")

#endif // CK_VENDOR_SUBSTRATE_H
