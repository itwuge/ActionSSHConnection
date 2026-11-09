#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : make-bundle.sh
# 文件用途    : 把 relay 目录打成自包含压缩包, 供目标机在无仓库场景下独立部署
# 架构定位    : 中继交付打包工具; 上游是 relay 工作副本, 下游是目标机上的解包目录
# 核心功能    : 校验必需文件, 按 relay/VERSION 生成版本号, 打包为 tar.gz, 输出校验和
# 职责边界    : 不安装任何软件, 不访问网络, 不修改被包含的文件, 不读取 relay 之外的资产
# 运行环境    : 任意 Linux 或 macOS 或 Git Bash, bash 4.x 以上, 依赖 tar 与 sha256sum
# 依赖关系    : 依赖 tar, sha256sum, date; 不依赖 root, 不依赖 git
#
# 输入        : 可选 --out <dir> 输出目录, 默认仓库根下的 dist/
#               --version <v> 版本标识, 默认取 relay/VERSION
# 退出码      : 0 成功; 2 参数非法; 3 必需文件缺失; 4 打包失败; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux, macOS, Git Bash

set -Eeuo pipefail

# =========** 方法一览 =========**
#   _say / _die -> 输出与终止
#   _parse_args -> 0/2: 解析参数
#   _version -> 0: 读取 relay/VERSION
#   _pack -> 0/3/4: 校验并打包

# =========** 常量与默认值 =========**
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$SCRIPT_DIR"
OUT_DIR=""
VERSION=""
BUNDLE_NAME="actssh-relay"

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: make-bundle.sh [--out <dir>] [--version <v>]

  --out <dir>       输出目录, 默认仓库根下的 dist/
  --version <v>     版本标识, 默认取 relay/VERSION
  -h, --help        打印本说明

产物: <out>/actssh-relay-<version>.tar.gz 与同名 .sha256
USAGE
}

_parse_args() {
    # 用途: 解析参数
    # 参数: 全部位置参数
    # 返回: 无; 退出码: 0 或 2
    while (( $# > 0 )); do
        case "$1" in
            --out) OUT_DIR="${2:?缺少 --out 取值}"; shift 2 ;;
            --version) VERSION="${2:?缺少 --version 取值}"; shift 2 ;;
            -h|--help) show_usage; exit 0 ;;
            *) printf '[ERROR] 未知参数: %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$(cd "${RELAY_DIR}/.." && pwd)/dist"
    fi
}

_version() {
    # 用途: 读取 relay 自身版本号
    # 参数: 无
    # 返回: 标准输出版本字符串; 退出码: 0
    if [[ -n "$VERSION" ]]; then
        printf '%s' "$VERSION"
        return 0
    fi
    if [[ -f "${RELAY_DIR}/VERSION" ]]; then
        tr -d '[:space:]' <"${RELAY_DIR}/VERSION"
        return 0
    fi
    printf '%s' "0.0.0"
}

_pack() {
    # 用途: 校验必需文件并打包
    # 参数: 无
    # 返回: 无; 退出码: 0 或 3 或 4
    local -a required=(
        VERSION
        install.sh
        uninstall.sh
        check-relay-health.sh
        install-uptermd.sh
        firewall.sh
        uptermd.service
        actssh-web-bridge.service
        bootstrap/lib.sh
        bootstrap/nginx-cert.sh
        bootstrap/web-bridge.sh
        bootstrap/selfcheck.sh
        bootstrap/actssh-nginx.service
        bridge/relay_bridge.py
        bridge/jsonl_logger.py
        bridge/requirements-web-bridge.txt
    )
    local rel
    for rel in "${required[@]}"; do
        if [[ ! -f "${RELAY_DIR}/${rel}" ]]; then
            printf '[ERROR] 必需文件缺失: %s\n' "$rel" >&2
            exit 3
        fi
    done
    # 打包前补齐执行位: 否则解包后 ./install.sh 与 bootstrap/*.sh 会因无执行权限失败
    chmod 0755 "${RELAY_DIR}"/*.sh "${RELAY_DIR}/bootstrap"/*.sh
    mkdir -p "$OUT_DIR"
    local tar_path="${OUT_DIR}/${BUNDLE_NAME}-${VERSION}.tar.gz"
    if ! tar -czf "$tar_path" \
        -C "$(dirname "$RELAY_DIR")" \
        "$(basename "$RELAY_DIR")"; then
        printf '[ERROR] 打包失败: %s\n' "$tar_path" >&2
        exit 4
    fi
    ( cd "$OUT_DIR" && sha256sum "$(basename "$tar_path")" >"$(basename "$tar_path").sha256" )
    printf '%s\n' "已生成: ${tar_path}"
    printf '%s\n' "版本: ${VERSION}"
    printf '%s\n' "校验和: $(cut -d' ' -f1 "${tar_path}.sha256")"
    printf '%s\n' "目标机解包后执行: sudo ./relay/install.sh --domain <域名> --email <邮箱> --apply"
}

# =========** 主流程 =========**
_parse_args "$@"
VERSION="$(_version)"
_pack
exit 0
