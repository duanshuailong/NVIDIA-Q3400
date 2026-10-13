#!/bin/bash
# Q3400 指定版本切换脚本 — 把 NVOS 切换到「你指定的某个版本」
#
# 与 q3400-upgrade-ladder.sh 的区别：
#   - ladder 只能「逐级往上升」到最高可用版本，且把非 8008/1010 当非法镜像清理
#   - 本脚本切到「你给定的精确版本」，可升可降（回退），不清理其他镜像
#
# 逻辑：
#   1. 只读检测当前运行的 NVOS 版本
#   2. 当前已是目标版本  → 跳过，直接退出（幂等）
#   3. 当前不是目标版本  → 安装目标版本镜像到 standby 分区并设为 boot-next
#                          （若 standby 分区已存在目标版本，可用 boot-next 直接切，免重装）
#   4. 安装/切换完成后，重启才生效 —— 默认交互确认，绝不擅自重启（--yes 跳过确认）
#
# NVOS 双分区机制：install 装到「非运行分区」并自动设 boot-next，切分区后新分区
#   Linux 层密码会回默认 admin/admin（配置层 nv config 会迁移保留）。
#   *** 切换前建议先跑 playbooks/40-set-password.yml 把密码写进 nv config 层 ***
#
# 用法（交换机本机）：
#   1. 把本脚本 + 目标版本镜像拷到 /host/tmp（或 U 盘 /home/admin/tmp）
#        nvosv25-02-6077amd64.bin   等 NVOS 镜像（可放多个，按版本自动挑选）
#   2. bash q3400-set-version.sh --version 25.02.6077          # 检测→安装→交互确认重启
#      bash q3400-set-version.sh --version 25.02.6077 --check  # 仅只读检测，不改任何东西
#      bash q3400-set-version.sh --version 25.02.6077 --yes    # 装完直接重启（无人值守）
#   3. tail -f /host/tmp/q3400-set-version.log

set -euo pipefail

USB_MOUNT=/home/admin/tmp
SRC=/host/tmp
LOG=${SRC}/q3400-set-version.log
LOCK_DIR=${SRC}/.q3400_set_version.lock
CONFIG_BACKUP_DIR=${SRC}/config-backups
NOS_STAGE=/host/nos-images
SCRIPT_VERSION="1.0.0"

# boot-next 命令模板（当 standby 分区已存在目标版本、想免重装直接切时使用）。
# {PART} = 目标分区名（如 partition2）。不同 NVOS 版本语法可能不同，
# 首次真机使用请先核对：nv action boot-next system --help
# 若该模板报错，脚本会自动回退到「从镜像文件重装」的可靠路径。
BOOTNEXT_CMD_TMPL='nv action boot-next system image {PART}'

# ---------- 运行时状态 ----------
TARGET_VER=""            # 目标版本，如 25.02.6077
TARGET_KEY=0
IMAGE_FILE=""            # 显式指定的镜像文件（--image）
ACTION=switch            # switch | check
ASSUME_YES=0             # --yes：安装后直接重启，不交互
DO_REBOOT=1              # --no-reboot：只装/只切，不重启
BACKGROUND=0
INTERNAL=0

CUR_NVOS="" CUR_NVOS_VER="" CUR_NVOS_KEY=0
PART_NAMES=() PART_BUILDS=() PART_VERS=()
RUNNING_PART="" NEXT_PART=""
FOUND_IMAGE=""           # 扫描到的目标版本镜像绝对路径
STANDBY_TARGET_PART=""   # 已含目标版本的非运行分区名（若有）

show_help() {
    cat <<EOF
Q3400 指定版本切换脚本 v${SCRIPT_VERSION} — 把 NVOS 切到指定版本（可升可降/回退）

必需:
  --version <X.XX.XXXX>   目标 NVOS 版本，例如 25.02.6077

可选:
  --image <文件>          显式指定镜像文件（默认按版本自动在 ${SRC}/U盘/脚本目录 搜索）
  --check                 仅只读检测（当前版本 / 分区 / 目标是否就绪），不做任何改动
  --yes                   安装完成后直接重启，无需交互确认（无人值守）
  --no-reboot             只安装/切换 boot-next，不重启（稍后手动重启生效）
  --bg                    后台运行
  --help                  显示帮助

行为:
  当前已是目标版本 → 跳过退出（幂等，安全可重复跑）
  当前不是        → 装目标版本到 standby 分区并设 boot-next
                     （standby 已有该版本则用 boot-next 直接切，免重装）
  默认: 安装后交互询问是否重启；绝不擅自重启

示例:
  bash q3400-set-version.sh --version 25.02.6077 --check
  bash q3400-set-version.sh --version 25.02.6077
  bash q3400-set-version.sh --version 25.02.6077 --yes --bg

提醒: 切分区后 Linux 层密码回默认。切换前先跑 playbooks/40-set-password.yml
      把密码写进 nv config 层，可跨分区保留。
EOF
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-V) TARGET_VER="${2:-}"; shift 2 ;;
        --image|-i)   IMAGE_FILE="${2:-}"; shift 2 ;;
        --check|-c)   ACTION=check; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --no-reboot)  DO_REBOOT=0; shift ;;
        --bg|--background) BACKGROUND=1; shift ;;
        --internal)   INTERNAL=1; shift ;;
        -h|--help)    show_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; show_help; exit 1 ;;
    esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# ---------- 版本解析（与 ladder 脚本一致）----------
extract_version() {
    local s=$1 v
    v=$( { grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{3,5}' <<<"${s}" || true; } | head -1)
    if [[ -z "${v}" ]]; then
        v=$( { grep -oE '[0-9]{2}-[0-9]{2}-[0-9]{3,5}' <<<"${s}" || true; } | head -1)
        v=${v//-/.}
    fi
    echo "${v}"
}

version_key() {
    local v=$1 a b c
    [[ -z "${v}" ]] && { echo 0; return; }
    IFS='.' read -r a b c <<<"${v}"
    echo $(( 10#${a:-0}*1000000000 + 10#${b:-0}*1000000 + 10#${c:-0} ))
}

# 归一化用户输入的版本（允许 25-02-6077 或 6077 简写→补全需完整，这里要求完整三段）
normalize_target() {
    local raw=$1
    raw=${raw//-/.}
    local v
    v=$(extract_version "${raw}")
    echo "${v}"
}

# ---------- 当前版本 / 分区检测 ----------
read_current_versions() {
    local nvos_out cur_part
    nvos_out=$(nv show system image 2>/dev/null || true)
    cur_part=$(awk '/^current[[:space:]]+/ {print $2; exit}' <<< "${nvos_out}")
    if [[ -n "${cur_part}" ]]; then
        CUR_NVOS=$(awk -v c="${cur_part}" '
            /^partition/ { pt=$1; next }
            pt == "partition" c && /build-id/ { print $NF; exit }
        ' <<< "${nvos_out}")
    fi
    [[ -z "${CUR_NVOS}" ]] && CUR_NVOS=$(awk '/build-id/ {print $NF; exit}' <<< "${nvos_out}")
    CUR_NVOS_VER=$(extract_version "${CUR_NVOS}")
    CUR_NVOS_KEY=$(version_key "${CUR_NVOS_VER}")
}

read_partitions() {
    PART_NAMES=() PART_BUILDS=() PART_VERS=()
    RUNNING_PART="" NEXT_PART=""
    local nvos_out
    nvos_out=$(nv show system image 2>/dev/null || true)
    [[ -z "${nvos_out}" ]] && return 1
    RUNNING_PART=$(awk '/^current[[:space:]]+/ {print $2; exit}' <<< "${nvos_out}")
    NEXT_PART=$(awk '/^next[[:space:]]+/ {print $2; exit}' <<< "${nvos_out}")
    local name="" build="" line
    while IFS= read -r line; do
        if [[ "${line}" =~ ^partition[0-9]+ ]]; then
            name=$(awk '{print $1}' <<< "${line}")
            if [[ "${line}" == *build-id* ]]; then
                build=$(awk '{print $NF}' <<< "${line}")
                PART_NAMES+=("${name}"); PART_BUILDS+=("${build}"); PART_VERS+=("$(extract_version "${build}")")
                name=""
            fi
        elif [[ -n "${name}" && "${line}" == *build-id* ]]; then
            build=$(awk '{print $NF}' <<< "${line}")
            PART_NAMES+=("${name}"); PART_BUILDS+=("${build}"); PART_VERS+=("$(extract_version "${build}")")
            name=""
        fi
    done <<< "${nvos_out}"
    (( ${#PART_NAMES[@]} > 0 ))
}

# 找一个「非运行分区」且版本==目标 → 存到 STANDBY_TARGET_PART
find_standby_with_target() {
    STANDBY_TARGET_PART=""
    local i
    for i in "${!PART_NAMES[@]}"; do
        [[ "${PART_NAMES[$i]}" == "${RUNNING_PART}" ]] && continue
        if [[ "${PART_VERS[$i]}" == "${TARGET_VER}" ]]; then
            STANDBY_TARGET_PART="${PART_NAMES[$i]}"
            return 0
        fi
    done
    return 1
}

print_partitions() {
    if ! read_partitions; then echo "  (无法读取分区信息)"; return; fi
    local i tag
    for i in "${!PART_NAMES[@]}"; do
        tag=""
        [[ "${PART_NAMES[$i]}" == "${RUNNING_PART}" ]] && tag="${tag} ◀运行中"
        [[ "${PART_NAMES[$i]}" == "${NEXT_PART}"    ]] && tag="${tag} ▶下次启动"
        [[ "${PART_VERS[$i]}"  == "${TARGET_VER}"   ]] && tag="${tag} ★目标版本"
        printf "    %-12s %-14s%s\n" "${PART_NAMES[$i]}" "${PART_VERS[$i]:-?}" "${tag}"
    done
}

# ---------- 镜像文件搜索 ----------
# 在目录里找版本==目标的 .bin
find_image_in_dir() {
    local dir=$1 f v
    [[ -d "${dir}" ]] || return 1
    while IFS= read -r f; do
        v=$(extract_version "$(basename "${f}")")
        if [[ "${v}" == "${TARGET_VER}" ]]; then echo "${f}"; return 0; fi
    done < <(find "${dir}" -maxdepth 2 -type f -iname '*.bin' \
        ! -name '._*' ! -name '.DS_Store' \
        ! -path '*/System Volume Information/*' \
        ! -path '*/.Spotlight-V100/*' \
        ! -path '*/.fseventsd/*' 2>/dev/null | sort)
    return 1
}

locate_image() {
    FOUND_IMAGE=""
    # 1. 显式指定优先
    if [[ -n "${IMAGE_FILE}" ]]; then
        if [[ -f "${IMAGE_FILE}" ]]; then
            local v; v=$(extract_version "$(basename "${IMAGE_FILE}")")
            if [[ -n "${v}" && "${v}" != "${TARGET_VER}" ]]; then
                log "警告: 指定镜像 $(basename "${IMAGE_FILE}") 版本 ${v} 与目标 ${TARGET_VER} 不一致"
            fi
            FOUND_IMAGE="${IMAGE_FILE}"; return 0
        fi
        log "错误: 指定的镜像文件不存在: ${IMAGE_FILE}"; return 1
    fi
    # 2. 自动搜索：SRC → U盘 → 脚本目录
    local script_dir d
    script_dir=$(cd "$(dirname "$0")" && pwd)
    for d in "${SRC}" "${USB_MOUNT}" "${script_dir}"; do
        [[ "${d}" == "${USB_MOUNT}" ]] && { mountpoint -q "${USB_MOUNT}" 2>/dev/null || continue; }
        if FOUND_IMAGE=$(find_image_in_dir "${d}"); then return 0; fi
    done
    FOUND_IMAGE=""
    return 1
}

# ---------- 配置备份（跨分区保留，切换前的保险）----------
backup_config() {
    local tag=${1:-set-version}
    mkdir -p "${CONFIG_BACKUP_DIR}"
    local ts f
    ts=$(date '+%Y%m%d-%H%M%S')
    f="${CONFIG_BACKUP_DIR}/config-${tag}-${CUR_NVOS_VER:-unknown}-${ts}.txt"
    set +e
    if nv config show -o commands > "${f}" 2>/dev/null && [[ -s "${f}" ]]; then
        log "配置已备份: ${f} ($(wc -l < "${f}") 行)"
    else
        nv config show > "${f}" 2>/dev/null
        if [[ -s "${f}" ]]; then log "配置已备份(基本格式): ${f}"
        else rm -f "${f}"; log "警告: 配置备份失败（nv config show 无输出），继续"; fi
    fi
    local eth0f="${CONFIG_BACKUP_DIR}/eth0-${ts}.txt"
    nv show interface eth0 ip address > "${eth0f}" 2>/dev/null || true
    [[ -s "${eth0f}" ]] && log "带外 eth0 IP 已记录: ${eth0f}" || rm -f "${eth0f}"
    set -e
}

# ---------- 安装 / 切换 ----------
cleanup_macos_junk_dir() {
    local dir=$1
    [[ -d "${dir}" ]] || return 0
    find "${dir}" -maxdepth 2 \( -name '._*' -o -name '.DS_Store' \) -type f -delete 2>/dev/null || true
}

# 把镜像放到 /host/nos-images 并 install（装到非运行分区、自动设 boot-next）
install_image() {
    local src=$1 base
    base=$(basename "${src}")
    mkdir -p "${NOS_STAGE}"
    cleanup_macos_junk_dir "${NOS_STAGE}"
    if [[ "$(cd "$(dirname "${src}")" && pwd)" != "${NOS_STAGE}" ]]; then
        log "拷贝镜像到 ${NOS_STAGE}: ${base} ($(du -h "${src}" 2>/dev/null | cut -f1))"
        cp -f "${src}" "${NOS_STAGE}/"; sync
    fi
    log ">>> 安装 NVOS ${TARGET_VER} [${base}]（装到 standby 分区，默认保留配置）"
    nv action install system image files "${base}" force
    log "NVOS ${TARGET_VER} 安装完成，已设为下次启动分区"
}

# standby 已有目标版本时，尝试用 boot-next 直接切（免重装）；失败返回非 0
switch_via_bootnext() {
    local part=$1 cmd
    cmd=${BOOTNEXT_CMD_TMPL/\{PART\}/${part}}
    log ">>> standby 分区 ${part} 已是 ${TARGET_VER}，尝试 boot-next 直接切换: ${cmd}"
    set +e
    eval "${cmd}" >>"${LOG}" 2>&1
    local rc=$?
    set -e
    if (( rc == 0 )); then
        log "boot-next 已指向 ${part} (${TARGET_VER})"
        return 0
    fi
    log "boot-next 失败 (rc=${rc})，命令语法可能因版本而异 → 回退到镜像文件重装"
    log "  可核对: nv action boot-next system --help"
    return 1
}

confirm_reboot() {
    if (( ! DO_REBOOT )); then
        log "已加 --no-reboot：不重启。稍后手动执行使之生效: nv action reboot system force"
        return 1
    fi
    if (( ASSUME_YES )); then return 0; fi
    if [[ ! -t 0 ]]; then
        log "非交互环境且未加 --yes：不擅自重启。请手动执行: nv action reboot system force"
        return 1
    fi
    local ans
    read -r -p ">>> 切到 ${TARGET_VER} 需重启生效。现在重启? (会造成短暂离线) [y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]]
}

do_reboot() {
    log ">>> 执行重启: nv action reboot system force"
    nv action reboot system force
}

# ---------- 只读检测 ----------
do_check() {
    echo "=== Q3400 指定版本检测 v${SCRIPT_VERSION} ==="
    read_current_versions
    echo "目标版本: ${TARGET_VER}"
    echo "当前运行: ${CUR_NVOS_VER:-未知}"
    echo ""
    echo "分区镜像:"
    print_partitions
    echo ""
    if [[ "${CUR_NVOS_VER}" == "${TARGET_VER}" ]]; then
        echo "结论: 已在目标版本，无需切换（幂等跳过）"
        return 0
    fi
    read_partitions
    if find_standby_with_target; then
        echo "结论: 需切换。standby 分区 ${STANDBY_TARGET_PART} 已有 ${TARGET_VER} → 可 boot-next 直接切，免重装"
    elif locate_image; then
        echo "结论: 需切换。将安装镜像: ${FOUND_IMAGE}"
    else
        echo "结论: 需切换，但【找不到 ${TARGET_VER} 镜像文件】，且无 standby 分区含该版本"
        echo "  请把镜像放到 ${SRC}/ 或 U 盘，或用 --image 指定"
        return 2
    fi
}

# ---------- 切换主流程 ----------
do_switch() {
    read_current_versions
    log "=== 目标 ${TARGET_VER} / 当前 ${CUR_NVOS_VER:-未知} ==="

    if [[ "${CUR_NVOS_VER}" == "${TARGET_VER}" ]]; then
        log "当前已是目标版本 ${TARGET_VER}，跳过（无需任何改动）"
        echo "已在目标版本 ${TARGET_VER}，无需切换。"
        return 0
    fi

    read_partitions || { log "错误: 无法读取分区信息 (nv show system image)"; exit 1; }

    # 切换前保险：备份配置 + 密码提醒
    backup_config "to-${TARGET_VER}"
    log "⚠ 切分区后新分区 Linux 层密码会回默认 admin/admin。若未处理，"
    log "  建议先在 Mac 端跑 playbooks/40-set-password.yml 把密码写进 nv config 层。"

    local switched=0
    # 路径 A：standby 已有目标版本 → boot-next 直接切（快，免重装）
    if find_standby_with_target; then
        if switch_via_bootnext "${STANDBY_TARGET_PART}"; then
            switched=1
        fi
    fi
    # 路径 B：从镜像文件安装（boot-next 未成功 或 standby 没有目标版本）
    if (( ! switched )); then
        if locate_image; then
            install_image "${FOUND_IMAGE}"
            switched=1
        else
            log "错误: 找不到 ${TARGET_VER} 镜像文件，且无 standby 分区含该版本，无法切换"
            log "  请把 nvos*${TARGET_VER//./}*.bin 放到 ${SRC}/ 或 U 盘，或用 --image 指定"
            exit 1
        fi
    fi

    echo ""
    echo "已就绪：下次启动分区将运行 ${TARGET_VER}"
    if confirm_reboot; then
        do_reboot
    else
        echo "未重启。手动重启生效: nv action reboot system force"
        echo "重启后确认: nv show system image"
    fi
}

# ---------- 后台 ----------
maybe_background() {
    if [[ -z "${Q3400_SETVER_BG:-}" && "${BACKGROUND}" -eq 1 && "${INTERNAL}" -eq 0 ]]; then
        local self; self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
        # 后台=无 tty，须显式 --yes 才会重启，否则装完停在等待重启
        nohup env Q3400_SETVER_BG=1 bash "${self}" --version "${TARGET_VER}" \
            $( [[ -n "${IMAGE_FILE}" ]] && echo --image "${IMAGE_FILE}" ) \
            $( (( ASSUME_YES )) && echo --yes ) \
            $( (( ! DO_REBOOT )) && echo --no-reboot ) \
            --internal >> "${LOG}" 2>&1 &
        echo "已在后台启动 (PID $!)，日志: tail -f ${LOG}"
        exit 0
    fi
}

acquire_lock() { mkdir "${LOCK_DIR}" 2>/dev/null || { log "已有任务在运行，日志: tail -f ${LOG}"; exit 1; }; }
release_lock() { rmdir "${LOCK_DIR}" 2>/dev/null || true; }

# ===================== 主入口 =====================
[[ -z "${TARGET_VER}" ]] && { echo "错误: 必须用 --version 指定目标版本" >&2; echo ""; show_help; exit 1; }
TARGET_VER=$(normalize_target "${TARGET_VER}")
[[ -z "${TARGET_VER}" ]] && { echo "错误: 版本格式无法识别，应形如 25.02.6077" >&2; exit 1; }
TARGET_KEY=$(version_key "${TARGET_VER}")

mkdir -p "${SRC}"

if [[ "${ACTION}" == "check" ]]; then
    do_check
    exit $?
fi

maybe_background
acquire_lock
trap release_lock EXIT
do_switch
