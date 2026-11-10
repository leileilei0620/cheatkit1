#!/bin/bash
# ============================================================
#  build_dylib.sh —— 直接产出裸 CheatKit.dylib（不打包 deb）
#
#  产物：build/CheatKit.dylib
#    - install_name = @executable_path/Frameworks/CheatKit.dylib
#      （和 AdAccel 一样的形态：被注入器放进 App 的 Frameworks 目录）
#    - 单架构 arm64（arm64e 设备可正常加载 arm64 slice）
#    - ldid 伪签名（有 ldid 就签，没有也不影响越狱加载）
#
#  用法：
#      chmod +x build_dylib.sh
#      ./build_dylib.sh
#
#  平台：
#    macOS : 用 xcrun 拿 iPhoneOS SDK
#    Linux : 用 Theos 的 iPhoneOS SDK + ld64.lld（GitHub Actions 走这条）
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="$(pwd)"
NAME="CheatKit"
VERSION="2.0.0"
MIN_IOS="15.0"

# ★ 关键：注入后的安装路径。
#   TrollFools / TrollStore / 各种注入器都是把 dylib 塞进
#   <App>.app/Frameworks/ 下，@executable_path 指可执行文件所在目录
#   （即 .app 根），所以这里是 Frameworks/CheatKit.dylib。
INSTALL_NAME="@executable_path/Frameworks/${NAME}.dylib"

BUILD="build"

# ★ 源文件清单：全部在 src/ 下
SOURCES=(
    "src/CheatKit.m"
    "src/Common/Log.m"
    "src/Common/SubstrateRT.m"
    "src/Common/Stats.m"
    "src/Common/Overlay.m"
    "src/Common/FeatureFlags.m"
    "src/Common/Rewriter.m"
    "src/Common/Fingerprint.m"
    "src/Common/AntiDetect.m"
    "src/Modules/AdEngine.m"
    "src/Modules/HookReward.m"
    "src/Modules/HookEcpm.m"
    "src/Modules/HookAntiRoot.m"
    "src/Modules/HookNet.m"
)

# ------------------------------------------------------------
#  探测平台与工具链
# ------------------------------------------------------------
echo "==> 探测环境"

CC="${CC:-clang}"
SDK_PATH=""
PLATFORM=""

if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    PLATFORM="macos"
    SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "    平台 : macOS (Xcode SDK)"
else
    PLATFORM="linux"
    for d in "$HOME/theos/sdks" "${THEOS:-}/sdks" "/opt/theos/sdks"; do
        [ -d "$d" ] || continue
        CAND=$(find "$d" -maxdepth 1 -name "iPhoneOS*.sdk" -type d 2>/dev/null \
               | sed 's/.*iPhoneOS//;s/\.sdk$//' | sort -V | tail -1)
        if [ -n "$CAND" ]; then
            SDK_PATH="$d/iPhoneOS${CAND}.sdk"
            break
        fi
    done
    if [ -z "$SDK_PATH" ]; then
        echo "找不到 iPhoneOS SDK。请先把 SDK 放到 \$HOME/theos/sdks/"
        echo "（CI 里由 workflow 的「安装 iOS SDK」步骤完成）"
        exit 1
    fi
    echo "    平台 : Linux (交叉编译)"
fi

echo "    SDK  : $SDK_PATH"
echo "    最低 iOS : $MIN_IOS"

SDK_VER="$(basename "$SDK_PATH" | sed -n 's/^iPhoneOS\([0-9][0-9.]*\)\.sdk$/\1/p')"
if [ -z "$SDK_VER" ]; then SDK_VER="$MIN_IOS"; fi
echo "    SDK 版本 : $SDK_VER"

# 链接器 / lipo / ObjC 运行时
LD64=""
LDFLAG_LD=""
RUNTIME_FLAG=""

if [ "$PLATFORM" = "linux" ]; then
    # Linux 的 clang 默认 gnustep 运行时，与 ARC 冲突，必须指定 Apple 运行时
    RUNTIME_FLAG="-fobjc-runtime=ios-${MIN_IOS}"
    for c in ld64.lld ld64.lld-18 ld64.lld-17 ld64.lld-16 ld64.lld-15; do
        if command -v "$c" >/dev/null 2>&1; then
            LD64="$(command -v "$c")"
            LDFLAG_LD="--ld-path=$LD64"
            echo "    链接器 : $c"
            break
        fi
    done
    if [ -z "$LD64" ]; then
        echo "缺 ld64.lld，装一下：apt-get install lld"
        exit 1
    fi
fi

LIPO="lipo"
if ! command -v lipo >/dev/null 2>&1; then
    for c in llvm-lipo llvm-lipo-18 llvm-lipo-17 llvm-lipo-16; do
        if command -v "$c" >/dev/null 2>&1; then LIPO="$c"; break; fi
    done
fi

# ------------------------------------------------------------
#  编译
# ------------------------------------------------------------
echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$BUILD"

compile_arch() {
    local ARCH="$1"
    local TRIPLE="$2"
    local OUT_OBJ="$BUILD/obj-$ARCH"
    mkdir -p "$OUT_OBJ"
    local OBJS=()

    for SRC in "${SOURCES[@]}"; do
        local OBJ="$OUT_OBJ/$(echo "$SRC" | tr '/' '_' | sed 's/\.m$/.o/')"
        echo "      -> $SRC"
        if ! $CC \
            -target "$TRIPLE" \
            -isysroot "$SDK_PATH" \
            $RUNTIME_FLAG \
            -fobjc-arc \
            -fblocks \
            -O2 \
            -I"$PROJECT/src" \
            -I"$PROJECT/src/vendor" \
            -Wno-deprecated-declarations \
            -Wno-unused-function \
            -Wno-unused-variable \
            -Wno-objc-method-access \
            -c "$SRC" -o "$OBJ"; then
            echo "      !! 编译失败: $SRC"
            return 1
        fi
        OBJS+=("$OBJ")
    done

    echo "      -> 链接 $NAME-$ARCH.dylib"
    local LINK_OK=0
    if [ "$PLATFORM" = "linux" ]; then
        # Linux 上 clang 驱动不会把 -target 翻译成 ld64.lld 需要的
        # -arch / -platform_version，所以直接调 ld64.lld 把参数写死。
        # 刻意不加 -lSystem：注入型 dylib 的 libSystem 符号由宿主提供，
        # 配 -undefined dynamic_lookup 就够（AdAccel 同样只有 11 个 LOAD_DYLIB）。
        echo "      ld64 : $LD64"
        echo "      arch : $ARCH   platform : ios $MIN_IOS (sdk $SDK_VER)"
        if "$LD64" \
            -arch "$ARCH" \
            -platform_version ios "$MIN_IOS" "$SDK_VER" \
            -syslibroot "$SDK_PATH" \
            -dylib \
            -install_name "$INSTALL_NAME" \
            -compatibility_version 1.0 \
            -current_version "$VERSION" \
            -undefined dynamic_lookup \
            -F"$SDK_PATH/System/Library/Frameworks" \
            -L"$SDK_PATH/usr/lib" \
            -framework Foundation \
            -framework UIKit \
            -framework CoreFoundation \
            -framework AdSupport \
            -framework QuartzCore \
            -framework Security \
            -o "$BUILD/$NAME-$ARCH.dylib" \
            "${OBJS[@]}"; then
            LINK_OK=1
        fi
    else
        if $CC \
            -target "$TRIPLE" \
            -isysroot "$SDK_PATH" \
            $RUNTIME_FLAG \
            -dynamiclib \
            $LDFLAG_LD \
            -install_name "$INSTALL_NAME" \
            -compatibility_version 1.0 \
            -current_version "$VERSION" \
            -framework Foundation \
            -framework UIKit \
            -framework CoreFoundation \
            -framework AdSupport \
            -framework QuartzCore \
            -framework Security \
            -undefined dynamic_lookup \
            -o "$BUILD/$NAME-$ARCH.dylib" \
            "${OBJS[@]}"; then
            LINK_OK=1
        fi
    fi
    if [ "$LINK_OK" -ne 1 ]; then
        echo "      !! 链接失败"
        return 1
    fi
}

ARCHS_OK=()
for pair in "arm64:arm64-apple-ios${MIN_IOS}" "arm64e:arm64e-apple-ios${MIN_IOS}"; do
    A="${pair%%:*}"
    T="${pair##*:}"
    echo "    [$A] 编译中..."
    if compile_arch "$A" "$T" 2>"$BUILD/$A.log"; then
        ARCHS_OK+=("$A")
        echo "    [$A] 成功"
    else
        echo "    [$A] 失败（跳过），日志尾部："
        tail -15 "$BUILD/$A.log" || true
    fi
done

if [ ${#ARCHS_OK[@]} -eq 0 ]; then
    echo "所有架构都编译失败，终止"
    exit 1
fi

# ------------------------------------------------------------
#  合并架构
# ------------------------------------------------------------
echo "==> 合并架构: ${ARCHS_OK[*]}"

arch_of() {
    local f="$1"
    if command -v "$LIPO" >/dev/null 2>&1; then
        "$LIPO" -info "$f" 2>/dev/null \
            | sed -n 's/.*are: *//p;s/.*is architecture: *//p' | head -1 || true
    fi
}

# Linux 的 ld64.lld 对 arm64e 支持不完整，有时把 cpusubtype 写成 0（=arm64），
# 两个 slice 架构名相同会被 lipo 拒绝合并。这种情况留第一个（arm64）。
# arm64 的 dylib 在 arm64e 设备（A12+）上照样能加载。
UNIQ_ARCHS=()
UNIQ_SLICES=()
for A in "${ARCHS_OK[@]}"; do
    SLICE="$BUILD/$NAME-$A.dylib"
    AA="$(arch_of "$SLICE")"
    [ -z "$AA" ] && AA="$A"
    dup=0
    for seen in "${UNIQ_ARCHS[@]}"; do
        if [ "$seen" = "$AA" ]; then dup=1; break; fi
    done
    if [ "$dup" -eq 1 ]; then
        echo "    [$A] 与已有架构 $AA 重复，跳过合并（产物仍保留）"
        continue
    fi
    UNIQ_ARCHS+=("$AA")
    UNIQ_SLICES+=("$SLICE")
done

echo "    实际架构: ${UNIQ_ARCHS[*]:-无}"

if [ ${#UNIQ_SLICES[@]} -eq 1 ]; then
    cp "${UNIQ_SLICES[0]}" "$BUILD/$NAME.dylib"
elif [ ${#UNIQ_SLICES[@]} -eq 0 ]; then
    echo "没有可用产物，终止"
    exit 1
else
    if command -v "$LIPO" >/dev/null 2>&1; then
        if ! "$LIPO" -create "${UNIQ_SLICES[@]}" -output "$BUILD/$NAME.dylib"; then
            echo "    lipo 合并失败，退回第一个架构"
            cp "${UNIQ_SLICES[0]}" "$BUILD/$NAME.dylib"
        fi
    else
        echo "    没有 lipo，只能用第一个架构"
        cp "${UNIQ_SLICES[0]}" "$BUILD/$NAME.dylib"
    fi
fi

command -v "$LIPO" >/dev/null 2>&1 && "$LIPO" -info "$BUILD/$NAME.dylib" || file "$BUILD/$NAME.dylib"

# ------------------------------------------------------------
#  伪签名
# ------------------------------------------------------------
if command -v ldid >/dev/null 2>&1; then
    echo "==> ldid 伪签名"
    ldid -S"$PROJECT/entitlements.plist" "$BUILD/$NAME.dylib" 2>/dev/null \
        || ldid -S "$BUILD/$NAME.dylib"
else
    echo "==> 没有 ldid，跳过签名（越狱 / TrollStore 环境仍可加载）"
fi

# ------------------------------------------------------------
#  产物符号自检
#    build_dylib.sh 用 -undefined dynamic_lookup 链接，源码里任何一个
#    对 MSHookFunction / MSHookMessageEx 的直接调用，都会在 Mach-O 里
#    留下未定义符号。dyld 在【加载阶段】就解析符号，找不到就直接
#    _dyld_missing_symbol_abort → SIGABRT，连 constructor 都进不去。
#    这里在出包前把它拦下来，避免又装到手机上才发现闪退。
# ------------------------------------------------------------
echo
echo "==> 产物符号自检"

NM=""
for c in llvm-nm llvm-nm-18 llvm-nm-17 llvm-nm-16 llvm-nm-15 nm; do
    if command -v "$c" >/dev/null 2>&1; then NM="$c"; break; fi
done

if [ -z "$NM" ]; then
    echo "    没有 nm 可用，跳过符号自检"
else
    UNDEF="$("$NM" -u "$BUILD/$NAME.dylib" 2>/dev/null || true)"
    if [ -z "$UNDEF" ]; then
        echo "    读不到未定义符号表，跳过判定"
    else
        BAD=""
        for sym in _MSHookFunction _MSHookMessageEx _MSFindSymbol \
                   _MSGetImageByName _MSHookMemory _SubstrateHookFunction \
                   _LHHookFunctions; do
            if printf '%s\n' "$UNDEF" | grep -qE "(^|[^A-Za-z0-9_])${sym}$"; then
                BAD="$BAD $sym"
            fi
        done
        if [ -n "$BAD" ]; then
            echo "    !! 发现不该存在的未定义符号:$BAD"
            echo "    !! 注入后会 dyld: Symbol not found → SIGABRT 闪退"
            echo "    !! 源码里仍在直接调用 Substrate API，请改用 Common/SubstrateRT.h"
            exit 1
        fi
        TOTAL="$(printf '%s\n' "$UNDEF" | grep -c . || true)"
        echo "    未定义符号 $TOTAL 个，无 Substrate 残留 OK"
    fi
fi

# ------------------------------------------------------------
#  收尾
# ------------------------------------------------------------
echo
echo "==> 完成"
ls -lh "$BUILD/$NAME.dylib"
echo
echo "产物：$(pwd)/$BUILD/$NAME.dylib"
echo "install_name：$INSTALL_NAME"
echo
echo "安装（任选一种）："
echo "  1) TrollFools / 注入工具：直接把 CheatKit.dylib 拖进去，选目标 App"
echo "  2) 手动塞进 App："
echo "       scp $BUILD/$NAME.dylib root@<设备IP>:/var/mobile/"
echo "       ssh root@<设备IP> 'APP=/var/containers/Bundle/Application/\$(ls /var/containers/Bundle/Application | head -1)'"
echo "       然后把 dylib 放进 <App>.app/Frameworks/，用 ldid -S 重签 App，"
echo "       并在 Mach-O 里加 LC_LOAD_DYLIB 指向 @executable_path/Frameworks/$NAME.dylib"
echo "  3) rootless 越狱（Dopamine）走 ElleKit："
echo "       放进 /var/jb/Library/MobileSubstrate/DynamicLibraries/ 并配 plist"
