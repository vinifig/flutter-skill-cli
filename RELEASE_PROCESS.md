# Release Process

## 快速发版命令

```bash
# 方法 1: 使用发版脚本（自动化）
./scripts/release.sh 0.3.2 "Brief description"

# 方法 2: 手动发版（精细控制）
# 见下方详细步骤
```

---

## 方法 1: 自动化发版（推荐）

### 使用 release.sh 脚本

```bash
# 基本用法
./scripts/release.sh <version> [description]

# 示例
./scripts/release.sh 0.3.2 "Bug fixes and performance improvements"
./scripts/release.sh 0.4.0 "Major feature release"
```

### 脚本功能

脚本会自动完成：

1. ✅ 检查 git 状态
2. ✅ 更新所有文件的版本号：
   - `pubspec.yaml`
   - `npm/package.json`
   - `vscode-extension/package.json`
   - `intellij-plugin/build.gradle.kts`
   - `intellij-plugin/plugin.xml`
   - `README.md`
   - `lib/src/cli/server.dart`
3. ✅ 更新 `CHANGELOG.md`（需手动编辑详细内容）
4. ✅ 提交、打 tag、推送到 GitHub
5. ✅ 触发 GitHub Actions 发布

### 注意事项

- ⚠️ 脚本会创建一个简单的 CHANGELOG 条目，**记得手动编辑补充详细内容**
- ⚠️ 推送前会要求确认，可以在此时修改 CHANGELOG
- ⚠️ 版本号格式必须是 `x.y.z`（例如：0.3.1）

---

## 方法 2: 手动发版流程

### Step 1: 准备 CHANGELOG

如果你有详细的 release notes，先准备好 CHANGELOG 条目：

```bash
# 1. 基于 RELEASE_NOTES_vX.Y.Z.md 创建简洁的 CHANGELOG 条目
# 2. 手动编辑 CHANGELOG.md，在最前面添加新版本

# CHANGELOG 格式示例：
## X.Y.Z

**Brief description**

### 🎯 Core Improvements
- Feature 1
- Feature 2

### ✨ New Features
- ...

### 📚 Documentation
- ...

---
```

### Step 2: 更新版本号

手动更新所有文件的版本号（或让 AI 帮你）：

```bash
# 需要更新的文件：
1. pubspec.yaml                           # version: X.Y.Z
2. lib/src/cli/server.dart                # const String _currentVersion = 'X.Y.Z'
3. npm/package.json                       # "version": "X.Y.Z"
4. vscode-extension/package.json          # "version": "X.Y.Z"
5. intellij-plugin/build.gradle.kts       # version = "X.Y.Z"
6. intellij-plugin/.../plugin.xml         # <version>X.Y.Z</version>
7. README.md                              # flutter_skill: ^X.Y.Z
```

### Step 3: 提交和打 tag

```bash
# 1. 查看更改
git status
git diff

# 2. 暂存所有更改
git add -A

# 3. 提交
git commit -m "chore: Release vX.Y.Z

Brief description of this release

Core improvements:
- Feature 1
- Feature 2

New features:
- ...

Documentation:
- ..."

# 4. 创建 tag
git tag vX.Y.Z

# 5. 推送到 GitHub
git push origin main --tags
```

### Step 4: 验证发布

```bash
# 查看 GitHub Actions 状态
open https://github.com/ai-dashboad/flutter-skill/actions

# 等待自动发布完成（约 10-15 分钟）
# 发布目标：
# - pub.dev
# - npm
# - VSCode Marketplace
# - JetBrains Marketplace
# - Homebrew
```

---

## 发版检查清单

### 发版前检查

- [ ] 代码已合并到 main 分支
- [ ] 所有测试通过
- [ ] CHANGELOG.md 已准备好
- [ ] 版本号符合语义化版本规范
- [ ] 如有重大变更，已更新文档

### 发版后验证

- [ ] GitHub tag 已创建
- [ ] GitHub Actions 运行成功
- [ ] pub.dev 显示新版本
- [ ] npm 显示新版本
- [ ] VSCode Marketplace 显示新版本（可能延迟几小时）
- [ ] JetBrains Marketplace 显示新版本（可能延迟几小时）

---

## 语义化版本规范

遵循 [Semantic Versioning 2.0.0](https://semver.org/)：

- **主版本号 (MAJOR)**: 不兼容的 API 变更
  - 例如：1.0.0 → 2.0.0

- **次版本号 (MINOR)**: 向后兼容的新功能
  - 例如：0.3.0 → 0.4.0

- **修订号 (PATCH)**: 向后兼容的问题修复
  - 例如：0.3.0 → 0.3.1

### 示例

```
0.3.0 → 0.3.1  # Bug 修复、性能优化、小改进
0.3.1 → 0.4.0  # 新功能、新 API
0.4.0 → 1.0.0  # 重大变更、破坏性更新
```

---

## 特殊发版场景

### 紧急修复版本

```bash
# 快速发布 bug 修复
./scripts/release.sh 0.3.2 "Critical bug fix"

# 或手动：
# 1. 只更新 PATCH 版本号
# 2. CHANGELOG 简洁明了
# 3. 快速推送
```

### 预发布版本

```bash
# Alpha 版本
./scripts/release.sh 0.4.0-alpha.1 "Alpha release for testing"

# Beta 版本
./scripts/release.sh 0.4.0-beta.1 "Beta release"

# RC 版本
./scripts/release.sh 0.4.0-rc.1 "Release candidate"
```

### 回滚版本

```bash
# 如果发现严重问题需要回滚：

# 1. 从 pub.dev 撤回版本（联系官方）
# 2. 标记版本为已弃用
dart pub global activate flutter_skill

# 3. 发布修复版本
./scripts/release.sh 0.3.3 "Fix critical issue in 0.3.2"
```

---

## 常见问题

### Q: 版本号更新遗漏了某个文件怎么办？

```bash
# 如果已经推送：
# 1. 修复文件
# 2. 创建新的补丁版本
./scripts/release.sh 0.3.2 "Fix version inconsistency"

# 如果还未推送：
# 1. 修复文件
# 2. 修改提交
git add <missed-file>
git commit --amend
git tag -f vX.Y.Z
git push origin main --tags --force
```

### Q: GitHub Actions 发布失败怎么办？

```bash
# 1. 查看失败原因
open https://github.com/ai-dashboad/flutter-skill/actions

# 2. 修复问题后重新触发
# 方式 1: 删除 tag 重新推送
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
git tag vX.Y.Z
git push origin vX.Y.Z

# 方式 2: 手动触发 workflow
# 在 GitHub Actions 界面点击 "Re-run jobs"
```

### Q: 如何测试发版流程？

```bash
# 在测试分支上测试：
git checkout -b test-release
./scripts/release.sh 0.3.1-test.1 "Test release"

# 验证所有文件是否正确更新
git diff main..test-release

# 测试完成后删除分支
git checkout main
git branch -D test-release
```

---

## 发版后续工作

### 1. 发布公告

- [ ] 在 GitHub Discussions 发布公告
- [ ] 在 Twitter/X 分享更新
- [ ] 在相关社区发布更新（如果有重大特性）

### 2. 文档更新

- [ ] 确保官方文档同步更新
- [ ] 更新示例代码
- [ ] 更新截图（如有 UI 变化）

### 3. 监控反馈

- [ ] 关注 GitHub Issues
- [ ] 检查 pub.dev 分析数据
- [ ] 监控错误报告

---

## 自动化建议

### 使用 AI 助手发版

```bash
# 告诉 AI：
"发布 v0.3.2 版本，修复了截图性能问题"

# AI 会自动：
# 1. 准备 CHANGELOG 条目
# 2. 更新所有版本号
# 3. 提交和打 tag
# 4. 推送到 GitHub
```

### 设置 Git Hooks

```bash
# 创建 .git/hooks/pre-push
# 自动检查版本一致性
```

---

## 参考资料

- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Actions Docs](https://docs.github.com/en/actions)
- [Pub.dev Publishing Guide](https://dart.dev/tools/pub/publishing)
