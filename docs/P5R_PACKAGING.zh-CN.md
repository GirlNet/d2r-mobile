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

本地补齐游戏模块的包另提供「模块初始化诊断」，与仍禁用的游戏启动按钮独立。它加载已签名的 Guest 框架，执行六个 SDK 启动入口，然后运行模块构造器并设置宿主参数，始终在 `nnMain` 之前停止。GPU 初始化、未实现的 NVN 操作及未解决的导入仍会先记录并停驻，不执行该操作。若初始化尚未停止，30 秒期限会记录超时并结束进程。探针 API 仍保留只执行 SDK、在构造器前停止的初始模式，此初始模式不需要 RomFS。模块构造器可能暴露更多平台或资源要求，SDK 阶段完成不代表这些构造器或游戏启动已验证。

每次运行都新建 `Documents/p5r-boot-probe-<UUID>/` 文件夹，包含 `boot-report.json`、`runtime.log` 及独立的 `save`/`temp` 目录，不复用正常存档。报告会在可用时带上宿主源码指纹/包元数据，逐入口和逐模块检查点、独立的构造器已开始/已完成标记；SDK 入口与参数设置分开计数。游戏主函数/GPU/就绪/图形标记保持为假。`stopped_before_game_main` 表示到达设定边界；`blocked`、`failed`、`timeout` 及被中断后仍为 `running` 的报告都表示执行未完成。若 App 提前退出，请保留两个文件。再次运行前请彻底关闭 App。报告及含游戏内容的包保留在本地。

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
