# MoonWake 内置 KernelSU 构建说明（ruby / Redmi Note 12 Pro 5G）

> 构建时间：2026-10-02 ｜ 工具链：Google clang 21.0.0 (r563880) ｜ 内核基线：Linux 4.19.325
> KernelSU：**KernelSU-Next `v3.2.0-legacy-susfs-v2-17-g56911735`**（branch `legacy-susfs-v2`，与官方 KernelAction 配置一致）

## 1. 已产出的可刷入包

| 文件 | 形态 | 内核文件 | 适用 |
|---|---|---|---|
| [MoonWake-2.6.0-KernelSU-AOSP-20261002.zip](computer:///workspace/output/MoonWake-2.6.0-KernelSU-AOSP-20261002.zip) | **AOSP 官方形态** | `Image.gz-dtb`（自带 dtb） | AOSP / LineageOS 等类原生 ROM |
| [MoonWake-2.6.0-KernelSU-HyperOS-20261002.zip](computer:///workspace/output/MoonWake-2.6.0-KernelSU-HyperOS-20261002.zip) | **MIUI / HyperOS 实验形态** | `Image.gz`（不带 dtb） | MIUI / HyperOS（**需真机验证可开机性**） |

两个包都基于官方 AnyKernel3 `ruby` 分支打包，可直接在 Recovery（OrangeFox）里刷入。

## 2. 内核内已确认内置 KernelSU

用 `llvm-nm` / `System.map` 核对，两个镜像内各含 **264 个 KernelSU 符号**，包括：

```
kernelsu_init          kernelsu_exit        apply_kernelsu_rules
ksu_handle_execveat    ksu_handle_faccessat  ksu_handle_stat
__ksu_is_allow_uid     is_ksu_domain         is_task_ksu_domain
anon_ksu_ioctl         anon_ksu_release
```

对应配置：`CONFIG_KSU=y`、`CONFIG_KSU_MANUAL_HOOK=y`（未用 kprobes hook），符合 MoonWake 官方 KSU 变体。

## 3. 两个包的具体配置

### A. MoonWake-KernelSU（AOSP 形态，等同于官方 MoonWake-KernelSU）
```
ruby_defconfig
+ vendor/bbr.config          → BBR3 拥塞控制（默认）
+ vendor/noop.config         → noop I/O 调度
+ vendor/kernelsu.config     → CONFIG_KSU / MANUAL_HOOK / MULTI_MANAGER
+ vendor/kernelpatch.config  → KALLSYMS（KPatch 用）
输出：Image.gz-dtb
KCFLAGS: -O3 -march=armv8.2-a+crypto+fp16+dotprod -mcpu=cortex-a78 -mtune=cortex-a78
```

### B. MoonWake-KernelSU-HyperOS（MIUI/HyperOS 实验形态）
```
ruby_defconfig
+ vendor/kernelsu.config     → CONFIG_KSU / MANUAL_HOOK
+ vendor/hyperos.config      → 恢复 MTK 性能/遥测/调试设施（见下）
输出：Image.gz（沿用原机 dtb，与 HyperMoon 打包方式一致）
KCFLAGS: 空（保守，避免编译器差异影响 vendor 模块）
```
`vendor/hyperos.config` 恢复了原厂被 MoonWake 关掉的设施：
`MTK_FPSGO_V3`、`MTK_PERF_OBSERVER`、`MTK_LOAD_TRACKER`、`MTK_CPU_CTRL_CFP`、`MTK_FRS`、`MTK_RESYM`、`MTK_MET`/`MTK_MET_PLF`/`MTPROF`、`MTK_GZ_LOG`、`DEBUG_FS`、`TRACING`、`KALLSYMS_ALL`。

## 4. 复现方式（KernelAction）

[configs/moonwake-kernelsu.json](computer:///workspace/configs/moonwake-kernelsu.json) 内含上述两个变体，可直接放进 fork 的 `KernelAction/configs/release/` 后选它出包。

关键点是 `kernelsu` 段（官方同款）：
```json
"kernelsu": {
  "enable": true,
  "setupLink": "https://raw.githubusercontent.com/XDL-MoonWake/KernelSU-Next/refs/heads/legacy-susfs-v2/kernel/setup.sh",
  "setupArg": "legacy-susfs-v2",
  "setupName": "KernelSU-Next"
}
```
`hyperos-compat` 分支请把 `vendor/hyperos.config` 一起推上去（本地已提交）。

## 5. 本地复现命令（等价于 CI 流程）

```bash
# 1) 注入 KernelSU（在源码根目录执行）
sh setup.sh legacy-susfs-v2
# 效果：drivers/kernelsu -> ../KernelSU-Next/kernel
#       drivers/Makefile 追加 obj-$(CONFIG_KSU) += kernelsu/
#       drivers/Kconfig  追加 source "drivers/kernelsu/Kconfig"

# 2) 配置 + 编译
export PATH=<clang-r563880>/bin:$PATH ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 \
       LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
make -j3 O=out ruby_defconfig
make -j3 O=out vendor/kernelsu.config vendor/hyperos.config
make -j3 O=out Image.gz
```

## 6. 使用说明

1. **先备份 boot 分区**（Recovery 里备份，或 `dd` 出 boot.img）。
2. 刷入 zip（OrangeFox → 选择 zip → 滑动刷入）。
3. 首次开机后安装 KernelSU 管理器（本项目用的是 KernelSU-Next 分支，**建议用配套的 KernelSU-Next 管理器**；官方说明 KSU 变体可兼容 KSUN / SukiSU / KowSU / 官方 KSU 等多个管理器）。
4. 若管理器提示未安装，说明 ROM 的 SELinux/AVB 干预，本内核已带 `MANUAL_HOOK`，无需再打 kprobes 补丁。

## 7. 重要提醒

- ⚠️ **HyperOS 形态未经真机验证**：MoonWake 官方声明其在 MIUI/HOS 上"不可开机"，本包按"打包形态 + 配置回归"的假设做了处理，属于实验性质。若无法开机，参考对比报告里的二分步骤继续定位。
- ⚠️ AOSP 形态与官方 MoonWake-KernelSU 配置一致，但仍建议先备份再刷。
- 本内核**未包含** SuSFS（`vendor/susfs.config`）与 LZ4KD；如需 SuSFS 版本可以再加 `vendor/susfs.config` 重新出包。
- 日志：`/workspace/build/build-ksu.log`（两次构建均 `BUILD_EXIT=0`、0 error）。
