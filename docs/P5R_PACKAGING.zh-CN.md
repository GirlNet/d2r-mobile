# P5R 实验性 iOS 打包

English: [P5R_PACKAGING.md](P5R_PACKAGING.md)

此流程链接完整的 P5R 宿主，并装入本地准备的游戏模块。当前产物是**未签名、禁用游戏启动的实验性安装包**：着色器资源仍是诊断产物，游戏启动尚未验证。签名不会消除这些限制。

## 构建无游戏内容的宿主壳

在装有 Xcode iOS SDK 的 Mac 上，于仓库根目录执行：

```sh
python3 dm/gfx/tools/dmsh_chain.py --header
python3 dm/ios/p5r/build_shell.py /absolute/path/out/p5r-shell
```

无游戏内容的壳包含「运行 GPU 自检」。签名并安装到 iPhone 后，可直接测试合成资源，不需要 RomFS 或 Guest 框架。结果保存在 `Documents/p5r-gpu-selftest.json`，可通过文件共享读取。Metal 3 和设备支持的 Metal 4 路径各运行 48 组；不支持的 Metal 4 会单独报告。自检通过不表示 P5R 图形已验证，也不会开放游戏启动。云端即使有新版 SDK，也可能只提供 Metal 3 设备；编译 Metal 4 路径不等于执行过 GPU 验证。

本地补齐游戏模块的包另提供「启动诊断」，与仍禁用的游戏启动按钮独立。它加载已签名的 Guest 框架，执行 SDK 初始化、模块构造器和参数设置，然后在 30 秒诊断期限内进入 `nnMain`。客体 GPU 初始化、未实现的 NVN 操作、未解决导入和未知内核操作都会先记录，再在操作前停驻。若诊断尚未停止，超时会记录状态并结束进程。探针 API 仍保留只执行 SDK 和只执行模块初始化的两种模式，分别在构造器或 `nnMain` 前停止。此受控启动模式不开放游戏渲染，也不表示游戏已可玩。

每次运行都新建 `Documents/p5r-boot-probe-<UUID>/` 文件夹，包含 `boot-report.json`、`runtime.log` 及独立的 `save`/`temp` 目录，不复用正常存档。报告保留源码/包元数据、SDK/模块检查点及独立的主函数进入/返回标记。`guest_gpu_work_submitted`、`runtime_ready` 和 `graphics_verified` 保持为假。`game_main_returned` 只记录该入口返回，不验证后台工作或图形。阻塞、失败、超时或被中断后仍为运行中的报告都表示执行未完成。若 App 提前退出，请保留两个文件。再次运行前请彻底关闭 App。报告及含游戏内容的包保留在本地。

启动器要求先放好 `Documents/romfs/` 目录才运行此模式，不据此认定内容完整，并开启文件系统操作日志。资源须保留原有路径和大小写；单独的本地资源 ZIP 解压后，应将 `romfs/` 直接放在文稿根目录，不能再套一层压缩包名称目录。挂载 RomFS、打开文件/目录和查询条目类型会增加客体路径检查点；记录时保持 errno 和原有操作行为。资源缺失和平台要求须根据实际报告解决，不能把诊断着色器当作已验证的游戏图形资源。

输出目录必须尚不存在且在仓库外。构建器编译装载器、宿主门、已支持的平台服务、Metal 后端和专用 UIKit/手柄前端，再执行完整 ARM64 iOS 链接。`DM_P5R_ONLY` 移除 D2R 专用分支，源码列表不包含 D2R 功能与生成表。未实现的客体导入仍会明确中止。

产物包括 `P5RMobile-shell-unsigned.ipa`、`build-report.json`、编译/链接日志与 Mach-O 装载命令检查记录。可执行文件必须是具有入口的 ARM64 iOS 应用，且不含内嵌游戏模块节。纯源码 CI 的 `ios-shell` 任务运行同一构建器，将产物保存为 `p5r-ios-shell`，保留七天。壳不包含游戏程序、RomFS、生成的着色器或存档。

## 在 Windows、Linux 或 macOS 上加入本地模块

先运行 [P5R_PORT.zh-CN.md](P5R_PORT.zh-CN.md) 中的程序准备和着色器诊断工具。程序准备必须完成并标为 `equivalence_passed`，着色器诊断必须成功结束。然后执行：

```sh
python3 dm/tools/p5r_pack.py /path/P5RMobile-shell-unsigned.ipa /path/port-preparation /path/shader-diagnostic /path/delivery/P5RMobile-experimental-unsigned.ipa
```

程序准备目录包含 `port-preparation.json` 和 `rewritten/`；诊断目录包含 `diagnostic-report.json`、`reflection-plans/`、`spirv/`、`msl/`。输出必须尚不存在且位于仓库和两个输入目录之外。

装包器核对模块散列、段/键页范围、互不重复的线程键槽、没有 D2R 私有剪口/观测/参数，以及着色器/报告散列。着色器和程序来源必须一致。复用可跨平台的 Mach-O 写入器，将 `main`、`sdk`、`subsdk0` 三个模块写入 `Frameworks/Guest.framework/Guest`，加入装载元数据，并把着色器产物保存在 `p5r-diagnostics/`。诊断产物不会被提升成就绪的运行时着色器库。流程检查 ZIP 路径、重名项及最终 CRC，并保留已存在的输出。

旁边的 `.report.json` 记录散列，并明确保留 `runtime_ready=false`、`graphics_verified=false`、`device_verified=false`、`signed=false`。UIKit 启动页显示图形待验证状态，正常游戏启动保持禁用；独立诊断按钮只执行选定的初始化阶段。未来经过验证的运行时包还需要使用者将自己的 RomFS 放到 `Documents/romfs/`；本工具不把 RomFS 装入 IPA。存档和临时目录独立使用 `save-p5r`、`temp-p5r`。

安装前必须同时签名应用和 Guest 框架。此流程不安装应用、不获取证书、不修改描述文件、不上传游戏衍生文件。含游戏的完整 IPA 和诊断报告应保留在本地。

导入本地 RomFS 后，当前启动器使用“图形初始化诊断”。新模式允许后端对象设置，随后在返回客体或提交游戏 GPU 工作前停止。`stopped_after_gpu_initialization` 只能证明后端初始化，不能证明游戏着色器、CPK 完整性、画面或可玩性。真机运行后提供新生成的本地启动报告和运行日志。App 与 Guest 框架仍需一起签名；更新时保留现有 RomFS。

最新启动器使用“提交前诊断”，在后端初始化后继续 CPU 资源处理和命令录制。到达提交边界、未支持操作或超时后，提供新的启动报告与运行日志。仅有初始化完成标志不代表已提交一帧或游戏画面已验证；更新一起签名的 App/框架时可保留现有本地 RomFS。

专用壳缺省使用 Metal 3，使生产绘制路径与云端 GPU 核对一致。向 `dm/ios/p5r/build_shell.py` 传入 `--metal-backend 4` 可选择 Metal 4 构建。所选后端写入壳/构建元数据并参与源码指纹；跳过的 Metal 4 比较不代表运行时验证。
