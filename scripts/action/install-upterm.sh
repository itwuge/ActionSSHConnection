#!/usr/bin/env bash
# 文件: scripts/action/install-upterm.sh
# 所属目录: scripts/action/
# 文件用途: 下载并校验 upterm 客户端, 解包后加入 PATH.
# 架构定位: Action 步骤脚本; 上游是 precheck, 下游是 start-session.
# 职责边界: 只处理客户端二进制, 不接触会话与凭据.
# 运行环境: Linux runner; 依赖 curl / sha256sum / tar.

set -euo pipefail

workdir="${ACTSSH_WORKDIR:?缺少 ACTSSH_WORKDIR}"
version="${ACTSSH_UPTERM_VERSION:-v0.41.1}"
asset="upterm_linux_amd64.tar.gz"
sha256="3007d4ce09e9f70a390e1b52e5a0b591fc9fa473196ca76d8f72b5f1cd723b31"

# 版本与校验和一一对应；未知版本直接拒绝，避免下载到未经核实的二进制
case "$version" in
  v0.41.1) ;;
  *)
    echo "失败[阶段 install-client]：未内置 $version 的校验和，只支持 v0.41.1" >&2
    exit 1
    ;;
esac

url="https://github.com/owenthereal/upterm/releases/download/${version}/${asset}"
if ! curl -fsSL --retry 2 --max-time 120 -o "$workdir/upterm.tar.gz" "$url"; then
  echo "失败[阶段 install-client]：下载 $asset 失败" >&2
  exit 1
fi

actual="$(sha256sum "$workdir/upterm.tar.gz" | awk '{print $1}')"
if [ "$actual" != "$sha256" ]; then
  echo "失败[阶段 install-client]：校验和不匹配（$version）" >&2
  exit 1
fi

mkdir -p "$workdir/bin"
tar -xzf "$workdir/upterm.tar.gz" -C "$workdir/bin" upterm || {
  echo "失败[阶段 install-client]：解包失败" >&2
  exit 1
}
chmod 700 "$workdir/bin/upterm"
"$workdir/bin/upterm" version >/dev/null 2>&1 || {
  echo "失败[阶段 install-client]：客户端无法执行" >&2
  exit 1
}
echo "$workdir/bin" >> "$GITHUB_PATH"
echo "upterm $version 已安装并通过校验和校验"
