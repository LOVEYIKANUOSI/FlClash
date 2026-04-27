#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN_ROOT="$(wslpath -w "$ROOT_DIR")"

CORE_EXE="$ROOT_DIR/libclash/windows/FlClashCore.exe"
HELPER_EXE="$ROOT_DIR/libclash/windows/FlClashHelperService.exe"
ENV_JSON="$ROOT_DIR/env.json"

log() {
  printf '[flclash] %s\n' "$*"
}

die() {
  printf '[flclash] %s\n' "$*" >&2
  exit 1
}

require_linux_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

windows_has_command() {
  cmd.exe /c "where $1" >/dev/null 2>&1
}

run_windows_command() {
  local command="$1"
  local escaped_command="${command//\"/\\\"}"
  cmd.exe /c "cd /d \"$WIN_ROOT\" && $escaped_command"
}

ensure_windows_toolchain() {
  windows_has_command flutter || die 'Windows 环境里找不到 flutter，请先把 Flutter 加到 Windows PATH'
  windows_has_command dart || die 'Windows 环境里找不到 dart，请先把 Dart/Flutter 加到 Windows PATH'
}

ensure_native_binaries() {
  if [[ -f "$CORE_EXE" && -f "$HELPER_EXE" && -f "$ENV_JSON" ]]; then
    log '检测到 Windows 原生核心已存在，跳过 core 构建'
    return
  fi

  log '缺少 Windows 原生核心，开始构建 core'
  run_windows_command "dart .\\setup.dart windows --arch amd64 --out core" \
    || die '构建 Windows 原生核心失败'
}

flutter_pub_get() {
  log '执行 flutter pub get'
  run_windows_command "flutter pub get" || die 'flutter pub get 失败'
}

print_tips() {
  cat <<'TEXT'

[flclash] 测试提示
- 即将以 Windows 桌面模式启动 FlClash
- 如果只是验证界面或登录入口，直接用这个脚本即可
- 关闭应用后，终端里的 flutter run 会自动结束

TEXT
}

main() {
  require_linux_command wslpath
  require_linux_command cmd.exe

  if [[ ! -d "$ROOT_DIR/.git" ]]; then
    die "当前目录不是 Git 仓库：$ROOT_DIR"
  fi

  ensure_windows_toolchain
  ensure_native_binaries
  flutter_pub_get
  print_tips

  log '启动 Flutter Windows 调试'
  run_windows_command "flutter run -d windows"
}

main "$@"
