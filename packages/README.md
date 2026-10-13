# packages

本目录存放 NVOS 镜像（`*.bin`）和 BIOS/CPLD 固件（`*.cab`、`*.vme`、`*.rar`），体积较大，不随仓库提供。

## 下载

百度网盘：NVIDIA-Q3400

- 链接：https://pan.baidu.com/s/1fN9AeE0i_C_QzQYRdrRxEQ?pwd=iava
- 提取码：`iava`

下载后把文件直接放进本目录（`packages/`），不要放子目录以外的位置。

## 需要的文件

`inventory/group_vars/q3400.yml` 里的 `nvos_images` 和 `firmware_files` 决定要用哪些：

- `nvosv25-02-6077amd64.bin`
- `nvosv25-02-7002amd64.bin`
- `nvos-amd64-25.02.8008.bin`
- `nvos-amd64-25.03.1010.bin`
- `0ACQF.cab`、`burn.vme`、`refresh.vme`
- `FUI000557.rar`（解压后得到 `FUI000557/` 目录）
