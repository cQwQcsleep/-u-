# 方案一：MoonWake + 官方 KernelSU v0.9.5

把**官方**（tiann/KernelSU）KernelSU 内置进 MoonWake 内核，替代 KernelSU-Next。

## 为什么是 v0.9.5

官方 KernelSU 从 v1.0 开始只支持 GKI 内核（内核 5.10+），4.19 机型最后一个可用版本是 **v0.9.5**
（commit `b766b98513b5a7eb33bc1c4a76b5702bf1288f07`，tag `v0.9.5`）。

## 集成方式（非 GKI 手动埋点）

```
git clone -b v0.9.5 https://github.com/tiann/KernelSU   # 放在内核源码根目录
ln -s ../KernelSU/kernel drivers/kernelsu
```

然后应用 `official-ksu-integration.patch`（等价于官方 non-GKI 文档的补丁）：

| 文件 | 改动 |
|---|---|
| `drivers/Kconfig` | `source "drivers/kernelsu/Kconfig"` |
| `drivers/Makefile` | `obj-$(CONFIG_KSU) += kernelsu/` |
| `fs/exec.c` | 去掉 KernelSU-Next 的 `ksu_su_compat_enabled` 判断，按官方文档调用 `ksu_handle_execveat` / `ksu_handle_execveat_sucompat` |
| `fs/stat.c` | 删除 KernelSU-Next 专属的 `ksu_handle_newfstat_ret` / `ksu_handle_fstat64_ret`，保留 `ksu_handle_stat` |
| `kernel/reboot.c` | 删除 KernelSU-Next 专属的 `ksu_handle_sys_reboot` |

配置片段 `vendor-official-ksu.config`：

```
CONFIG_KSU=y
CONFIG_KPROBES=n          # 必须关闭！见下
CONFIG_HAVE_KPROBES=n
CONFIG_KPROBE_EVENTS=n
```

## 踩过的坑：KPROBES 必须关闭

第一次编译在 vmlinux 链接阶段失败：

```
ld.lld: error: undefined symbol: ksu_input_hook
ld.lld: error: undefined symbol: ksu_execveat_hook
ld.lld: error: undefined symbol: ksu_vfs_read_hook
```

原因在 v0.9.5 的 `KernelSU/kernel/ksud.c`：

```c
#ifdef CONFIG_KPROBES
static struct work_struct stop_vfs_read_work;      /* kprobe 模式 */
...
#else
bool ksu_vfs_read_hook __read_mostly = true;       /* 手动模式才定义这三个变量 */
bool ksu_execveat_hook __read_mostly = true;
bool ksu_input_hook __read_mostly = true;
#endif
```

内核树里的手动埋点（`fs/exec.c`、`fs/read_write.c`、`drivers/input/input.c`）依赖这三个变量，
所以 `CONFIG_KPROBES=y` 时它们不存在 → 链接失败。官方 non-GKI 文档也写明：
**手动集成必须关闭 KPROBES，否则开机后按音量下可能误触发安全模式**。
`ruby_defconfig` 默认就是 `CONFIG_KPROBES=n`，配置片段里再显式声明一次防止被其它片段打开。

（`CONFIG_HAVE_KPROBES` 是 arm64 架构 select 的，保持 y 无影响。）

## 构建

```bash
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 ruby_defconfig
scripts/kconfig/merge_config.sh -O out -m out/.config arch/arm64/configs/vendor/official-ksu.config
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     KCFLAGS="-O2 -march=armv8.2-a+crypto+fp16+dotprod -mcpu=cortex-a78 -mtune=cortex-a78" \
     -j$(nproc) Image.gz-dtb
```

产物用 AnyKernel3（`ruby` 分支）打包成卡刷包。

## 状态

- [x] 集成补丁 + 配置片段
- [x] 修复链接错误（KPROBES=n）
- [x] 编译通过（AOSP 形态）→ 产物 `builds/MoonWake-2.6.0-KernelSU-Official-v0.9.5-20261003.zip`
- [x] 编译通过（HyperOS 形态）→ 产物 `builds/MoonWake-2.6.0-KernelSU-Official-v0.9.5-HyperOS-20261003.zip`
- [ ] 真机验证（刷入后装官方 KernelSU Manager）

HyperOS 形态 = 在上述配置基础上再合并 `vendor/hyperos.config`（恢复 MTK 性能/遥测/调试设施），
并改用不带 dtb 的 `Image.gz` 打包（与 HyperOS 刷机惯例一致）。

## 编译验证结果

`System.map` 中共 **159 个 KernelSU 符号**，关键符号齐全：

```
ffffff8008f1e070 T ksu_handle_execveat
ffffff8008f1f260 T ksu_handle_faccessat
ffffff8008f1f3d0 T ksu_handle_stat
ffffff8008f21c00 T ksu_handle_sys_read
ffffff8008f23a50 T apply_kernelsu_rules
ffffff8009afe0d0 T kernelsu_init
ffffff8009bf3000 D ksu_vfs_read_hook
ffffff8009bf3001 D ksu_execveat_hook
ffffff8009bf3002 D ksu_input_hook
```

`Image.gz-dtb` 13,643,676 字节，用 MoonWake 官方 AnyKernel3（`ruby` 分支）打包（16.3 MB）。

## 刷入后怎么用

1. 在 Recovery 里刷入本卡刷包；
2. 安装**官方** KernelSU Manager APK（tiann/KernelSU release）；
3. 若 Manager 提示"内核版本不受支持"，说明 Manager 版本过新（v0.9.5 内核不认识新版 Manager 协议），换用与 v0.9.5 配套的 Manager 版本。

## 完整源码

完整内联源码（含官方 KernelSU v0.9.5 源码）已作为独立分支推送：
`kernel-source/moonwake-official-ksu`（该分支与本仓库其它内容历史无关，体积约 443MB）。