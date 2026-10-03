# KernelAction CI 配置

把这里的 JSON 放进你的 KernelAction fork 的 `KernelAction/configs/release/` 目录，
在 Action 页面选择对应配置即可出包（会拉取本仓库的源码分支 + 配置片段 + AnyKernel3 打包）。

| 文件 | 说明 |
|---|---|
| `moonwake-kernelsu.json` | MoonWake + KernelSU-Next（AOSP / HyperOS 两个变体，指向上游仓库） |
| `official-ksu.json` | MoonWake + **官方 KernelSU v0.9.5**（指向本仓库 `kernel-source/moonwake-official-ksu` 分支，KSU 源码已内联，`kernelsu.enable=false`） |
| `hypermoon-features.json` | HyperMoon + **MGLRU/BBR/LZ4KD/NOOP**（指向本仓库 `kernel-source/hypermoon-moonwake-features` 分支） |

注意：
- `official-ksu.json` 的 `CONFIG_KPROBES` 必须是 n（由 `vendor/official-ksu.config` 保证），否则链接失败；
- 若 KernelAction 版本对 `kernelsu.enable=false` 的处理不同，可改为保持 `true` 但把 `setupLink` 指向
  `https://raw.githubusercontent.com/tiann/KernelSU/v0.9.5/kernel/setup.sh`、`setupArg` 填 `v0.9.5`
  （源码分支里已有 KernelSU 目录，会跳过 clone）；
- 这些 JSON 基于本仓库已验证的本地构建流程整理，CI 侧未做端到端验证。