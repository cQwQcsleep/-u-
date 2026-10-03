# 方案二：HyperMoon 移植 MoonWake 特性

HyperMoon 是 HyperOS 兼容版内核，但缺少 MoonWake 的性能特性。
这里把 MoonWake 的特性逐个移植过来，目标是「既能开机、又更快」。

## 移植内容

| 特性 | 配置片段 | 说明 |
|---|---|---|
| **MGLRU**（多代 LRU） | `configs/lru.config` | mm/vmscan.c 等 60+ 文件、约 +8600 行；后台回收更聪明，低内存更跟手 |
| **BBR3** 拥塞控制 | `configs/bbr.config` | `CONFIG_TCP_CONG_BBR=y` + 默认 `bbr` |
| **LZ4KD / LZ4K** | `configs/lz4kd.config` | 更快的 zram 压缩算法 |
| **NOOP** I/O 调度 | `configs/noop.config` | 默认调度器改 noop，降低 UFS 开销 |
| **Simple LMK** | `configs/slmk.config` | ⚠️ 见下方说明，当前配置下**无法启用** |

代码改动全部来自 MoonWake 的对应提交（cherry-pick + 适配），完整清单见 `commits.txt`（53 个提交），
合并后的总 diff 见 `hypermoon-moonwake-features.patch`（63 files changed，含 8 个文件的适配修复）。

## 移植适配点（重点）

HyperMoon 的基线比 MoonWake 老，直接 cherry-pick 会留下一批 API 不匹配，
以下这些坑都已修复（对应 `mglru: fix build after MGLRU/SLMK port on the older 4.19 base` 提交）：

1. **`include/linux/mmzone.h`**：补 `#define ANON_AND_FILE 2`（MoonWake 有、HyperMoon 没有），
   否则 MGLRU 的所有 `[...][ANON_AND_FILE][...]` 数组编译不过。
2. **`include/linux/mm_inline.h`**：MoonWake 用 3 参数 LRU 辅助函数
   （`add/del_page_from_lru_list(page, lruvec, lru)`），移植时被改成了 2 参数版本，
   导致全树 16+ 处调用点编译失败、且 `page_off_lru()` 先清标志后内部重算会算错 LRU。
   现已恢复 3 参数签名并把 MGLRU 钩子放进去；MGLRU 自己的 4 处 2 参数调用改为传 `page_lru(page)`。
3. **swap cache shadow API**：MGLRU 的 refault 跟踪需要
   `__add_to_swap_cache(page, entry, &shadow)` / `__delete_from_swap_cache(page, shadow)` /
   `clear_shadow_from_swap_cache()`。移植时只改了调用方没改定义，现已把实现补齐
   （`mm/swap_state.c`、`mm/swapfile.c`、`include/linux/swap.h`）。
4. **`mm/internal.h`**：补 `arch_has_hw_pte_young()` 桩函数（MGLRU 需要）。
5. **`fs/proc/task_mmu.c`**：上游 HyperMoon 自身有个 bug——用了 4.19 不存在的
   `mmap_read_unlock()`，`CONFIG_PROC_PAGE_MONITOR=y` 时编译失败，已改为 `up_read(&mm->mmap_sem)`。
6. **`mm/vmscan.c`**：HyperMoon 的 `page_lru_base_type()` 与 MoonWake 版本不同，保留 HyperMoon 逻辑。

另外 MGLRU 附带修复提交：`mm: mglru: Fix some missing function declarations and pointer errors`、
`BACKPORT: mm: multi-gen LRU: Move lru_gen_add_mm() out of IRQ-off region`、
`ANDROID: Make MGLRU aware of speculative faults`。

## 关于 Simple LMK（重要）

上游 MoonWake 的 `slmk.config` 内容为：

```
CONFIG_MEMCG=n
CONFIG_PSI=n
CONFIG_ANDROID_SIMPLE_LMK=y
```

但 MTK 的 `ANDROID_DEFAULT_SETTING`（`drivers/misc/mediatek/Kconfig.default`，ruby_defconfig 默认开启）
里有 `select MEMCG`，**select 优先级高于配置片段**，所以 `MEMCG=n` 永远不会生效，
而 `ANDROID_SIMPLE_LMK` 的 Kconfig 依赖是 `depends on !ANDROID_LOW_MEMORY_KILLER && !MEMCG`，
结果是 **Simple LMK 在这两个内核上都无法启用**（上游片段实际是死配置）。

要真正启用只有两条路，都不建议日常用：

- 关掉 `CONFIG_ANDROID_DEFAULT_SETTING` / `CONFIG_MTK_ANDROID_DEFAULT_SETTING`
  （会连带关掉一整套 Android/MTK 默认项，HyperOS 很可能不开机）；
- 或修改 `Kconfig.default` 把 `select MEMCG` 改成 `select MEMCG if !ANDROID_SIMPLE_LMK`
  （侵入 MTK 配置语义，`MEMCG=n` 也会影响 HyperOS 的 memcg/PSI 相关服务）。

因此本方案**默认只启用 MGLRU / BBR / LZ4KD / NOOP**，SLMK 代码保留（`CONFIG_ANDROID_SIMPLE_LMK`
不打开），配置片段一并存档供以后研究。

## 构建

```bash
cd hypermoon
git apply hypermoon-moonwake-features.patch        # 或直接切到已有分支
cp configs/*.config arch/arm64/configs/vendor/

make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 ruby_defconfig
scripts/kconfig/merge_config.sh -O out -m out/.config \
    arch/arm64/configs/vendor/{bbr,lru,lz4kd,noop}.config
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     KCFLAGS="-O2 -march=armv8.2-a+crypto+fp16+dotprod -mcpu=cortex-a78 -mtune=cortex-a78" \
     -j$(nproc) Image.gz-dtb
```

验证配置生效：

```bash
grep -E "CONFIG_LRU_GEN=|CONFIG_LRU_GEN_ENABLED|CONFIG_TCP_CONG_BBR=|CONFIG_CRYPTO_LZ4KD=|CONFIG_DEFAULT_IOSCHED" out/.config
```

## 状态

- [x] MGLRU / SLMK 代码移植（分支 `moonwake-features`，53 个提交）
- [x] 配置片段
- [x] 修复全部编译错误（ANON_AND_FILE、LRU 辅助函数、shadow API、arch_has_hw_pte_young、mmap_read_unlock）
- [x] 编译通过 → 产物 `builds/HyperMoon-1.0.2-MoonWake-Features-20261003.zip`
- [ ] 真机验证

## 编译验证结果

`System.map` 符号核对（内核版本串：`5.10.246-HyperMoon-1.0.2`）：

```
MGLRU:  lru_gen_add_mm / lru_gen_del_mm / lru_gen_migrate_mm / lru_gen_look_around
        lru_gen_init_lruvec / lru_gen_init_memcg / lru_gen_exit_memcg
        lru_gen_eviction / lru_gen_refault        （共 21 个 lru_gen 符号）
LZ4KD:  lz4kd_compress_crypto / lz4kd_decompress_crypto / lz4kd_init / lz4kd_exit / lz4kd_out_tail
BBR:    bbr_init / bbr_ssthresh / bbr_set_state
```

配置核对（.config）：`CONFIG_LRU_GEN=y`、`CONFIG_LRU_GEN_ENABLED=y`、`CONFIG_LRU_GEN_STATS=y`、
`CONFIG_TCP_CONG_BBR=y`、`CONFIG_DEFAULT_TCP_CONG="bbr"`、`CONFIG_CRYPTO_LZ4KD=y`、
`CONFIG_LZ4KD_COMPRESS/DECOMPRESS=y`、`CONFIG_DEFAULT_IOSCHED="noop"`。

产物为 `Image.gz`（16.2 MB，HyperOS 形态不带 dtb），用 MoonWake 官方 AnyKernel3（`ruby` 分支）打包（18.9 MB）。