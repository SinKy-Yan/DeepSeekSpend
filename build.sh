#!/bin/bash
# build.sh — 编译并打包 DeepSeekSpend.app（菜单栏应用）
# 用法：
#   ./build.sh          本机构建
#   ./build.sh release  发布构建（内置兼容 Node.js，生成可分发 zip）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"           # DeepSeekSpend 项目目录
OUT="$ROOT/../build/DeepSeekSpend.app"           # 生成的 App 放在工程目录的 build/ 下
APP_NAME="DeepSeekSpend"
BUNDLE_ID="com.deepseekspend.menu"
TMP="$ROOT/.build"
MODE="${1:-local}"

echo "==> 清理旧产物"
rm -rf "$OUT" "$TMP"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$TMP"

echo "==> 编译 Swift (arm64, macOS 13+)"
# 某些 Command Line Tools 版本同时留下 swift/module.modulemap 与 swift/bridging.modulemap，
# 两者都声明 SwiftBridging 会让 clang 报「redefinition of module」。用 VFS 覆盖掉旧文件。
SWIFT_VFS=()
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] \
   && [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  echo "    检测到 CLT modulemap 冲突，启用 VFS 覆盖"
  printf '// disabled: SwiftBridging is defined by bridging.modulemap\n' > "$TMP/empty.modulemap"
  cat > "$TMP/clt-overlay.yaml" <<YAML
{
  "version": 0,
  "fallthrough": true,
  "roots": [
    {
      "type": "directory",
      "name": "/Library/Developer/CommandLineTools/usr/include/swift",
      "contents": [
        { "type": "file", "name": "module.modulemap", "external-contents": "$TMP/empty.modulemap" }
      ]
    }
  ]
}
YAML
  SWIFT_VFS=(-vfsoverlay "$TMP/clt-overlay.yaml")
fi
swiftc -O \
  -target arm64-apple-macosx13.0 \
  "${SWIFT_VFS[@]}" \
  "$ROOT/App/main.swift" \
  -o "$OUT/Contents/MacOS/$APP_NAME" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement

echo "==> 复制采集器与配置"
cp "$ROOT/collector.mjs" "$OUT/Contents/Resources/collector.mjs"
cp "$ROOT/config.json"   "$OUT/Contents/Resources/config.json"


echo "==> 查找并内置兼容的 Node.js"
# 需要一个自带 zstd 解压能力、且不依赖 Homebrew 动态库的自包含 node。
NODE_BIN="${DEEPSEEKSPEND_NODE:-}"
if [ -z "$NODE_BIN" ] || ! "$NODE_BIN" -e "require('node:zlib').zstdDecompressSync" 2>/dev/null; then
  for CANDIDATE in "$ROOT/tools/node-runtime" "/Applications/DeepSeekSpend.app/Contents/Resources/node" "$(command -v node || true)"; do
    if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ] && "$CANDIDATE" -e "require('node:zlib').zstdDecompressSync" 2>/dev/null; then
      NODE_BIN="$CANDIDATE"
      break
    fi
  done
fi
if [ -z "$NODE_BIN" ] || ! "$NODE_BIN" -e "require('node:zlib').zstdDecompressSync" 2>/dev/null; then
  echo "错误：未找到自包含且支持 zstdDecompressSync 的 Node.js（需要 v22.15+）" >&2
  echo "      可设置 DEEPSEEKSPEND_NODE=/path/to/node 后重试" >&2
  exit 1
fi
NODE_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$NODE_BIN")"
NODE_ROOT="$(dirname "$(dirname "$NODE_REAL")")"
cp "$NODE_REAL" "$OUT/Contents/Resources/node"
chmod +x "$OUT/Contents/Resources/node"
if [ -f "$NODE_ROOT/LICENSE" ]; then
  cp "$NODE_ROOT/LICENSE" "$OUT/Contents/Resources/Node-LICENSE"
elif [ -f "$ROOT/tools/Node-LICENSE" ]; then
  cp "$ROOT/tools/Node-LICENSE" "$OUT/Contents/Resources/Node-LICENSE"
fi

echo "==> 生成图标"
swift "${SWIFT_VFS[@]}" "$ROOT/genicon.swift" "$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>DeepSeekSpend</string>
	<key>CFBundleDisplayName</key>
	<string>DeepSeek 消费</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.2.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>NSHumanReadableCopyright</key>
	<string>本地用量估算 · 可选官方余额查询</string>
</dict>
</plist>
PLIST

echo "==> 代码签名（ad-hoc，不创建证书、不修改钥匙串或信任设置）"
codesign --force --deep --sign - "$OUT"

echo "==> 完成"
echo "App: $OUT"
du -sh "$OUT"

# 发布模式：打 zip 包到 dist/
if [ "$MODE" = "release" ]; then
  DIST="$ROOT/dist"
  mkdir -p "$DIST"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUT/Contents/Info.plist" 2>/dev/null || echo 1.2.1)"
  ARCH="arm64"
  ZIP="$DIST/DeepSeekSpend-v${VERSION}-macOS-${ARCH}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$OUT" "$ZIP"
  echo "==> 发布包: $ZIP"
  ls -lh "$ZIP"
fi
