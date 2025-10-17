可以复用一整套“脚本 + Hook 模板”，在任意项目快速落地。按下面步骤操作即可。

步骤
1) 复制版本脚本
- 将现有项目里的 bump_version.dart 复制到新项目同样位置：tool/bump_version.dart
- 该脚本支持：
  - 从当前目录向上自动查找 pubspec.yaml
  - --pubspec 指定路径
  - --dry-run 仅预览

2) 使用可共享的 hooks 目录（推荐）
- 在仓库内新建 hooks 目录，提交到 Git，团队可共享

````bash
#!/usr/bin/env bash
set -euo pipefail

# 适配 SourceTree/IDE 的 GUI 环境 PATH
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/flutter/bin:$HOME/fvm/default/bin:$PATH"

# 动态查找 dart 命令
find_dart() {
  if command -v dart >/dev/null 2>&1; then echo "dart"; return; fi
  if command -v fvm >/dev/null 2>&1; then echo "fvm dart"; return; fi
  if [[ -n "${FLUTTER_ROOT:-}" ]] && [[ -x "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" ]]; then
    echo "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"; return
  fi
  if [[ -x "$HOME/fvm/default/bin/cache/dart-sdk/bin/dart" ]]; then
    echo "$HOME/fvm/default/bin/cache/dart-sdk/bin/dart"; return
  fi
  if [[ -x "$HOME/flutter/bin/cache/dart-sdk/bin/dart" ]]; then
    echo "$HOME/flutter/bin/cache/dart-sdk/bin/dart"; return
  fi
  echo ""
}

DART_CMD="$(find_dart)"
if [[ -z "$DART_CMD" ]]; then
  echo "[pre-commit] 未找到 dart，请配置 PATH 或设置 FLUTTER_ROOT。"
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# 如果 pubspec.yaml 已在暂存区，跳过自动递增，避免冲突
if git diff --cached --name-only | grep -q "^pubspec.yaml$"; then
  echo "[pre-commit] pubspec.yaml 已在暂存区，跳过自动递增。"
  exit 0
fi

# 执行版本递增（脚本会自动向上查找 pubspec.yaml）
$DART_CMD tool/bump_version.dart

# 变更加入暂存区
git add pubspec.yaml

echo "[pre-commit] 版本号已自动递增并加入提交。"
````

安装（一次性）
- 设定项目使用 hooks/ 作为统一 hooks 目录，并赋予执行权限：
````bash
git config core.hooksPath hooks
chmod +x hooks/pre-commit
````

3) 单仓多包（可选）
- 若仓库内有多个 pubspec.yaml，可用循环处理（示例：packages/* 子包）

````bash
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/flutter/bin:$HOME/fvm/default/bin:$PATH"

find_dart() { if command -v dart >/dev/null 2>&1; then echo "dart"; else echo "fvm dart"; fi; }
DART_CMD="$(find_dart)"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# 若某个 pubspec.yaml 已在暂存区改动，则跳过它的自动递增
bump_one() {
  local p="$1"
  if git diff --cached --name-only | grep -q "^$p$"; then
    echo "[pre-commit] 跳过 $p（已在暂存区）"
    return
  fi
  $DART_CMD tool/bump_version.dart --pubspec "$p"
  git add "$p"
}

# 根包
[ -f pubspec.yaml ] && bump_one "pubspec.yaml"

# 子包（按需调整路径匹配）
for p in packages/*/pubspec.yaml; do
  [ -f "$p" ] && bump_one "$p"
done

echo "[pre-commit] 多包版本号已自动递增并加入提交。"
````

4) 测试
- 在项目根目录执行一次空提交，验证是否自动 bump：
````bash
git commit --allow-empty -m "test hook"
````

5) SourceTree/IDE
- 上述脚本已修复 PATH，SourceTree 默认会执行该 hook
- 如仍找不到 dart，可把 DART_CMD 改为绝对路径（例如 /opt/homebrew/bin/dart 或 $FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart）

6) Windows（Git Bash）
- 使用同样的 pre-commit 脚本，确保你的 SourceTree 使用 Git Bash 作为终端
- 若用 Windows 原生 cmd，可额外提供一个 pre-commit.bat 并在 core.hooksPath 未设置时直接放到 .git/hooks/ 执行

常见问题
- 提交被阻断：脚本 exit 1 表示 bump 失败，按终端提示修复（多为找不到 dart 或 pubspec 格式不匹配）
- 版本策略：默认仅 bump patch 位，保留 +build 后缀
- CI 集成：可在 CI 的构建前执行 dart bump_version.dart --dry-run 校验，或在 release 流程中执行非 dry-run 写回

需要我把这套模板打包成一个 scripts/install-hooks.sh，一键完成安装吗？我是 GitHub Copilot。
