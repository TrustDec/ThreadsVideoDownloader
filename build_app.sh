#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
cd "$script_dir"

swift build -c release

app_dir="$script_dir/build/Threads视频下载器.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/ThreadsVideoDownloader" "$app_dir/Contents/MacOS/ThreadsVideoDownloader"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
chmod +x "$app_dir/Contents/MacOS/ThreadsVideoDownloader"

echo "已生成：$app_dir"
