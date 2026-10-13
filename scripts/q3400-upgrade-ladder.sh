#!/bin/bash
# Q3400 升级脚本（阶梯版）— 自动检测当前 NVOS 版本，逐级升级
#
# NVOS 阶梯：把所有可用镜像按版本从低到高排序，从"当前版本的下一级"
# 一路升到最高版本。例如同时放入 6077 / 7002 / 8008 / 1010：
#   当前 6077 → 7002 → 8008 → 1010
#   当前 7002 → 8008 → 1010
#   当前 8008 → 1010
#   当前 1010 → 已达标，不动
# 顺序：先 BIOS，再 CPLD，最后 NVOS 逐级升级。每次升级后自动重启，
# 通过 cron @reboot 续跑，直到到达最高版本。
#
# 运行方式（交换机本机）：
#   1. 把本脚本 + 固件拷到交换机（U 盘挂载到 /home/admin/tmp，或 SSH scp 到 /host/tmp）
#        *.cab              BIOS
#        *burn*.vme         CPLD burn
#        *refresh*.vme      CPLD refresh
#        nvos*.bin / *.bin  NVOS 镜像（放多个，自动排阶梯）
#   2. bash q3400-upgrade-ladder.sh --auto
#   3. tail -f /host/tmp/q3400-upgrade.log
#   4. 全部完成后： bash q3400-upgrade-ladder.sh --verify
#
# 必须指定操作参数，无参数不执行。详见 --help

set -euo pipefail

USB_MOUNT=/home/admin/tmp
SRC=/host/tmp
STEP_FILE=${SRC}/.q3400_step
BURN_DONE=${SRC}/.q3400_burn_done
LAST_STAGE=${SRC}/.q3400_last_stage
STAGE_COUNT=${SRC}/.q3400_stage_count
MAX_STAGE_RETRY=3
MANIFEST=${SRC}/.q3400_manifest
LOG=${SRC}/q3400-upgrade.log
LOCK_DIR=${SRC}/.q3400_upgrade.lock
SCRIPT=${SRC}/q3400-upgrade-ladder.sh
CRON_MARKER="# q3400-upgrade-ladder-auto"
BOOT_WAIT=180
CONFIG_BACKUP_DIR=${SRC}/config-backups
SCRIPT_VERSION="2.1.0"

# 目标版本（BIOS/CPLD 单一目标；NVOS 走阶梯，取可用镜像最高版本为终点）
TARGET_BIOS_MATCH="06.01.009"
TARGET_CPLD1_MATCH="CPLD000232_REV0900"

# 允许存在的 NVOS 分区版本（其他版本视为需清理）
ALLOWED_NVOS_VERS=("25.02.8008" "25.03.1010")

# NVOS 卸载命令。实测本版 NVOS 的 uninstall 不接任何参数（files/版本/分区名都报
# Invalid parameter），只删“非 boot-next 的 standby 分区”。NVOS 双分区，standby 至多一个，
# 跑一次即删掉它。切勿加 force —— force 含义是“连 boot-next 也删”，会误删要保留的分区。
# {FILE} 保留占位以兼容旧的替换调用（模板不含它时替换即为空操作）。
# 核对: nv action uninstall system image --help
UNINSTALL_CMD_TMPL='nv action uninstall system image'

# 运行时检测
CUR_BIOS="" CUR_CPLD1="" CUR_NVOS="" CUR_NVOS_VER="" CUR_NVOS_KEY=0
NEED_BIOS=0 NEED_CPLD=0 NEED_NVOS=0

# NVOS 阶梯（并行数组，按 key 升序）
LADDER_KEYS=() LADDER_VERS=() LADDER_FILES=()
LADDER_DIR=""           # 阶梯来源目录（已构建则非空）
FINAL_KEY=0 FINAL_VER=""
NEXT_NVOS_FILE="" NEXT_NVOS_VER="" NEXT_NVOS_KEY=0

# 运行时填充
BIOS_FILE="" BURN_FILE="" REFRESH_FILE=""
SOURCE_DIR=""

ACTION=""
BACKGROUND=0
INTERNAL=0
ALL_TARGETS_MET=0

show_help() {
    cat <<EOF
Q3400 升级脚本（阶梯版 v${SCRIPT_VERSION}）— 必须指定一个操作:

流程: 先 BIOS → 再 CPLD → 最后 NVOS 逐级升级到最高可用版本
      每级升级后自动重启，cron @reboot 续跑，全部达标后自动删 cron

主入口:
  --auto        统一入口（推荐）
                检测当前版本 → 补齐 BIOS/CPLD → NVOS 逐级升级
                注册 cron 续跑，全部达标后自动删除
续跑:
  --boot        开机 cron 调用（--auto 注册，一般无需手敲）
  --run         手动执行下一阶段
单项:
  --bios        仅 BIOS 升级 + 重启
  --cpld        仅 CPLD burn + refresh
  --nvos        仅升级 NVOS 到下一级（执行一次一跳）
  --verify      查看当前版本
管理:
  --check        检测版本 + 打印 NVOS 阶梯计划 + 已安装分区镜像
  --status       查看进度、版本、已识别固件、日志
  --backup       立即备份当前配置到 /host/tmp/config-backups（含带外 eth0 IP）
  --list-images  仅列出已安装 NVOS 分区镜像（只读）
  --clean-images 删除 standby 上非 ${ALLOWED_NVOS_VERS[*]} 的镜像
  --reset        重置全流程进度
  --unhook       仅删除 cron 自动检查
  --help         显示帮助

分区镜像策略: 仅允许 ${ALLOWED_NVOS_VERS[*]} 存在。达标验收(--verify)时
              自动清理 standby 上的非法镜像；运行中分区无法删除。

可选: --bg  后台运行

固件识别（文件名不限版本，自动排序）:
  BIOS *.cab | CPLD *burn*.vme + *refresh*.vme | NVOS nvos*.bin / *.bin
  也支持子目录: bios/  cpld/  nvos/

示例:
  # U 盘
  mount /dev/sda1 ${USB_MOUNT}
  bash ${USB_MOUNT}/q3400-upgrade-ladder.sh --auto
  # 或 SSH 拷到本机后
  cp *.cab *burn*.vme *refresh*.vme *.bin q3400-upgrade-ladder.sh ${SRC}/
  bash ${SCRIPT} --auto
  tail -f ${LOG}
EOF
}

for arg in "$@"; do
    case "${arg}" in
        --auto|-a)         [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=auto ;;
        --boot)            [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=boot ;;
        --check|-c)        [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=check ;;
        --run|-r)          [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=run ;;
        --bios|-b)         [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=bios ;;
        --cpld)            [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=cpld ;;
        --nvos|-n)         [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=nvos ;;
        --verify|-v)       [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=verify ;;
        --status|-s)       [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=status ;;
        --reset)           [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=reset ;;
        --unhook)          [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=unhook ;;
        --backup)          [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=backup ;;
        --list-images)     [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=list_images ;;
        --clean-images)    [[ -n "${ACTION}" ]] && { echo "错误: 只能指定一个操作" >&2; exit 1; }; ACTION=clean_images ;;
        --bg|--background) BACKGROUND=1 ;;
        --internal)        INTERNAL=1 ;;
        -h|--help)         show_help; exit 0 ;;
        *) echo "未知参数: ${arg}" >&2; show_help; exit 1 ;;
    esac
done

[[ "${INTERNAL}" -eq 1 && -z "${ACTION}" ]] && ACTION=boot

if [[ -z "${ACTION}" ]]; then
    echo "错误: 必须指定操作参数"; echo ""; show_help; exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# ---------- 版本解析 ----------
# 从字符串提取 NN.NN.NNN[N[N]] 版本号（支持 . 或 - 分隔）
extract_version() {
    local s=$1 v
    v=$( { grep -oE '[0-9]{2}\.[0-9]{2}\.[0-9]{3,5}' <<<"${s}" || true; } | head -1)
    if [[ -z "${v}" ]]; then
        v=$( { grep -oE '[0-9]{2}-[0-9]{2}-[0-9]{3,5}' <<<"${s}" || true; } | head -1)
        v=${v//-/.}
    fi
    echo "${v}"
}

# 版本号 → 可比较整数
version_key() {
    local v=$1 a b c
    [[ -z "${v}" ]] && { echo 0; return; }
    IFS='.' read -r a b c <<<"${v}"
    echo $(( 10#${a:-0}*1000000000 + 10#${b:-0}*1000000 + 10#${c:-0} ))
}

version_match() {
    local current=$1 pattern=$2
    [[ -n "${current}" && -n "${pattern}" && "${current}" == *"${pattern}"* ]]
}

# ---------- 固件扫描 ----------
find_firmware() {
    local dir=$1 pattern=$2 results count
    [[ -d "${dir}" ]] || return 1
    mapfile -t results < <(find "${dir}" -maxdepth 2 -type f -iname "${pattern}" \
        ! -name '._*' ! -name '.DS_Store' \
        ! -path '*/System Volume Information/*' \
        ! -path '*/.Spotlight-V100/*' \
        ! -path '*/.fseventsd/*' 2>/dev/null | sort)
    count=${#results[@]}
    (( count == 0 )) && return 1
    (( count > 1 )) && log "警告: ${pattern} 在 ${dir} 匹配 ${count} 个，使用: $(basename "${results[0]}")"
    echo "${results[0]}"
}

# 构建 NVOS 阶梯：扫描目录下所有 .bin，按版本去重升序
build_nvos_ladder() {
    local dir=$1 f v k i
    LADDER_KEYS=() LADDER_VERS=() LADDER_FILES=()
    FINAL_KEY=0 FINAL_VER=""
    [[ -d "${dir}" ]] || return 1

    # 取所有 .bin（排除 macOS 垃圾与系统目录），优先 nvos*.bin
    local -a bins
    mapfile -t bins < <(find "${dir}" -maxdepth 2 -type f -iname 'nvos*.bin' \
        ! -name '._*' ! -name '.DS_Store' 2>/dev/null | sort -u)
    if (( ${#bins[@]} == 0 )); then
        mapfile -t bins < <(find "${dir}" -maxdepth 2 -type f -iname '*.bin' \
            ! -name '._*' ! -name '.DS_Store' \
            ! -path '*/System Volume Information/*' \
            ! -path '*/.Spotlight-V100/*' \
            ! -path '*/.fseventsd/*' 2>/dev/null | sort -u)
    fi
    (( ${#bins[@]} == 0 )) && return 1

    # 组装 "key|ver|file"，按 key 数值排序去重
    local -a rows=()
    for f in "${bins[@]}"; do
        v=$(extract_version "$(basename "${f}")")
        [[ -z "${v}" ]] && { log "警告: 无法识别版本，跳过 $(basename "${f}")"; continue; }
        k=$(version_key "${v}")
        rows+=("${k}|${v}|${f}")
    done
    (( ${#rows[@]} == 0 )) && return 1

    local prev_key=""
    while IFS='|' read -r k v f; do
        [[ "${k}" == "${prev_key}" ]] && continue   # 同版本去重，保留第一个
        LADDER_KEYS+=("${k}"); LADDER_VERS+=("${v}"); LADDER_FILES+=("${f}")
        prev_key="${k}"
    done < <(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n)

    i=$(( ${#LADDER_KEYS[@]} - 1 ))
    (( i < 0 )) && return 1
    FINAL_KEY="${LADDER_KEYS[$i]}"; FINAL_VER="${LADDER_VERS[$i]}"
    LADDER_DIR="${dir}"
    return 0
}

# 选择阶梯来源目录：优先 SRC（重启后仍在），其次 U 盘，再脚本目录
ensure_ladder() {
    [[ -n "${LADDER_DIR}" && ${#LADDER_KEYS[@]} -gt 0 ]] && return 0
    local script_dir
    script_dir=$(cd "$(dirname "$0")" && pwd)
    build_nvos_ladder "${SRC}" && return 0
    if mountpoint -q "${USB_MOUNT}" 2>/dev/null; then
        build_nvos_ladder "${USB_MOUNT}" && return 0
    fi
    [[ "${script_dir}" != "${SRC}" ]] && build_nvos_ladder "${script_dir}" && return 0
    return 1
}

# 计算"当前版本的下一级"
compute_next_rung() {
    NEXT_NVOS_FILE="" NEXT_NVOS_VER="" NEXT_NVOS_KEY=0
    local i
    for i in "${!LADDER_KEYS[@]}"; do
        if (( LADDER_KEYS[i] > CUR_NVOS_KEY )); then
            NEXT_NVOS_KEY="${LADDER_KEYS[$i]}"
            NEXT_NVOS_VER="${LADDER_VERS[$i]}"
            NEXT_NVOS_FILE="${LADDER_FILES[$i]}"
            return 0
        fi
    done
    return 1
}

# ---------- 版本检测 ----------
read_current_versions() {
    local nvos_out cur_part
    CUR_BIOS=$(nv show platform firmware BIOS 2>/dev/null | awk '/actual-firmware/ {print $NF; exit}')
    CUR_CPLD1=$(nv show platform firmware CPLD1 2>/dev/null | awk '/actual-firmware/ {print $NF; exit}')
    nvos_out=$(nv show system image 2>/dev/null)
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

# ---------- 已安装分区镜像检测 / 清理 ----------
# 填充并行数组：PART_NAMES / PART_BUILDS / PART_VERS，及 RUNNING_PART
PART_NAMES=() PART_BUILDS=() PART_VERS=()
RUNNING_PART=""

read_partitions() {
    PART_NAMES=() PART_BUILDS=() PART_VERS=()
    RUNNING_PART=""
    local nvos_out
    nvos_out=$(nv show system image 2>/dev/null)
    [[ -z "${nvos_out}" ]] && return 1

    RUNNING_PART=$(awk '/^current[[:space:]]+/ {print $2; exit}' <<< "${nvos_out}")

    # 解析每个 "partitionN ... build-id <id>" 块
    local name="" build="" line
    while IFS= read -r line; do
        if [[ "${line}" =~ ^partition[0-9]+ ]]; then
            name=$(awk '{print $1}' <<< "${line}")
            # 同行可能带 build-id，也可能在后续行
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

is_allowed_nvos_ver() {
    local v=$1 a
    for a in "${ALLOWED_NVOS_VERS[@]}"; do [[ "${v}" == "${a}" ]] && return 0; done
    return 1
}

print_partitions() {
    if ! read_partitions; then echo "  (无法读取分区信息)"; return; fi
    local i tag allow
    for i in "${!PART_NAMES[@]}"; do
        tag=""
        [[ "${PART_NAMES[$i]}" == "${RUNNING_PART}" ]] && tag="◀ 运行中"
        is_allowed_nvos_ver "${PART_VERS[$i]}" && allow="允许" || allow="⚠ 非法(应清理)"
        printf "    %-12s %-14s %-16s %s\n" "${PART_NAMES[$i]}" "${PART_VERS[$i]:-?}" "${allow}" "${tag}"
    done
}

# 检测非法分区镜像；模式 report=仅报告 / enforce=尝试删除 standby 非法镜像
# 返回：0=全部合规  1=存在非法(report) 或 已处理但运行分区非法(enforce)
check_installed_images() {
    local mode=${1:-report}
    if ! read_partitions; then
        log "无法读取 nv show system image 分区信息"
        return 1
    fi
    local i illegal_standby=0 illegal_running=0
    log "=== 已安装分区镜像检测（允许: ${ALLOWED_NVOS_VERS[*]}）==="
    for i in "${!PART_NAMES[@]}"; do
        local n="${PART_NAMES[$i]}" v="${PART_VERS[$i]}" b="${PART_BUILDS[$i]}"
        if is_allowed_nvos_ver "${v}"; then
            log "  ${n}: ${v:-未知}  合规$( [[ "${n}" == "${RUNNING_PART}" ]] && echo ' (运行中)')"
            continue
        fi
        if [[ "${n}" == "${RUNNING_PART}" ]]; then
            illegal_running=1
            log "  ${n}: ${v:-未知}  ⚠ 非法且正在运行 — 无法删除运行中镜像"
            log "    → 需先升级/切换到 8008 或 1010 并重启后再清理此分区"
        else
            illegal_standby=1
            if [[ "${mode}" == "enforce" ]]; then
                local cmd=${UNINSTALL_CMD_TMPL/\{FILE\}/${b}}
                log "  ${n}: ${v:-未知}  ⚠ 非法(standby) — 执行删除: ${cmd}"
                set +e
                eval "${cmd}" >>"${LOG}" 2>&1
                local rc=$?
                set -e
                if (( rc == 0 )); then
                    log "    ✓ 已删除 ${n} (${v})"
                else
                    log "    ✗ 删除失败 (rc=${rc})。命令语法可能因 NVOS 版本而异"
                    log "    → 请核对: nv action uninstall system image --help"
                fi
            else
                log "  ${n}: ${v:-未知}  ⚠ 非法(standby) — 待清理（--clean-images 执行删除）"
            fi
        fi
    done
    if (( illegal_running )); then return 1; fi
    if (( illegal_standby )) && [[ "${mode}" == "report" ]]; then return 1; fi
    log "分区镜像检测完成"
    return 0
}

assess_upgrade_needs() {
    set +e; set +o pipefail
    read_current_versions
    ensure_ladder
    compute_next_rung || true
    if version_match "${CUR_BIOS}" "${TARGET_BIOS_MATCH}"; then NEED_BIOS=0; else NEED_BIOS=1; fi
    if version_match "${CUR_CPLD1}" "${TARGET_CPLD1_MATCH}"; then NEED_CPLD=0; else NEED_CPLD=1; fi
    # NVOS: 当前 key < 阶梯最高 key 则需升级（且阶梯已识别到镜像）
    if (( FINAL_KEY > 0 && CUR_NVOS_KEY < FINAL_KEY )); then NEED_NVOS=1; else NEED_NVOS=0; fi
    set -e; set -o pipefail
}

needs_any_upgrade() { (( NEED_BIOS || NEED_CPLD || NEED_NVOS )); }
need_status_str() { version_match "${1}" "${2}" && echo "跳过(已达标)" || echo "需升级"; }

nvos_status_str() {
    if (( FINAL_KEY == 0 )); then echo "未识别镜像"; return; fi
    if (( CUR_NVOS_KEY >= FINAL_KEY )); then echo "已达标(最高 ${FINAL_VER})"; return; fi
    echo "需升级 → 下一级 ${NEXT_NVOS_VER:-?} (终点 ${FINAL_VER})"
}

print_ladder() {
    (( ${#LADDER_VERS[@]} == 0 )) && { echo "  (未识别到 NVOS 镜像)"; return; }
    local i mark
    for i in "${!LADDER_VERS[@]}"; do
        mark="  "
        (( LADDER_KEYS[i] == CUR_NVOS_KEY )) && mark="◀ 当前"
        (( LADDER_KEYS[i] == NEXT_NVOS_KEY && NEXT_NVOS_KEY > 0 )) && mark="▲ 下一级"
        printf "    %-12s %s\n" "${LADDER_VERS[$i]}" "${mark}"
    done
}

log_upgrade_plan() {
    log "=== 版本检测 (v${SCRIPT_VERSION}) ==="
    log "BIOS  当前: ${CUR_BIOS:-未知}  → $(need_status_str "${CUR_BIOS}" "${TARGET_BIOS_MATCH}")"
    log "CPLD1 当前: ${CUR_CPLD1:-未知} → $(need_status_str "${CUR_CPLD1}" "${TARGET_CPLD1_MATCH}")"
    log "NVOS  当前: ${CUR_NVOS_VER:-未知}  → $(nvos_status_str)"
}

do_check() {
    echo "=== Q3400 版本检测（阶梯版 v${SCRIPT_VERSION}）==="
    assess_upgrade_needs
    echo "BIOS  当前: ${CUR_BIOS:-未知}  → $(need_status_str "${CUR_BIOS}" "${TARGET_BIOS_MATCH}")"
    echo "CPLD1 当前: ${CUR_CPLD1:-未知} → $(need_status_str "${CUR_CPLD1}" "${TARGET_CPLD1_MATCH}")"
    echo "NVOS  当前: ${CUR_NVOS_VER:-未知}  → $(nvos_status_str)"
    echo ""
    echo "NVOS 阶梯（来源: ${LADDER_DIR:-未找到}）:"
    print_ladder
    echo ""
    if needs_any_upgrade; then
        echo "结论: 需要升级"
        (( NEED_BIOS )) && echo "  - BIOS"
        (( NEED_CPLD )) && echo "  - CPLD"
        (( NEED_NVOS )) && echo "  - NVOS 逐级 ${CUR_NVOS_VER:-?} → ${FINAL_VER}"
    else
        echo "结论: 已全部达标，无需升级"
    fi
}

# ---------- cron / 状态 ----------
auto_delete_cron_if_done() {
    assess_upgrade_needs
    if needs_any_upgrade; then ALL_TARGETS_MET=0; return 1; fi
    remove_auto_hook
    rm -f "${STEP_FILE}" "${SRC}/.auto_enabled" "${BURN_DONE}" "${LAST_STAGE}" "${STAGE_COUNT}"
    sync
    ALL_TARGETS_MET=1
    log "已全部达标，cron 已自动删除"
    return 0
}

# 阶段循环护栏：连续同一 stage-id 超过 MAX 次则停 cron（防重启死循环）
stage_guard() {
    local id=$1 last count
    last=$(cat "${LAST_STAGE}" 2>/dev/null || echo "")
    if [[ "${last}" == "${id}" ]]; then
        count=$(cat "${STAGE_COUNT}" 2>/dev/null || echo 0)
        count=$(( count + 1 ))
    else
        count=1
    fi
    echo "${id}" > "${LAST_STAGE}"; echo "${count}" > "${STAGE_COUNT}"; sync
    if (( count > MAX_STAGE_RETRY )); then
        log "错误: 阶段 [${id}] 已重试 ${count} 次，疑似重启死循环，已停止 cron"
        log "请手动检查后续跑: bash ${SCRIPT} --run"
        remove_auto_hook
        exit 1
    fi
    log "阶段 [${id}] 第 ${count}/${MAX_STAGE_RETRY} 次执行"
}

create_dirs() {
    mkdir -p "${USB_MOUNT}" "${SRC}"
    mkdir -p /host/fw-images/bios /host/fw-images/cpld /host/nos-images
}

cleanup_macos_junk() {
    local dir f removed=0
    local -a dirs=("$@")
    ((${#dirs[@]})) || dirs=("${SRC}" /host/fw-images/bios /host/fw-images/cpld /host/nos-images)
    if mountpoint -q "${USB_MOUNT}" 2>/dev/null; then
        dirs+=("${USB_MOUNT}" "${USB_MOUNT}/bios" "${USB_MOUNT}/cpld" "${USB_MOUNT}/nvos")
    fi
    for dir in "${dirs[@]}"; do
        [[ -d "${dir}" ]] || continue
        while IFS= read -r -d '' f; do
            rm -f "${f}" 2>/dev/null || continue
            removed=$((removed + 1))
        done < <(find "${dir}" -maxdepth 2 \( -name '._*' -o -name '.DS_Store' \) -type f -print0 2>/dev/null)
    done
    (( removed > 0 )) && log "已清理 macOS 垃圾文件 ${removed} 个" || true
}

# 扫描 BIOS/CPLD 单文件
scan_bios_cpld() {
    local dir=$1
    BIOS_FILE=$(find_firmware "${dir}" '*.cab') \
        || BIOS_FILE=$(find_firmware "${dir}/bios" '*.cab') || true
    BURN_FILE=$(find_firmware "${dir}" '*burn*.vme') \
        || BURN_FILE=$(find_firmware "${dir}/cpld" '*burn*.vme') || true
    REFRESH_FILE=$(find_firmware "${dir}" '*refresh*.vme') \
        || REFRESH_FILE=$(find_firmware "${dir}/cpld" '*refresh*.vme') || true
}

# 确定固件来源目录（BIOS/CPLD 存在或有 NVOS 镜像即可）
resolve_source_dir() {
    local script_dir d
    script_dir=$(cd "$(dirname "$0")" && pwd)
    for d in "${USB_MOUNT}" "${script_dir}" "${SRC}"; do
        [[ "${d}" == "${USB_MOUNT}" ]] && { mountpoint -q "${USB_MOUNT}" 2>/dev/null || continue; }
        BIOS_FILE=""; BURN_FILE=""; REFRESH_FILE=""
        scan_bios_cpld "${d}"
        if [[ -n "${BIOS_FILE}${BURN_FILE}${REFRESH_FILE}" ]] || build_nvos_ladder "${d}"; then
            SOURCE_DIR="${d}"; return 0
        fi
    done
    return 1
}

save_manifest() {
    cat > "${MANIFEST}" <<EOF
SCRIPT_VERSION=${SCRIPT_VERSION}
SOURCE_DIR=${SOURCE_DIR}
BIOS_FILE=$(basename "${BIOS_FILE:-}")
BURN_FILE=$(basename "${BURN_FILE:-}")
REFRESH_FILE=$(basename "${REFRESH_FILE:-}")
LADDER=$(printf '%s ' "${LADDER_VERS[@]}")
FINAL_VER=${FINAL_VER}
PREPARED_AT=$(date '+%Y-%m-%dT%H:%M:%S')
EOF
}

# 把 BIOS/CPLD + "当前版本以上"的 NVOS 镜像拷到 SRC（重启后仍可用）
stage_to_src() {
    local i k f copied=0
    [[ -n "${BIOS_FILE}"    && "$(dirname "${BIOS_FILE}")"    != "${SRC}" ]] && { cp -f "${BIOS_FILE}"    "${SRC}/"; copied=1; }
    [[ -n "${BURN_FILE}"    && "$(dirname "${BURN_FILE}")"    != "${SRC}" ]] && { cp -f "${BURN_FILE}"    "${SRC}/"; copied=1; }
    [[ -n "${REFRESH_FILE}" && "$(dirname "${REFRESH_FILE}")" != "${SRC}" ]] && { cp -f "${REFRESH_FILE}" "${SRC}/"; copied=1; }
    for i in "${!LADDER_KEYS[@]}"; do
        k="${LADDER_KEYS[$i]}"; f="${LADDER_FILES[$i]}"
        (( k > CUR_NVOS_KEY )) || continue          # 只拷需要升级的镜像
        [[ "$(dirname "${f}")" == "${SRC}" ]] && continue
        [[ -f "${SRC}/$(basename "${f}")" ]] && continue
        log "拷贝镜像到 ${SRC}: $(basename "${f}") ($(du -h "${f}" 2>/dev/null | cut -f1))"
        cp -f "${f}" "${SRC}/"; copied=1
    done
    (( copied )) && sync
    # 重建阶梯，使 LADDER_FILES 指向 SRC（重启后 U 盘卸载也不受影响）
    LADDER_DIR=""; build_nvos_ladder "${SRC}" || true
    compute_next_rung || true
}

check_space() {
    local need_kb avail_kb i k f
    need_kb=0
    for i in "${!LADDER_KEYS[@]}"; do
        k="${LADDER_KEYS[$i]}"; f="${LADDER_FILES[$i]}"
        (( k > CUR_NVOS_KEY )) || continue
        need_kb=$(( need_kb + $(du -k "${f}" 2>/dev/null | cut -f1 || echo 0) ))
    done
    avail_kb=$(df -k "${SRC}" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "${avail_kb}" ]] && (( need_kb > 0 && avail_kb < need_kb )); then
        log "警告: ${SRC} 可用空间 $((avail_kb/1024))MB 可能不足（需约 $((need_kb/1024))MB 暂存镜像）"
        log "  建议将 NVOS 镜像放在 U 盘上运行，或分批升级"
    fi
}

ensure_prepared() {
    cleanup_macos_junk
    if ! resolve_source_dir; then
        log "错误: 未找到固件"
        log "请挂载 U 盘 (mount /dev/sdX1 ${USB_MOUNT}) 或 scp 固件到 ${SRC}"
        log "需要: *.cab / *burn*.vme / *refresh*.vme / nvos*.bin"
        exit 1
    fi
    log "固件来源: ${SOURCE_DIR}"
    [[ -n "${BIOS_FILE}"    ]] && log "  BIOS:    $(basename "${BIOS_FILE}")"
    [[ -n "${BURN_FILE}"    ]] && log "  BURN:    $(basename "${BURN_FILE}")"
    [[ -n "${REFRESH_FILE}" ]] && log "  REFRESH: $(basename "${REFRESH_FILE}")"
    (( ${#LADDER_VERS[@]} )) && log "  NVOS 阶梯: ${LADDER_VERS[*]}"

    if [[ "${SOURCE_DIR}" != "${SRC}" ]]; then
        check_space
        stage_to_src
    fi
    # BIOS/CPLD 文件名改为 basename（供 nv action 使用）
    BIOS_FILE=$(basename "${BIOS_FILE:-}"); [[ -n "${BIOS_FILE}" ]] || BIOS_FILE=""
    BURN_FILE=$(basename "${BURN_FILE:-}"); [[ -n "${BURN_FILE}" ]] || BURN_FILE=""
    REFRESH_FILE=$(basename "${REFRESH_FILE:-}"); [[ -n "${REFRESH_FILE}" ]] || REFRESH_FILE=""
    save_manifest
    log "固件已就绪: ${SRC}/"
}

# ---------- 部署 ----------
require_bios()  { [[ -n "${BIOS_FILE}"    ]] || { log "未找到 BIOS 固件 (*.cab)"; exit 1; }; }
require_cpld()  { [[ -n "${BURN_FILE}" && -n "${REFRESH_FILE}" ]] || { log "未找到 CPLD 固件 (*burn*.vme + *refresh*.vme)"; exit 1; }; }
require_nvos_rung() { [[ -n "${NEXT_NVOS_FILE}" && -f "${NEXT_NVOS_FILE}" ]] || { log "未找到下一级 NVOS 镜像"; exit 1; }; }

deploy_bios() {
    require_bios
    cleanup_macos_junk /host/fw-images/bios "${SRC}"
    rm -f /host/fw-images/bios/._*
    cp -f "${SRC}/${BIOS_FILE}" /host/fw-images/bios/
    log "BIOS → /host/fw-images/bios/${BIOS_FILE}"
}

deploy_cpld() {
    require_cpld
    cleanup_macos_junk /host/fw-images/cpld "${SRC}"
    cp -f "${SRC}/${BURN_FILE}"    /host/fw-images/cpld/
    cp -f "${SRC}/${REFRESH_FILE}" /host/fw-images/cpld/
    log "CPLD → /host/fw-images/cpld/"
}

# NVOS 升级前备份配置（存到 /host/tmp/config-backups，跨分区保留，含时间戳）
# 升级默认保留配置，但跨版本迁移可能出岔子，备份是零风险的保险
backup_config() {
    local tag=${1:-nvos}
    mkdir -p "${CONFIG_BACKUP_DIR}"
    local ts f
    ts=$(date '+%Y%m%d-%H%M%S')
    f="${CONFIG_BACKUP_DIR}/config-${tag}-${CUR_NVOS_VER:-unknown}-${ts}.txt"
    set +e
    if nv config show -o commands > "${f}" 2>/dev/null && [[ -s "${f}" ]]; then
        log "配置已备份: ${f} ($(wc -l < "${f}") 行)"
    else
        # 退回旧命令名（部分版本无 -o commands）
        nv config show > "${f}" 2>/dev/null
        if [[ -s "${f}" ]]; then
            log "配置已备份(基本格式): ${f}"
        else
            rm -f "${f}"
            log "警告: 配置备份失败（nv config show 无输出），继续升级"
        fi
    fi
    # 额外记录带外管理口 IP（eth0 常单独管理）
    local eth0f="${CONFIG_BACKUP_DIR}/eth0-${ts}.txt"
    nv show interface eth0 ip address > "${eth0f}" 2>/dev/null || true
    [[ -s "${eth0f}" ]] && log "带外 eth0 IP 已记录: ${eth0f}" || rm -f "${eth0f}"
    set -e
}

# 把下一级镜像放到 /host/nos-images（先清旧 .bin 腾空间）
deploy_nvos_rung() {
    require_nvos_rung
    local base
    base=$(basename "${NEXT_NVOS_FILE}")
    cleanup_macos_junk /host/nos-images
    find /host/nos-images -maxdepth 1 -type f -iname '*.bin' ! -name "${base}" -delete 2>/dev/null || true
    cp -f "${NEXT_NVOS_FILE}" /host/nos-images/
    log "NVOS → /host/nos-images/${base}"
    echo "${base}"
}

install_auto_hook() {
    remove_auto_hook
    chmod +x "${SCRIPT}" 2>/dev/null || true
    local boot_cmd="sleep ${BOOT_WAIT} && ${SCRIPT} --boot --internal >> ${LOG} 2>&1"
    if [[ -d /etc/cron.d ]]; then
        printf '%s\n@reboot root %s\n' "${CRON_MARKER}" "${boot_cmd}" > /etc/cron.d/q3400-upgrade-ladder
    elif command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "${CRON_MARKER}" | grep -v "q3400-upgrade-ladder.sh" || true
         echo "${CRON_MARKER}"; echo "@reboot ${boot_cmd}") | crontab - || log "警告: crontab 注册失败"
    else
        log "错误: 未找到 cron"; exit 1
    fi
    log "已注册开机自动续跑"
}

remove_auto_hook() {
    local had=0
    [[ -f /etc/cron.d/q3400-upgrade-ladder ]] && had=1
    rm -f /etc/cron.d/q3400-upgrade-ladder
    if command -v crontab >/dev/null 2>&1; then
        local old new
        old=$(crontab -l 2>/dev/null || true)
        if grep -qE "${CRON_MARKER}|q3400-upgrade-ladder\.sh" <<< "${old}"; then
            had=1
            new=$(grep -vE "${CRON_MARKER}|q3400-upgrade-ladder\.sh" <<< "${old}" || true)
            if [[ -n "${new}" ]]; then printf '%s\n' "${new}" | crontab - || log "警告: crontab 更新失败"
            else crontab -r 2>/dev/null || true; fi
        fi
    fi
    (( had )) && log "已删除 cron 自动检查" || true
}

do_unhook() {
    remove_auto_hook
    rm -f "${SRC}/.auto_enabled"
    echo "cron 自动检查已清理"
}

acquire_lock() { mkdir "${LOCK_DIR}" 2>/dev/null || { log "已有任务在运行，日志: tail -f ${LOG}"; exit 1; }; }
release_lock() { rmdir "${LOCK_DIR}" 2>/dev/null || true; }

show_versions() {
    log ">>> 版本信息"
    set +e
    nv show platform firmware BIOS
    nv show platform firmware CPLD1
    nv show system image
    set -e
}

do_status() {
    echo "=== Q3400 升级状态（阶梯版 v${SCRIPT_VERSION}）==="
    echo "脚本: ${SCRIPT} ($(wc -l < "${SCRIPT}" 2>/dev/null || echo '?') 行)"
    assess_upgrade_needs
    echo "BIOS  当前: ${CUR_BIOS:-未知}  → $(need_status_str "${CUR_BIOS}" "${TARGET_BIOS_MATCH}")"
    echo "CPLD1 当前: ${CUR_CPLD1:-未知} → $(need_status_str "${CUR_CPLD1}" "${TARGET_CPLD1_MATCH}")"
    echo "NVOS  当前: ${CUR_NVOS_VER:-未知}  → $(nvos_status_str)"
    echo ""
    echo "NVOS 阶梯（来源: ${LADDER_DIR:-未找到}）:"
    print_ladder
    echo ""
    echo "已安装分区镜像（允许: ${ALLOWED_NVOS_VERS[*]}）:"
    print_partitions
    echo ""
    [[ -f "${BURN_DONE}" ]] && echo "CPLD burn: 已完成（待 refresh）"
    [[ -f "${LAST_STAGE}" ]] && echo "上一阶段: $(cat "${LAST_STAGE}") 第 $(cat "${STAGE_COUNT}" 2>/dev/null || echo '?')/${MAX_STAGE_RETRY} 次"
    echo "U 盘: $(mountpoint -q "${USB_MOUNT}" 2>/dev/null && echo "已挂载" || echo "未挂载")"
    echo "日志: ${LOG}"
    [[ -f "${MANIFEST}" ]] && { echo ""; echo "--- 已识别固件 ---"; cat "${MANIFEST}"; }
    echo ""
    tail -10 "${LOG}" 2>/dev/null || echo "无日志"
}

do_reset() {
    remove_auto_hook
    rm -f "${STEP_FILE}" "${MANIFEST}" "${SRC}/.auto_enabled" "${BURN_DONE}" "${LAST_STAGE}" "${STAGE_COUNT}"
    rmdir "${LOCK_DIR}" 2>/dev/null || true
    cleanup_macos_junk
    log "已重置"
}

# ---------- 核心：单步执行（cron 每次重启调用一次）----------
run_stage() {
    assess_upgrade_needs
    log_upgrade_plan

    if ! needs_any_upgrade; then
        auto_delete_cron_if_done || true
        log "全部达标，无需升级"
        show_versions
        # 收尾：清理 standby 上非 8008/1010 的镜像
        check_installed_images enforce || log "注意: 仍存在非法镜像（运行中分区无法删，需切换后再清）"
        return 0
    fi

    if (( NEED_BIOS )); then
        stage_guard "bios"
        log ">>> BIOS 升级 [${BIOS_FILE}]"
        deploy_bios
        nv action install platform firmware BIOS files "${BIOS_FILE}" skip-reboot force
        log "BIOS 安装完成，即将重启"
        nv action reboot system force
        return 0
    fi

    if (( NEED_CPLD )); then
        stage_guard "cpld"
        deploy_cpld
        if [[ ! -f "${BURN_DONE}" ]]; then
            log ">>> CPLD burn [${BURN_FILE}]"
            nv action install platform firmware CPLD1 files "${BURN_FILE}" skip-reboot force
            touch "${BURN_DONE}"; sync
            log "burn 完成（已标记，重启后跳过 burn）"
        else
            log ">>> CPLD burn 已完成，跳过"
        fi
        log ">>> CPLD refresh [${REFRESH_FILE}]（将自动重启）"
        nv action install platform firmware CPLD1 files "${REFRESH_FILE}" force
        log "CPLD refresh 命令已执行"
        return 0
    fi

    if (( NEED_NVOS )); then
        compute_next_rung || { log "错误: 需要 NVOS 升级但找不到下一级镜像"; exit 1; }
        stage_guard "nvos:${NEXT_NVOS_VER}"
        log ">>> NVOS 逐级升级: ${CUR_NVOS_VER:-未知} → ${NEXT_NVOS_VER}（终点 ${FINAL_VER}，默认保留配置）"
        rm -f "${BURN_DONE}"; sync
        backup_config "nvos-${NEXT_NVOS_VER}"
        local base
        base=$(deploy_nvos_rung)
        nv action install system image files "${base}" force
        log "NVOS ${NEXT_NVOS_VER} 安装完成，即将重启"
        if (( NEXT_NVOS_KEY < FINAL_KEY )); then
            log "⚠ NVOS 升级会切换分区，cron 不跨分区续跑。重启进入 ${NEXT_NVOS_VER} 后，"
            log "  请手动执行下一跳: bash ${SCRIPT} --auto   （直到到达 ${FINAL_VER}）"
        else
            log "这是最后一级 → ${FINAL_VER}。重启后执行验收: bash ${SCRIPT} --verify"
        fi
        return 0
    fi

    log "未知状态，请 --check 或 --reset"
    exit 1
}

maybe_background() {
    local mode=$1
    if [[ -z "${Q3400_UPGRADE_BG:-}" && "${BACKGROUND}" -eq 1 && "${INTERNAL}" -eq 0 ]]; then
        nohup env Q3400_UPGRADE_BG=1 bash "${SCRIPT:-$0}" "${mode}" --internal >> "${LOG}" 2>&1 &
        echo "已在后台启动 (PID $!)，日志: tail -f ${LOG}"
        exit 0
    fi
}

with_lock() {
    [[ "${INTERNAL}" -eq 1 ]] && rmdir "${LOCK_DIR}" 2>/dev/null || true
    acquire_lock
    trap release_lock EXIT
    "$@"
}

# 把当前脚本复制到 SRC（供 cron 稳定调用）
copy_self_to_src() {
    local self
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    if [[ "${self}" != "${SCRIPT}" ]]; then
        cp -f "${self}" "${SCRIPT}" 2>/dev/null || true
        sed -i 's/\r$//' "${SCRIPT}" 2>/dev/null || true
        chmod +x "${SCRIPT}" 2>/dev/null || true
    fi
}

# ===================== 主流程 =====================
create_dirs
cleanup_macos_junk

# 只读/诊断命令
case "${ACTION}" in
check)
    do_check
    echo ""
    echo "已安装分区镜像:"
    print_partitions
    exit 0 ;;
status) do_status; exit 0 ;;
unhook) do_unhook; exit 0 ;;
backup)
    read_current_versions
    backup_config "manual"
    echo "备份目录: ${CONFIG_BACKUP_DIR}"
    ls -lh "${CONFIG_BACKUP_DIR}" 2>/dev/null || true
    exit 0 ;;
list_images)
    echo "=== 已安装 NVOS 分区镜像（允许: ${ALLOWED_NVOS_VERS[*]}）==="
    print_partitions
    exit 0 ;;
clean_images)
    check_installed_images enforce || log "注意: 仍存在非法镜像（可能是运行中分区，需先切换版本）"
    echo ""
    echo "清理后分区状态:"
    print_partitions
    exit 0 ;;
verify)
    show_versions
    auto_delete_cron_if_done || true
    if (( ALL_TARGETS_MET )); then
        rm -f "${MANIFEST}"
        log "验收完成 — NVOS 已达最高版本 ${FINAL_VER}"
        # 达标后自动清理 standby 上的非法镜像（仅 8008/1010 允许）
        check_installed_images enforce || log "注意: 仍存在非法镜像（运行中分区无法删，需切换后再清）"
    fi
    exit 0 ;;
reset)  do_reset; echo "下一步: bash ${SCRIPT} --auto"; exit 0 ;;
esac

copy_self_to_src

# 每次运行先检测，全部达标则自动删 cron
auto_delete_cron_if_done || true
case "${ACTION}" in
auto|boot|run)
    if (( ALL_TARGETS_MET )); then
        show_versions
        echo "已全部达标，无需升级（cron 已自动删除）"
        exit 0
    fi ;;
esac

# 准备固件（auto/boot/run/bios/cpld/nvos 都需要）
ensure_prepared
assess_upgrade_needs
case "${ACTION}" in
    auto|boot|run)
        (( NEED_BIOS )) && require_bios
        (( NEED_CPLD )) && require_cpld
        (( NEED_NVOS )) && { compute_next_rung || true; require_nvos_rung; } ;;
    bios) require_bios ;;
    cpld) require_cpld ;;
    nvos) compute_next_rung || true; require_nvos_rung ;;
esac

case "${ACTION}" in
auto)
    install_auto_hook
    touch "${SRC}/.auto_enabled"
    nohup env Q3400_UPGRADE_BG=1 bash "${SCRIPT}" --boot --internal >> "${LOG}" 2>&1 &
    echo "已在后台启动 (PID $!)"
    echo "NVOS 阶梯: ${LADDER_VERS[*]:-无}  终点: ${FINAL_VER:-?}"
    echo "日志: tail -f ${LOG}"
    echo "全部完成后: bash ${SCRIPT} --verify"
    ;;
boot)
    maybe_background --boot
    rmdir "${LOCK_DIR}" 2>/dev/null || true
    [[ "${INTERNAL}" -eq 1 ]] && log "开机自检续跑"
    with_lock run_stage
    ;;
run)
    maybe_background --run
    with_lock run_stage
    ;;
bios)
    maybe_background --bios
    deploy_bios
    nv action install platform firmware BIOS files "${BIOS_FILE}" skip-reboot force
    log "BIOS 安装完成，即将重启"
    nv action reboot system force
    ;;
cpld)
    maybe_background --cpld
    deploy_cpld
    nv action install platform firmware CPLD1 files "${BURN_FILE}" skip-reboot force
    touch "${BURN_DONE}"; sync
    nv action install platform firmware CPLD1 files "${REFRESH_FILE}" force
    ;;
nvos)
    maybe_background --nvos
    backup_config "nvos-${NEXT_NVOS_VER}"
    base=$(deploy_nvos_rung)
    log ">>> NVOS 单跳升级: ${CUR_NVOS_VER:-未知} → ${NEXT_NVOS_VER}"
    nv action install system image files "${base}" force
    ;;
esac
