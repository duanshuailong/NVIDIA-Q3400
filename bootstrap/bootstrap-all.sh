#!/usr/bin/env bash
# 批量初始化新交换机：对清单里每台跑一次改密码 + 装公钥
#
# 用法:
#   ./bootstrap-all.sh <IP列表文件> <旧密码> <新密码> [公钥文件]
#   IP列表文件: 一行一个 IP（# 开头的行忽略）
#   例:
#     ./bootstrap-all.sh ips.txt admin 'NewPass@2026' ~/.ssh/id_ed25519.pub
#
# 也可直接传 IP（逗号分隔）代替文件:
#     ./bootstrap-all.sh 192.168.1.58,192.168.1.59 admin 'NewPass@2026' ~/.ssh/id_ed25519.pub
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP="${SCRIPT_DIR}/bootstrap-switch.exp"

LIST="${1:-}"
OLDPASS="${2:-}"
NEWPASS="${3:-}"
PUBKEY="${4:-$HOME/.ssh/id_ed25519.pub}"

if [[ -z "$LIST" || -z "$OLDPASS" || -z "$NEWPASS" ]]; then
    echo "用法: $0 <IP列表文件|逗号分隔IP> <旧密码> <新密码> [公钥文件]" >&2
    exit 1
fi
[[ -x "$EXP" ]] || chmod +x "$EXP"

# 组装 IP 列表
ips=()
if [[ -f "$LIST" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
        [[ -n "$line" ]] && ips+=("$line")
    done < "$LIST"
else
    IFS=',' read -r -a ips <<< "$LIST"
fi

(( ${#ips[@]} )) || { echo "错误: 没有解析到任何 IP" >&2; exit 1; }

echo "将初始化 ${#ips[@]} 台: ${ips[*]}"
ok=0; fail=0
for ip in "${ips[@]}"; do
    echo "==================== $ip ===================="
    if "$EXP" "$ip" "$OLDPASS" "$NEWPASS" "$PUBKEY"; then
        ok=$((ok+1))
    else
        fail=$((fail+1)); echo "!!! $ip 初始化失败"
    fi
done
echo "===================================================="
echo "完成: 成功 ${ok} / 失败 ${fail}"
echo "下一步: 把新密码填进 group_vars（或已装公钥则免密），跑 ansible-playbook playbooks/00-ping.yml"
