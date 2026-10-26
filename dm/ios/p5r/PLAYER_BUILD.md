# Player builds / 玩家构建

`build_shell.py OUTPUT` builds the Metal 4 player shell with
`DM_RUNTIME_DIAGNOSTICS=0`. Performance observation is removed at compile time:
NVN call counters and timing wrappers, per-frame statistics and slow-frame files,
GPU timing callbacks and counter heaps, shader comparison probes, draw-site
histograms, capture probes, text diagnostics and periodic system-state sampling.
Yield timing and diagnostic page-protection timing/counters are omitted too;
the underlying scheduler and dirty-page protection/generations are preserved.
The linked executable is checked for retained diagnostic symbols.

默认构建从编译层关闭性能观测，并检查链接结果是否还保留诊断模块。资源完整性、
绘制参数和绑定范围校验、真实游戏查询、GPU 栅栏、帧节拍与前后台同步仍保留。
删除观测开销本身不代表已经验证持续帧率提升。

Developer builds can explicitly opt back in with `--diagnostics`. Existing
component/GPU tests retain their diagnostic behavior by default. Player builds
ignore old diagnostic keys in `p5r-config.txt`, retaining only the verified
compatibility overrides listed in `player_config.h`; unadopted compute batching
and render-target continuation remain disabled.

开发构建可用 `--diagnostics` 显式开启观测。玩家构建不会让旧配置重开计时、抓取、
丢绘制或候选路径；已有兼容性修复单独保留。

The launcher's **Control layout / 按键布局** opens a full-screen preview using the
production virtual pad. Drag buttons, the left stick or the D-pad to move them.
Drag the toolbar title to uncover controls. Save commits the draft; Cancel
discards it; Reset changes only the draft until saved. Positions are normalized
to the safe area and stored separately for iPhone and iPad. The preview never
publishes game input. The existing right-side camera swipe remains available.

启动菜单中的“按键布局”与游戏复用同一手柄几何和命中逻辑。iPhone、iPad 分别保存；
拖动、保存、取消、重载、恢复默认和移动后的按键输入由无游戏内容的 UIKit 验收 App
验证，模拟器不可用时会明确报告跳过。`t_pad_layout.c` 覆盖归一化和坏配置边界。

Host/menu-only updates do not require a new resource archive. Compare the
deployment input files (including the P5R tables in the playable package) with
the previous archive's file manifest before deciding whether to repackage.
Repository-side tables from another profile are not deployment inputs.

只改宿主或菜单时无需重打资源；以实际交付输入与旧包文件清单的比较结果决定。
