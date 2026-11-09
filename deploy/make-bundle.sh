#!/usr/bin/env bash
# =========** 文件头 =========**
# 文件        : make-bundle.sh
# 文件用途    : 把 deploy 脚本与桥接代码打成一个自包含压缩包, 供目标机在无仓库场景下一键部署
# 架构定位    : 交付打包工具; 上游是仓库工作副本, 下游是目标机上的解包目录
# 核心功能    : 校验必需文件, 生成版本号, 打包为 tar.gz, 输出包内清单与校验和
# 职责边界    : 不安装任何软件, 不访问网络, 不修改被包含的文件, 不生成安装脚本之外的内容
# 运行环境    : 任意 Linux 或 macOS 或 Git Bash, bash 4.x 以上, 依赖 tar 与 sha256sum
# 依赖关系    : 依赖 tar, sha256sum, date; 不依赖 root
#
# 输入        : 可选 --out <dir> 输出目录, 默认仓库根下的 dist/
#               --version <v> 版本标识, 默认取 git 短提交号, 无 git 时为日期
# 退出码      : 0 成功; 2 参数非法; 3 必需文件缺失; 4 打包失败; 130 收到 INT; 143 收到 TERM
# 运行平台    : Linux, macOS, Git Bash

set -Eeuo pipefail

# =========** 方法一览 =========**
#   _say / _die -> 输出与终止
#   _parse_args -> 0/2: 解析参数
#   _version -> 0: 计算默认版本号
#   _pack -> 0/3/4: 校验并打包

# =========** 常量与默认值 =========**
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR=""
VERSION=""
BUNDLE_NAME="actssh-deploy"

# =========** 参数校验 =========**
show_usage() {
    # 用途: 打印用法
    # 参数: 无
    # 返回: 无; 退出码: 0
    cat <<'USAGE'
用法: make-bundle.sh [--out <dir>] [--version <v>]

  --out <dir>       输出目录, 默认 <repo>/dist
  --version <v>     版本标识, 默认 git 短提交号
  -h, --help        打印本说明

产物: <out>/actssh-deploy-<version>.tar.gz 与同名 .sha256
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
        OUT_DIR="${REPO_ROOT}/dist"
    fi
}

_version() {
    # 用途: 计算默认版本号
    # 参数: 无
    # 返回: 标准输出版本字符串; 退出码: 0
    if [[ -n "$VERSION" ]]; then
        printf '%s' "$VERSION"
        return 0
    fi
    if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
        printf '%s' "$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
        return 0
    fi
    date '+%Y%m%d%H%M'
}

_pack() {
    # 用途: 校验必需文件并打包
    # 参数: 无
    # 返回: 无; 退出码: 0 或 3 或 4
    local -a required=(
        deploy/bootstrap.sh
        deploy/uninstall.sh
        deploy/check-relay-health.sh
        deploy/install-uptermd.sh
        deploy/firewall.sh
        deploy/uptermd.service
        deploy/actssh-web-bridge.service
        deploy/bootstrap/lib.sh
        deploy/bootstrap/nginx-cert.sh
        deploy/bootstrap/web-bridge.sh
        deploy/bootstrap/selfcheck.sh
        deploy/bootstrap/actssh-nginx.service
        scripts/bridge/relay_bridge.py
        scripts/bridge/jsonl_logger.py
        scripts/requirements-web-bridge.txt
    )
    local rel
    for rel in "${required[@]}"; do
        if [[ ! -f "${REPO_ROOT}/${rel}" ]]; then
            printf '[ERROR] 必需文件缺失: %s\n' "$rel" >&2
            exit 3
        fi
    done
    mkdir -p "$OUT_DIR"
    local tar_path="${OUT_DIR}/${BUNDLE_NAME}-${VERSION}.tar.gz"
    if ! tar -czf "$tar_path" \
        -C "$REPO_ROOT" \
        deploy scripts/bridge scripts/requirements-web-bridge.txt; then
        printf '[ERROR] 打包失败: %s\n' "$tar_path" >&2
        exit 4
    fi
    ( cd "$OUT_DIR" && sha256sum "$(basename "$tar_path")" >"$(basename "$tar_path").sha256" )
    printf '%s\n' "已生成: ${tar_path}"
    printf '%s\n' "校验和: $(cut -d' ' -f1 "${tar_path}.sha256")"
    printf '%s\n' "目标机解包后执行: sudo ./deploy/bootstrap.sh --domain <域名> --email <邮箱> --apply"
}

# =========** 主流程 =========**
_parse_args "$@"
VERSION="$(_version)"
_pack
exit 0
