# Kernel 工作区（MoonWake / HyperMoon）

Redmi Note 12T（ruby，MT6877 / 天玑 810）内核折腾记录与产物。
基线内核：Linux 4.19.x ｜ 工具链：Google clang 21.0.0 (r563880) ｜ 打包：AnyKernel3（`ruby` 分支）

## 目录

| 目录 | 内容 |
|---|---|
| [`moonwake-official-ksu/`](moonwake-official-ksu/) | **方案一**：MoonWake 内核内置**官方 KernelSU v0.9.5**（非 GKI 手动集成）✅ 编译通过 |
| [`hypermoon-moonwake-features/`](hypermoon-moonwake-features/) | **方案二**：把 MoonWake 的特性（MGLRU / BBR / LZ4KD / NOOP）移植到 HyperMoon ✅ 编译通过 |
| [`hyperos-compat/`](hyperos-compat/) | MoonWake 的 HyperOS/MIUI 兼容配置片段（恢复 MTK 性能/遥测/调试设施） |
| [`kernel-action/`](kernel-action/) | KernelAction CI 构建配置（含两个新变体的 JSON） |
| [`builds/`](builds/) | 可直接刷入的 AnyKernel3 卡刷包 |
| [`docs/`](docs/) | 完整构建说明文档 |

另有完整源码分支（可直接用 KernelAction CI 构建，无需再打补丁）：

- `kernel-source/moonwake-official-ksu`：MoonWake 全量源码 + 官方 KernelSU v0.9.5（约 443 MB）
- `kernel-source/hypermoon-moonwake-features`：HyperMoon 全量源码 + MGLRU/BBR/LZ4KD/NOOP 移植（约 433 MB）

这两个分支与本仓库其它内容历史无关（独立快照）；单独 clone 时建议 `git clone --single-branch --branch <分支名>`。

## 卡刷包一览

| 文件 | 内容 | 适用 |
|---|---|---|
| `builds/MoonWake-2.6.0-KernelSU-AOSP-20261002.zip` | MoonWake + KernelSU-Next（AOSP 形态，带 dtb） | 类原生 ROM |
| `builds/MoonWake-2.6.0-KernelSU-HyperOS-20261002.zip` | MoonWake + KernelSU-Next（HyperOS 形态，不带 dtb） | MIUI / HyperOS |
| `builds/MoonWake-2.6.0-KernelSU-Official-v0.9.5-20261003.zip` | **MoonWake + 官方 KernelSU v0.9.5**（AOSP 形态，带 dtb） | 类原生 ROM |
| `builds/MoonWake-2.6.0-KernelSU-Official-v0.9.5-HyperOS-20261003.zip` | **MoonWake + 官方 KernelSU v0.9.5**（HyperOS 形态，不带 dtb，合并 `vendor/hyperos.config`） | MIUI / HyperOS |
| `builds/HyperMoon-1.0.2-MoonWake-Features-20261003.zip` | **HyperMoon + MGLRU/BBR/LZ4KD/NOOP** | MIUI / HyperOS |

## 两个内核的关系

- **MoonWake**（`DXRN-MoonWake/moonwake_kernel_xiaomi_ruby`）：功能增强版，带 MGLRU、BBR3、LZ4KD、Simple LMK 等特性；在 HyperOS 上默认配置可能不开机。
- **HyperMoon**（`DXRN-MoonWake/hypermoon_kernel_xiaomi_ruby`）：HyperOS 兼容版；特性相对保守。
- 两个方案互为补充：
  1. 方案一让 MoonWake 内置官方 KernelSU（不用 KernelSU-Next）；
  2. 方案二把 MoonWake 的特性搬到 HyperMoon，让它既能开机又更快。

## 关键结论（速览）

- 官方 KernelSU 自 v1.0 起不支持非 GKI 内核，4.19 最后一个可用版本是 **v0.9.5**。
- v0.9.5 手动集成**必须关闭 `CONFIG_KPROBES`**：ksud.c 里 `#ifdef CONFIG_KPROBES` 走 kprobe 分支、不定义 `ksu_*_hook` 变量，而内核树的手动埋点依赖这些变量（链接会失败）；官方文档也明确，手动集成开 KPROBES 会导致开机按音量下误触发安全模式。
- MTK 的 `ANDROID_DEFAULT_SETTING` 会 `select MEMCG`，因此上游 MoonWake 的 `slmk.config`（要求 `MEMCG=n`）实际上无法启用 Simple LMK，除非同时关掉整套 ANDROID_DEFAULT_SETTING。
- HyperMoon 基线较老，移植 MoonWake（5.x 风格）代码需要适配：`ANON_AND_FILE`、3 参数 LRU 辅助函数、swap cache shadow API、`arch_has_hw_pte_young`；另外修掉了上游自带的 `mmap_read_unlock()` 编译错误。

## 复现（本地流程）

```bash
# 方案一：官方 KernelSU
git clone -b v0.9.5 https://github.com/tiann/KernelSU
ln -s ../KernelSU/kernel drivers/kernelsu
git apply moonwake-official-ksu/official-ksu-integration.patch

make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 ruby_defconfig
scripts/kconfig/merge_config.sh -O out -m out/.config arch/arm64/configs/vendor/official-ksu.config
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     KCFLAGS="-O2 -march=armv8.2-a+crypto+fp16+dotprod -mcpu=cortex-a78 -mtune=cortex-a78" \
     -j$(nproc) Image.gz-dtb
```

```bash
# 方案二：HyperMoon 特性版
cd hypermoon && git apply hypermoon-moonwake-features/hypermoon-moonwake-features.patch
cp hypermoon-moonwake-features/configs/*.config arch/arm64/configs/vendor/
make O=out ARCH=arm64 ruby_defconfig
scripts/kconfig/merge_config.sh -O out -m out/.config arch/arm64/configs/vendor/{bbr,lru,lz4kd,noop}.config
make O=out ARCH=arm64 olddefconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 -j$(nproc) Image.gz-dtb
```