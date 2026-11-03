# Q3400 交换机批量升级 (Ansible)

从 Mac 用 Ansible 批量驱动 Q3400 交换机执行阶梯升级（BIOS → CPLD → NVOS 逐级）。
Ansible 从本机 SSH 驱动，每跳后等交换机重启恢复再触发下一跳，**天然跨 NVOS 分区**
（不依赖交换机 cron）。

`10-stage.yml` 一次推送脚本 + BIOS/CPLD 固件 + NVOS 大镜像（每个约 2.7GB）到交换机
`/host/tmp`，`20-upgrade.yml` 编排升级。固件/镜像下载见 `packages/README.md`。

## 快速开始

```bash
cd /path/to/ansible

# 0. 填 IP：编辑 inventory/hosts.ini，[q3400] 下一行一台
# 1. 自检（只读：能否连、能否 sudo、nv 版本）
ansible-playbook playbooks/00-ping.yml

# 2.【升级前必做】密码写进 nv config 层，否则升级后密码丢（见「密码持久化」）
ansible-playbook playbooks/40-set-password.yml -e new_admin_password='admin'

# 3. 推送脚本 + 固件 + 大镜像到各交换机 /host/tmp（大文件，较慢）
#    推之前先清掉交换机上旧的 .bin（见「推送文件」）
ansible-playbook playbooks/10-stage.yml

# 4. 批量升级（逐台：备份 → 逐跳升级 → 验收）
ansible-playbook playbooks/20-upgrade.yml
#   只升某几台:  -l 192.0.2.4

# 随时看状态（只读）
ansible-playbook playbooks/30-status.yml
```

机器多时建议先对一台跑通全流程，再批量。

## 目录结构

```
ansible/
├── ansible.cfg                      # 连接/并发/超时配置
├── inventory/
│   ├── hosts.ini                    # 交换机 IP 清单（[q3400]）
│   └── group_vars/q3400.yml         # 用户、密码、文件路径、镜像列表、超时
├── playbooks/
│   ├── 00-ping.yml                  # 连通性 + sudo + nv 自检（只读）
│   ├── 10-stage.yml                 # 推脚本 + 固件 + 镜像到 /host/tmp
│   ├── 20-upgrade.yml               # 主编排：备份 + 逐跳升级 + 验收
│   ├── 30-status.yml                # 批量状态查看（只读）
│   ├── 40-set-password.yml          # 密码写进 nv config 层，跨升级保留
│   └── tasks/one_hop.yml            # 单跳逻辑（被 20 循环调用）
├── scripts/q3400-upgrade-ladder.sh  # 阶梯升级脚本（推到交换机执行）
├── packages/                        # 固件 + 镜像（不入库，下载见 packages/README.md）
└── README.md
```

> `group_vars` 必须放在 `inventory/group_vars/`（挨着 `hosts.ini`）。放项目根目录
> `ansible-playbook` 读不到，会用 Mac 本地用户名登录导致 `Permission denied`。

> 项目自包含：`group_vars` 用 `{{ playbook_dir }}/..` 引用路径，整个目录可整体拷走或改名。

## 推送文件（10-stage.yml）

**文件必须落在交换机的 `/host/tmp`**：升级脚本优先扫这里，且 `/host` 分区跨升级重启保留。

`10-stage.yml` 默认全推：升级脚本 + BIOS/CPLD 固件 + NVOS 镜像，推送内容由
`group_vars/q3400.yml` 决定：

```yaml
local_firmware_dir: "{{ playbook_dir }}/../packages"   # 固件目录
local_images_dir:   "{{ playbook_dir }}/../packages"   # 镜像目录
nvos_images:                                            # 要推的镜像（决定阶梯）
  - "nvosv25-02-7002amd64.bin"
  - "nvos-amd64-25.02.8008.bin"
  - "nvos-amd64-25.03.1010.bin"
firmware_files: ["0ACQF.cab", "burn.vme", "refresh.vme"]  # BIOS/CPLD 已达标可设 []
```

```bash
# 推之前先清掉交换机上旧的 .bin，避免旧版本混进阶梯（playbook 不会自动清）
ansible q3400 -b -m raw -a 'rm -f /host/tmp/*.bin'

# 全推（脚本 + 固件 + 镜像）
ansible-playbook playbooks/10-stage.yml
```

已推过镜像、只想更新脚本或固件时，可以关掉对应开关：

```bash
ansible-playbook playbooks/10-stage.yml -e push_images=false                       # 脚本 + 固件
ansible-playbook playbooks/10-stage.yml -e push_images=false -e push_firmware=false # 只推脚本
```

> 镜像体积大，单台推送耗时较长；`forks = 10` 时会同时向多台推，注意 Mac 出口带宽。

### 阶梯 = /host/tmp 里的 .bin

脚本扫描 `/host/tmp` 下所有 `.bin`，**按版本号自动排序成升级阶梯**，从当前版本的下一级升到最高版本：

- 逐级（6077 → 7002 → 8008 → 1010）：`nvos_images` 放 7002 / 8008 / 1010
- 跳级（6077 → 8008 → 1010）：只放 8008 / 1010（能否跳取决于 NVOS）

阶梯以 `/host/tmp` 里实际存在的 `.bin` 为准，所以推送前务必清掉不需要的旧镜像。

## 密码持久化（升级前必做）

NVOS 有两套密码存储：

| 存储 | 修改方式 | 升级换分区后 |
|------|---------|-------------|
| Linux 层（`/etc/shadow`） | 首登交互改密 / `passwd` | **丢**，新分区回出厂 `admin/admin` |
| NVOS 配置层（`nv config`） | `nv set system aaa user admin password` + `nv config save` | **保留**，随 startup 配置迁移 |

NVOS 升级 = 装全新镜像到另一分区，只改了 Linux 层的密码每跳都会回默认（eth0 IP 等在
nv config 里的配置保留）。所以升级前先跑 `40-set-password.yml`：

```bash
# 当前密码与 group_vars 一致：
ansible-playbook playbooks/40-set-password.yml -e new_admin_password='admin'

# 机器当前是出厂 admin/admin（或已被升级重置）时，临时覆盖登录密码：
ansible-playbook playbooks/40-set-password.yml -l <IP> \
  -e ansible_password=admin -e ansible_become_password=admin \
  -e new_admin_password='admin'
```

它依次执行 `nv set system aaa user admin password` → `nv config apply` → `nv config save`，
其中 `nv config save` 是跨升级保留的关键。

> `nv config apply` 暂用 `--assume-yes` 非交互，若真机报错先 `nv config apply --help` 核对。

> 出厂新机首次 SSH 会强制交互改密，Ansible 会卡住。新机先手动 `ssh admin@<IP>` 走完改密流程再纳入清单。

## 工作原理

`20-upgrade.yml` 默认 `serial: 1` 逐台执行：

1. 确认 `/host/tmp/q3400-upgrade-ladder.sh` 已就位（否则先跑 `10-stage.yml`）
2. `--backup` 备份配置到 `/host/tmp/config-backups`（含带外 eth0 IP）
3. 循环 `tasks/one_hop.yml`，最多 `max_iterations` 跳，每跳：
   - `--check` 判断是否已全部达标，达标则结束循环
   - 未达标则**同步**执行 `--run` 跑一个阶段（BIOS / CPLD / 一级 NVOS），日志写
     `/host/tmp/q3400-upgrade.log`；触发重启导致 SSH 断开属正常，会被忽略
   - `pause` + `wait_for_connection` 等重启后 SSH 恢复，读回当前版本
4. 全部达标后 `--verify` 收尾：清 cron，并删除 standby 分区上非 `25.02.8008` / `25.03.1010` 的镜像
   （允许列表见脚本 `ALLOWED_NVOS_VERS`）

已在目标版本的机器首次 `--check` 即返回「已全部达标」，不升级、不重启，只做备份和 `--verify`。

> `--run` 必须同步阻塞执行，切勿后台化，否则任务秒返回，后续等待空转、不会真正升级。

达到最大跳数仍未完成会打印警告，登录查看：`tail -50 /host/tmp/q3400-upgrade.log`。

## 主要参数（group_vars/q3400.yml）

| 变量 | 默认 | 说明 |
|------|------|------|
| `ansible_user` | `admin` | SSH 用户 |
| `ansible_password` / `ansible_become_password` | `admin`（占位） | 登录 / sudo 密码，需与 `40-set-password` 设置的一致 |
| `max_iterations` | `8` | 单台最多跳数（BIOS + CPLD + NVOS 阶梯） |
| `reboot_timeout` | `900` | 每跳等待 SSH 恢复的最长秒数 |
| `reboot_delay` | `30` | 重启后开始探测 SSH 前的延迟秒数 |

`ansible.cfg` 里 `forks = 10` 控制并行台数；要并行升级可删掉 `20-upgrade.yml` 里的 `serial: 1`（慎用）。

## 认证与密码

密码登录需 Mac 装 `sshpass`（`brew install sshpass`）；也可用 `ssh-copy-id` 装公钥免密。

仓库里的密码都是占位符，**真实密码不要提交到 git**。推荐本地 `secrets.yml`（已在 `.gitignore`）：

```yaml
# secrets.yml
ansible_password: "实际密码"
ansible_become_password: "实际密码"
```

```bash
ansible-playbook playbooks/20-upgrade.yml -e @secrets.yml
```

或用 `ansible-vault create secrets.yml`，运行时加 `--ask-vault-pass`。

## 注意

- 升级默认保留配置，且每台升级前自动备份；降级才会丢配置。
- 镜像必须在 `/host/tmp`，推送前先清旧 `.bin`。
- 除 `10-stage.yml` 推文件用 `copy` 模块（需交换机有 Python）外，其余任务都用 `raw` 模块。
- 升级会多次重启交换机，请在维护窗口执行。

## 免责声明

- 本项目为个人整理的运维工具，非 NVIDIA 官方产品，与 NVIDIA 无任何关联，也未获其认可或支持。
- 脚本和文档按「现状」提供，不附带任何明示或暗示的担保，包括但不限于适销性、特定用途适用性及不侵权的担保。
- 固件/系统升级存在设备变砖、配置丢失、业务中断等风险。使用前请自行评估，先在测试设备上验证，并做好配置备份。
- 因使用本项目造成的任何直接或间接损失（包括设备损坏、数据丢失、业务中断等），作者概不负责，风险由使用者自行承担。
- 固件和 NVOS 镜像的版权归 NVIDIA 所有，本仓库不包含这些文件。`packages/README.md` 中的网盘链接仅供参考，请优先通过官方渠道获取并遵守其许可条款。
