#!/bin/bash
# 构建 PyPocket：准备运行时 → 生成工程 → 编译 → 注入 Python 标准库 → 打包未签名 IPA
# 用法：./scripts/build.sh            出 arm64 真机 IPA（未签名）
#       ./scripts/build.sh simulator  出模拟器 App 并跑 Python 单元测试
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-device}"
python3 scripts/prepare_runtime.py
python3 scripts/prepare_certificates.py

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 xcodegen：brew install xcodegen" >&2; exit 1
fi
xcodegen generate

if [[ "$MODE" == "simulator" ]]; then
  xcodebuild -project PyPocket.xcodeproj -scheme PyPocket -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
  APP=build/DerivedData/Build/Products/Debug-iphonesimulator/PyPocket.app
  PLATFORM_NAME=iphonesimulator CURRENT_ARCH=x86_64 \
    TARGET_BUILD_DIR="$(dirname "$APP")" WRAPPER_NAME="$(basename "$APP")" \
    CODE_SIGNING_ALLOWED=NO python3 scripts/embed_runtime.py
  python3 -m unittest discover -s tests -v
  echo "模拟器构建完成：$APP（CI 上再用 -destination 'platform=iOS Simulator,name=...' 跑测试）"
  exit 0
fi

xcodebuild -project PyPocket.xcodeproj -scheme PyPocket -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
APP=build/DerivedData/Build/Products/Release-iphoneos/PyPocket.app
PLATFORM_NAME=iphoneos CURRENT_ARCH=arm64 \
  TARGET_BUILD_DIR="$(dirname "$APP")" WRAPPER_NAME="$(basename "$APP")" \
  CODE_SIGNING_ALLOWED=NO python3 scripts/embed_runtime.py

rm -rf build/Payload "build/PyPocket.ipa"
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry PyPocket.ipa Payload && rm -rf Payload)
echo "已生成未签名 IPA：build/PyPocket.ipa（用 Sideloadly / AltStore / zsign 重签安装）"
