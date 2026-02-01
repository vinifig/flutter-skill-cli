#!/bin/bash

echo "🚀 flutter-skill v0.2.24 发布脚本"
echo ""
echo "正在发布到官方 pub.dev..."
echo ""

# 设置环境变量指向官方 pub.dev
export PUB_HOSTED_URL=https://pub.dev
export FLUTTER_STORAGE_BASE_URL=

# 发布
flutter pub publish

echo ""
echo "✅ 发布完成！"
echo ""
echo "访问 https://pub.dev/packages/flutter_skill 查看"
