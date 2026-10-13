# Q3400 交换机批量升级 (Ansible)

从 Mac 用 Ansible 批量驱动 Q3400 交换机执行阶梯升级（BIOS→CPLD→NVOS 逐级）。
Ansible 从本机 SSH 驱动，每跳后等交换机重启恢复再触发下一跳，**天然跨 NVOS 分区**
（不依赖交换机 cron，解决了脚本本地运行时 cron 不跨分区的限制）。

大镜像（每个约 2.7GB）**推荐你自己手动拷贝**到交换机，Ansible 只推脚本 + 编排升级。
见下面「镜像手动拷贝」。

## Playbook 怎么用（精简）

```bash
cd /path/to/ansible

# 0. 填 IP：编辑 inventory/hosts.ini，[q3400] 下一行一台
# 1. 自检（只读，能不能连、能不能 sudo）
ansible-playbook playbooks/00-ping.yml

# 2. 手动拷镜像到各交换机 /host/tmp（见「镜像手动拷贝」）

# 3. 推脚本（不推大镜像，你已手动拷了）
ansible-playbook playbooks/10-stage.yml -e push_images=false -e push_firmware=false

# 4. 批量升级（逐台，自动备份 + 逐跳升 + 验收）
ansible-playbook playbooks/20-upgrade.yml
#   只升某几台:  -l 192.0.2.4

# 随时看状态（只读）
ansible-playbook playbooks/30-status.yml
```

顺序就是编号 `00 → 10 → 20`。日常最常跑的是 `20`（升级）和 `30`（看状态）。

### 镜像路径变动了怎么办

看你用哪种方式，改的地方不同：

- **手动拷镜像（推荐，当前用法）**：镜像路径变了，**只改你敲的 `scp` 命令里的路径**，
  playbook 和配置**一个字都不用动**——Ansible 不碰 Mac 上的镜像，只负责推脚本 + 编排。

- **让 Ansible 帮你推镜像**（跑 `10-stage.yml` 不加 `push_images=false` 时）：路径写在
  **`inventory/group_vars/q3400.yml`** 里，改这几行即可，改完照常跑，无需改 playbook：

  ```yaml
  local_script:       "{{ playbook_dir }}/../scripts/q3400-upgrade-ladder.sh"  # 脚本
  local_firmware_dir: "{{ playbook_dir }}/../packages"        # 固件（与镜像同目录）
  local_images_dir:   "{{ playbook_dir }}/../packages"        # 镜像（与固件同目录）
  nvos_images:                                                 # 要推哪些镜像（文件名）
    - "nvos-amd64-25.03.1010.bin"
  ```

  > 默认已指向项目内 `packages/`，换版本只需把新 `.bin` 放进 `packages/` 并改 `nvos_images` 列表。

  路径挪了改 `local_images_dir`；换了别的版本改 `nvos_images` 列表。playbook 里全是变量引用，从不写死路径。

## 目录结构

```
ansible/
├── ansible.cfg                      # 连接/并发/超时配置
├── inventory/
│   ├── hosts.ini                    # 交换机 IP 清单（[q3400]）
│   └── group_vars/q3400.yml         # 用户、密码、文件路径、镜像列表、超时
├── playbooks/
│   ├── 00-ping.yml                  # 连通性 + sudo + nv 自检
│   ├── 40-set-password.yml          # 密码写进 nv config 层，跨升级保留（升级前必做）
│   ├── 10-stage.yml                 # 推送脚本（+可选固件/镜像）到 /host/tmp
│   ├── 20-upgrade.yml               # 主编排：逐跳升级到目标版本 + 验收
│   ├── 50-set-version.yml           # 指定版本直达（可升可降/回退）+ 重启后清理多余分区
│   ├── 30-status.yml                # 只读批量状态查看
│   ├── 99-remove-key.yml            # 删除 bootstrap 装的公钥
│   └── tasks/one_hop.yml            # 单跳逻辑（被 20 循环调用）
├── scripts/q3400-upgrade-ladder.sh  # 阶梯升级脚本（推给交换机）
├── scripts/q3400-set-version.sh     # 指定版本切换脚本（可升可降/回退，供 50 用）
├── packages/                        # 固件 + 镜像统一放这（*.cab / *.vme / *.bin），不入库，网盘下载见 packages/README.md
├── bootstrap/                       # 新机首次初始化（改密码 + 装公钥）
└── README.md
```

> **本项目自包含**：脚本/固件/镜像都在项目内，`group_vars` 用 `{{ playbook_dir }}/..`
> 引用，整个 `ansible/` 目录可整体拷走或改名，路径不用动。

> **注意 `group_vars` 的位置**：必须放在 `inventory/group_vars/`（挨着 `hosts.ini`），
> 不能放项目根目录。否则 `ansible-playbook` 找不到它，会用你 Mac 的本地用户名登录导致
> `Permission denied`。（ad-hoc `ansible q3400 ...` 能读到根目录的，但 playbook 不行。）

## 镜像手动拷贝（重点）

大镜像自己拷，比 Ansible 推更快更可控。**关键：镜像必须落在交换机的 `/host/tmp`。**

### 为什么是 `/host/tmp`

升级脚本按这个顺序找镜像，`/host/tmp` 优先级最高：

```
1) /host/tmp            ← SRC，脚本第一个扫这里（也是本套 Ansible 用的路径）
2) /home/admin/tmp      ← 仅当它是真正的 U 盘挂载点时才扫
3) 脚本所在目录
```

而且 `/host` 分区**跨升级重启保留**，放这儿最稳。

### 权限坑：不能直接 scp 到 /host/tmp

`/host/tmp` 属 root（755），普通 `admin` 用户直接 `scp` 进去会 **Permission denied**。
所以要 **两步**：先 scp 到有写权限的 `/home/admin/`，再 `sudo mv` 进 `/host/tmp`。
（admin 已配 sudo 免密，`mv` 不用输密码。）

### 拷贝步骤（每台交换机执行）

假设交换机 IP `192.0.2.4`，Mac 上镜像+固件都在本项目的
`/path/to/ansible/packages/`。

```bash
# 1) scp 到 admin 家目录（admin 有写权限；密码 admin）
cd /path/to/ansible/packages
scp nvos-amd64-25.03.1010.bin admin@192.0.2.4:/home/admin/

# 固件同理（BIOS/CPLD，若需要；同目录，无需切换）
scp 0ACQF.cab burn.vme refresh.vme admin@192.0.2.4:/home/admin/

# 2) SSH 进去，把文件 sudo 挪进 /host/tmp
ssh admin@192.0.2.4
sudo mv /home/admin/*.bin /home/admin/*.cab /home/admin/*.vme /host/tmp/ 2>/dev/null
ls -lh /host/tmp/           # 确认到位
exit
```

一条命令搞定挪动（不进交互 shell）：

```bash
ssh admin@192.0.2.4 'sudo mv /home/admin/*.bin /home/admin/*.cab /home/admin/*.vme /host/tmp/ 2>/dev/null; ls -lh /host/tmp/'
```

### 阶梯 = /host/tmp 里的 .bin 文件

脚本扫描 `/host/tmp` 下所有 `.bin`，**按版本号自动排序成升级阶梯**。所以你手动拷时：

- **想逐级**（6077→7002→8008→1010）：把 7002/8008/1010 三个 `.bin` 都拷进去。
- **想跳级**（6077→8008→1010）：只拷 8008/1010。
- **拷之前先清掉 `/host/tmp` 里的旧 `.bin`**，避免旧版本混进阶梯：

```bash
ssh admin@192.0.2.4 'sudo rm -f /host/tmp/*.bin; ls /host/tmp/'
```

> 手动拷镜像时，`group_vars` 里的 `nvos_images` 列表**不再决定阶梯**（那只用于 Ansible 推送）。
> 阶梯完全由 `/host/tmp` 里实际存在的 `.bin` 决定。

## 删除分区里的旧 NVOS 镜像（如 6077）

NVOS 是**双分区**（partition1 / partition2），升级会把新版本装进另一个分区。想腾出分区、
或清掉旧版本（如 `nvos-25.02.6077`）时，用 `nv action uninstall`。

### 关键：只能删 standby 分区，删不掉正在运行/boot-next 的分区

先看分区状态，确认要删的版本**既不是 current、也不是 next**：

```bash
ssh admin@192.0.2.4
nv show system image
```

```
             operational
-----------  ---------------
current      2          ← 正在运行 partition2
next         2          ← 下次启动也是 partition2
partition1
  build-id   nvos-25.02.6077     ← standby，可删
partition2
  build-id   nvos-25.03.1010     ← 运行中 + boot-next，保留
```

上例里 6077 在 partition1、既非 current 也非 next，可安全删。
若要删的版本正是 current 或 next，得先升级/切到别的版本并重启，让它变成 standby 后再删。

### 正确命令（本 NVOS 版本实测）

`uninstall` **不接** `files` / 版本号 / 分区名等任何参数——这些都会报 `Invalid parameter`。
它只有一个可选的 `force`，默认删的就是**非 boot-next 的那个 standby 分区**：

```bash
# 删 standby 分区（上例即删 partition1 的 6077）——不要加 force
nv action uninstall system image

# 验证：partition1 应清空，只剩 partition2，current/next 仍是 2
nv show system image
```

> **不要加 `force`。** `force` 的含义是「即使镜像被设为 boot-next 也照删」，加了可能误删你要保留的
> boot-next 分区。不加 `force` 时它只动 standby，天然安全。

> 命令语法可能随 NVOS 版本而异。若上面命令报错，用 `nv action uninstall system image --help`
> 或按 Tab 补全核对；升级脚本 `--clean-images` 也会自动清 standby 上的非目标版本镜像。

## 指定版本直达 / 回退（50-set-version.yml）

`20-upgrade.yml` 只能**逐级往上升**到最高版本。若你要**切到某个精确版本**（比如回退到
`25.02.6077`，或跳过中间版本直达），用 `50-set-version.yml` + `scripts/q3400-set-version.sh`。

它做三件事：直达目标版本（忽略阶梯）→ 重启进目标 → **清理多余分区，只保留目标版本**。

### 机制（NVOS 双分区，跨一次重启完成）

因为 NVOS 是双分区、`uninstall` 只能删 standby，所以"只留目标"必须在**重启进目标之后**做
（那时旧版本才落到 standby、才可删）：

```
1. 推 q3400-set-version.sh + 目标镜像到 /host/tmp
2. 只读检测：当前已是目标 → 幂等跳过
3. 装目标镜像到 standby 分区并设 boot-next（此步不重启）
4. auto_reboot=true 才重启进目标；重启后校验"运行版本==目标"（不符则中止，不清理）
5. cleanup_partitions=true 时删 standby（旧版本已落 standby）→ 只剩目标版本
```

### 用法（两步走，安全）

```bash
cd /path/to/ansible

# ① 安全预置：只装到 standby、设好 boot-next，不重启（默认 auto_reboot=false）
ansible-playbook playbooks/50-set-version.yml -e target_version=25.02.6077 -l 192.0.2.93

# ② 确认后：重启进目标 + 重启后清理多余分区，只留目标
ansible-playbook playbooks/50-set-version.yml -e target_version=25.02.6077 \
    -e auto_reboot=true -e cleanup_partitions=true -l 192.0.2.93
```

`target_version` 必须是完整点分格式（如 `25.02.6077`）。镜像按版本自动在 `packages/` 里匹配
唯一 `.bin`（`25.02.6077` → `nvosv25-02-6077amd64.bin`），已 10-stage 推过可加 `-e push_image=false`。

### 变量开关

| 变量 | 默认 | 作用 |
|------|------|------|
| `target_version` | （必填） | 目标 NVOS 版本，如 `25.02.6077` |
| `auto_reboot` | `false` | **安全开关**：`true` 才重启进目标；`false` 只预置不重启 |
| `cleanup_partitions` | `true` | 重启并校验通过后删 standby，只留目标（需 `auto_reboot=true` 才会执行） |
| `push_image` | `true` | 是否推送目标镜像（已手动拷/推过可 `false`） |

> **非交互式重启就是加 `-e auto_reboot=true`**。playbook 全程无交互，`auto_reboot=true`
> 会自动 `nv action reboot system force`、等恢复、校验、清理。想保留旧分区做回退保险，
> 加 `-e cleanup_partitions=false`。

### 安全设计

- **默认不擅自重启**：`auto_reboot=false` 时只装到 standby、设好 boot-next 就停，
  打印手动重启命令。确认后再加 `-e auto_reboot=true`。
- **清理前必校验**：重启后若没跑起目标版本，直接中止**不删分区**，防误删。
- **清理用无参 `uninstall`**：只删 standby，不加 `files`/`force`，不会误删 boot-next 分区。
- **切分区后密码回默认**：先跑 `40-set-password.yml` 把密码写进 nv config 层（见「密码持久化」）。

> 能否一步到位取决于 NVOS —— 若某版本不支持从当前版本直接装到目标（跨多版本），
> `install` 可能报错。首次真机建议先跑第①步预置观察，脚本内的 `--check` 会打印结论。

### 单台手动（不用 Ansible）

镜像已在 `/host/tmp` 时，直接 SSH 上去跑脚本：

```bash
ssh admin@192.0.2.93
sudo bash /host/tmp/q3400-set-version.sh --version 25.02.6077 --check   # 只读检测
sudo bash /host/tmp/q3400-set-version.sh --version 25.02.6077           # 交互确认重启
sudo bash /host/tmp/q3400-set-version.sh --version 25.02.6077 --yes     # 非交互直接重启
```

> 脚本 `--yes` = 非交互直接重启（等同 playbook 的 `auto_reboot=true`）。**后台/无 tty 时
> 不加 `--yes` 不会重启**，会停在待重启并提示手动 `nv action reboot system force`。

## 脚本直接用（不用 Ansible，单台）

镜像已拷进 `/host/tmp` 后，直接 SSH 上去跑脚本即可。**只需记一个命令 `--auto`。**

```bash
ssh admin@192.0.2.4

# 全自动：检测版本 → 补 BIOS/CPLD → NVOS 逐级升级 → 自动重启续跑 → 达标后收尾
sudo bash /host/tmp/q3400-upgrade-ladder.sh --auto

# 另开一个窗口看进度（可选）
ssh admin@192.0.2.4 'tail -f /host/tmp/q3400-upgrade.log'
```

`--auto` 会自己注册开机 cron 续跑，中途重启不用管，全部达标后自动删 cron 收尾。

常用的就这几个，其余基本用不到：

```bash
sudo bash /host/tmp/q3400-upgrade-ladder.sh --auto     # 一键全自动升级（最常用）
sudo bash /host/tmp/q3400-upgrade-ladder.sh --status   # 看进度/版本/已识别固件
sudo bash /host/tmp/q3400-upgrade-ladder.sh --check     # 只看阶梯计划，不动手
sudo bash /host/tmp/q3400-upgrade-ladder.sh --backup    # 单独备份配置
```

> Ansible 的 `20-upgrade.yml` 本质就是从 Mac 远程帮你逐台调这个脚本（但用 `--check`/`--run`
> 逐跳驱动、天然跨分区，不依赖交换机 cron）。**单台手动用 `--auto`，多台批量用 Ansible。**

## 密码持久化（重要，升级前必做）

**踩坑记录**：NVOS 有两套密码存储，务必分清，否则升级后密码会“丢”：

| 存储 | 谁改的 | 升级换分区后 |
|------|--------|-------------|
| **Linux 层**（`/etc/shadow`） | `bootstrap-switch.exp` 走首登交互改的就是这个 | **丢** —— 新分区是全新镜像，Linux 层回出厂 `admin/admin` |
| **NVOS 配置层**（`nv config`） | `nv set system aaa user admin password` + `nv config save` | **保留** —— 升级会把 startup 配置迁到新分区 |

NVOS 升级 = 装全新镜像到另一分区。bootstrap 只改 Linux 层，所以 **一升级密码就回默认**
（eth0 IP 这类在 nv config 里的则保留，所以 IP 还在、只有密码丢）。而且**每跳都会再丢一次**。

**解决：升级前先把密码写进 nv config 层并 save**，之后每次换分区都跟着迁移，不再丢：

```bash
cd /path/to/ansible

# 若机器当前是默认 admin/admin（新机 bootstrap 后 / 已被升级重置）：
ansible-playbook playbooks/40-set-password.yml -l <IP> \
  -e ansible_password=admin -e ansible_become_password=admin \
  -e new_admin_password='admin'

# 若当前密码已是 group_vars 里的 admin，直接：
ansible-playbook playbooks/40-set-password.yml -l <IP> -e new_admin_password='admin'
```

`40-set-password.yml` 做三步：`nv set system aaa user admin password` → `nv config apply` → `nv config save`。
其中 **`nv config save` 是关键**（存进 startup 才跨升级保留）。密码用 `-e` 传入，不写死进库。

> `nv config apply` 的非交互参数（脚本暂用 `--assume-yes`）可能随 NVOS 版本不同，
> 首次在真机上跑若报错，先 `nv config apply --help` 核对一下写法。

## 新机器 vs 老机器

所有机器登录密码统一为 `admin`，可放同一个 `[q3400]` 组，一套 `group_vars` 通吃。

| 类型 | 是否要 bootstrap | 登录方式 |
|------|-----------------|---------|
| **新机**（出厂 admin/admin） | 要（改密码 + 装公钥） | 公钥免密（密码也可用） |
| **老机**（已设过密码） | 不要 | 用密码 `admin` |

老机器直接填进 `hosts.ini` 即可，跳过 bootstrap。密码登录依赖 Mac 上的 `sshpass`：

```bash
brew install sshpass    # 已装则跳过；group_vars 里已填 ansible_password
```

## 新机器首次初始化

新机 admin/admin 首次 SSH 会**强制改密码**（交互式），Ansible 撞上这个提示会卡住。
所以新机器必须先跑一次性 bootstrap：改密码 + 装 SSH 公钥（之后 Ansible 免密码）。

> ⚠ **注意**：bootstrap 改的是 **Linux 层密码**，**不跨升级保留**（升级换分区会回默认）。
> 所以 bootstrap 之后、升级之前，必须再跑一次 `40-set-password.yml` 把密码写进 nv config 层
> （见上面「密码持久化」一节）。只做 bootstrap 不做这步，升级后密码会丢。

```bash
cd /path/to/ansible/bootstrap

# 单台
./bootstrap-switch.exp 192.168.1.58 admin 'NewPass@2026' ~/.ssh/id_ed25519.pub

# 批量（IP 列表文件，一行一个；或逗号分隔）
./bootstrap-all.sh 192.168.1.58,192.168.1.59 admin 'NewPass@2026' ~/.ssh/id_ed25519.pub
```

> **提示词因 NVOS 版本略有差异**，脚本用关键词模糊匹配。**强烈建议先拿一台新机试**，
> 若卡住/超时，把实际交互提示发我，我按真实提示词调 expect 匹配。
> 也可以纯手动：`ssh admin@<IP>` 走完改密码流程，再 `ssh-copy-id admin@<IP>` 装公钥。

## 使用步骤

```bash
cd /path/to/ansible

# 0. 新机器先 bootstrap（见上一节）；填 IP：编辑 inventory/hosts.ini，[q3400] 下一行一台

# 1. 自检连通性与权限
ansible-playbook playbooks/00-ping.yml

# 2. 【升级前必做】把密码写进 nv config 层，跨升级保留（否则升级后密码丢，见「密码持久化」）
ansible-playbook playbooks/40-set-password.yml -e new_admin_password='admin'
#   若机器当前是默认 admin/admin：再加 -e ansible_password=admin -e ansible_become_password=admin

# 3. 手动拷镜像到各交换机的 /host/tmp（见「镜像手动拷贝」）

# 4. 推脚本（不推大镜像，因为你已手动拷了）
ansible-playbook playbooks/10-stage.yml -e push_images=false -e push_firmware=false
#   若固件也想让 Ansible 推：去掉 push_firmware=false
#   若镜像也想让 Ansible 推（慢）：全去掉，用默认 true

# 5. 批量升级（逐台，每跳等重启，直到目标版本 + 验收）
ansible-playbook playbooks/20-upgrade.yml
#   只升某几台:  -l 192.0.2.4
#   并行升(慎用): 删掉 20-upgrade.yml 里的 serial: 1

# 随时看状态（只读）

# 5.（可选）升级完成后删除 bootstrap 装的公钥，回到纯密码登录
ansible-playbook playbooks/99-remove-key.yml
```

## 各 playbook 说明

| playbook | 作用 | 是否改动交换机 |
|----------|------|--------------|
| `00-ping.yml` | 连通性 + sudo + nv 命令与版本自检 | 只读 |
| `40-set-password.yml` | 把密码写进 nv config 层并 save，跨升级保留 | 改配置 |
| `10-stage.yml` | 推脚本（+可选固件/镜像）到 `/host/tmp` | 写文件 |
| `20-upgrade.yml` | 主编排：备份 + 逐跳升级 + 验收清理 | 升级/重启 |
| `50-set-version.yml` | 指定版本直达（可升可降/回退）+ 重启后清理多余分区，只留目标 | 升级/重启 |
| `30-status.yml` | 只读查看版本/阶梯/已装分区镜像 | 只读 |
| `99-remove-key.yml` | 删 bootstrap 装的公钥，回到密码登录 | 清理 |

### 10-stage.yml 的开关

```bash
# 只推脚本（配合手动拷镜像，最常用）
ansible-playbook playbooks/10-stage.yml -e push_images=false -e push_firmware=false

# 推脚本 + 固件，不推大镜像
ansible-playbook playbooks/10-stage.yml -e push_images=false

# 全推（脚本 + 固件 + 镜像，慢）—— 这时才看 group_vars 的 nvos_images/firmware_files
ansible-playbook playbooks/10-stage.yml
```

## 工作原理（每跳）

`tasks/one_hop.yml` 每次循环：
1. `--check` 判断是否已全部达标 → 达标则结束循环
2. 未达标 → 后台跑 `--run` 执行一个阶段（可能触发重启）
3. `wait_for_connection` 等交换机重启后 SSH 恢复
4. 读回当前版本，进入下一跳

全部达标后 `--verify` 收尾（清 cron + 清理 standby 上非目标版本的镜像）。

若机器已经在目标版本，`20-upgrade.yml` 第一次 `--check` 就返回「已全部达标」，
**直接跳过升级、不重启**，只做备份和 `--verify` 清理。

## 认证方式（二选一）

**推荐：SSH 密钥（免密码，最安全）**
```bash
ssh-copy-id admin@<交换机IP>     # 每台执行一次
# group_vars 里不填 ansible_password
```

**或：密码（当前默认，group_vars 里已填 admin）**
密码登录需 Mac 装 `sshpass`。生产环境建议改用 vault 加密：
```bash
ansible-vault create secrets.yml
# 内容: ansible_password / ansible_become_password
ansible-playbook playbooks/20-upgrade.yml -e @secrets.yml --ask-vault-pass
```

## 使用前：按实际密码修改的位置

仓库里的密码都是占位符（`admin` / `NewPass@2026`），使用前按实际情况替换。**真实密码不要提交到 git。**

| 位置 | 改什么 | 说明 |
|------|--------|------|
| `inventory/group_vars/q3400.yml` 的 `ansible_password` | 交换机 SSH 登录密码 | 默认 `admin`，改成交换机当前实际密码 |
| `inventory/group_vars/q3400.yml` 的 `ansible_become_password` | sudo 提权密码 | 一般与登录密码相同 |
| `playbooks/40-set-password.yml` 命令行 `-e new_admin_password='...'` | 想让交换机最终使用的密码 | 只通过 `-e` 传入，不写进文件 |
| 同上命令的 `-e ansible_password=... -e ansible_become_password=...` | 机器当前密码 | 仅当机器还是出厂 `admin/admin` 或被升级重置时才需要临时覆盖 |
| `bootstrap/bootstrap-switch.exp` / `bootstrap-all.sh` 的第 3 个参数 | 首登要设置的新密码 | 示例里的 `NewPass@2026` 换成实际密码，命令行传入，脚本里没有写死 |
| `inventory/hosts.ini` | 设备 IP | 示例用的 `192.0.2.x` 要换成真实 IP |
| `inventory/group_vars/q3400.yml` 的 `local_pubkey` | 本机公钥路径 | 默认 `~/.ssh/id_ed25519.pub` |

三个密码要保持一致：`q3400.yml` 里的登录密码和 sudo 密码，要等于 `40-set-password.yml` 设置的 `new_admin_password`，否则升级后会登录失败。

### 不把真实密码提交到 git（推荐）

**方式一：本地私有变量文件。** 在项目根目录新建 `secrets.yml`（已在 `.gitignore` 里），运行时用 `-e @secrets.yml` 覆盖：

```yaml
# secrets.yml
ansible_password: "实际密码"
ansible_become_password: "实际密码"
```

```bash
ansible-playbook playbooks/20-upgrade.yml -e @secrets.yml
```

**方式二：ansible-vault。** 见上面「认证方式」。vault 文件和密码都不要提交到 git。

## 注意

- **升级默认保留配置**，且每台升级前 `20-upgrade.yml` 会自动 `--backup`
  （存 `/host/tmp/config-backups`，含带外 eth0 IP）。降级才会丢配置。
- **镜像必须在 `/host/tmp`**（不是 `/home/admin`），且拷前先清旧 `.bin`（见上）。
- `20-upgrade.yml` 默认 `serial: 1`（逐台升），便于观察；确认稳妥后可改并行。
- 交换机若无 Python，playbook 用 `raw` 模块规避，已适配。
- 机器多时建议先只对一台跑通 `00 → (手动拷) → 10 → 20` 全流程，再批量。
