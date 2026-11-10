//
//  vendor/ck_compat.h —— 平台兼容兜底层
//
//  为什么需要它：
//    strcasestr() 不是 C 标准库函数，是 BSD/GNU 扩展。
//    Darwin 的 <string.h> 只在 __DARWIN_C_LEVEL >= __DARWIN_C_FULL 时才声明它，
//    Linux 的 <string.h> 走 _GNU_SOURCE 分支。
//    在 GitHub Actions 的 Ubuntu + iPhoneOS SDK 交叉编译下，
//    宏环境两边都不完全对，一旦声明不可见，
//    clang 就会报 "call to undeclared function 'strcasestr'"（C99 起是 error 不是 warning）。
//
//  所以这里自己实现一份，函数名加 ck_ 前缀，绝不与系统符号冲突。
//

#ifndef CK_COMPAT_H
#define CK_COMPAT_H

#include <stddef.h>
#include <string.h>

// 大小写无关的子串查找（等价 strcasestr）
// 返回 haystack 中首个匹配位置，找不到返回 NULL
static inline char *ck_strcasestr(const char *haystack, const char *needle) {
    if (!haystack || !needle) return NULL;
    if (!*needle) return (char *)haystack;

    size_t nlen = strlen(needle);
    for (const char *p = haystack; *p; p++) {
        size_t i = 0;
        while (i < nlen) {
            unsigned char a = (unsigned char)p[i];
            unsigned char b = (unsigned char)needle[i];
            if (!a) return NULL;                       // haystack 提前结束
            if (a >= 'A' && a <= 'Z') a = (unsigned char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (unsigned char)(b - 'A' + 'a');
            if (a != b) break;
            i++;
        }
        if (i == nlen) return (char *)p;               // 整段命中
    }
    return NULL;
}

// 大小写无关的前缀比较（等价 strncasecmp(a, b, n) == 0）
static inline int ck_strncasecmp_eq(const char *a, const char *b, size_t n) {
    if (!a || !b) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = (unsigned char)a[i];
        unsigned char cb = (unsigned char)b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb - 'A' + 'a');
        if (ca != cb) return 0;
        if (!ca) return 1;                             // 两边同时结束
    }
    return 1;
}

// 大小写无关的整串比较（等价 strcasecmp(a, b) == 0）
static inline int ck_strcasecmp_eq(const char *a, const char *b) {
    if (!a || !b) return 0;
    for (size_t i = 0;; i++) {
        unsigned char ca = (unsigned char)a[i];
        unsigned char cb = (unsigned char)b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb - 'A' + 'a');
        if (ca != cb) return 0;
        if (!ca) return 1;
    }
}

#endif
