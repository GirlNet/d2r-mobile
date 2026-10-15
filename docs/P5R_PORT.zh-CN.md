# P5R 移植准备

English: [P5R_PORT.md](P5R_PORT.md)

状态：**实验性运行时适配进行中；本项目尚不能在 iOS 上运行 P5R。** 当前目标为用户提供的 iPhone 18 Pro、iOS 27，尚未做真机验证。已完成程序改写准备，并开始分离启动、输入和存档中的暗黑 2 逻辑；图形、视频及应用壳仍待适配。

## 已实现

- `dm/tools/inspect_exefs.py`：校验 NSO 段边界及启用的 SHA-256 散列，读取 ELF64 导入与导出，记录构建号，报告依赖提供者候选。宿主替代了原版装载器，因此不使用 `rtld` 的导出来满足依赖。
- `dm/tools/prepare_port.py`：生成本地清单，使用 native 规则域改写 `main`、`sdk`、`subsdkN`，可选逐处指令等价验证。游戏衍生产物保存在仓库外，清单始终明确标记运行时与原生宿主门尚未验证。
- `dm/verify/equiv.py`：支持 Windows 进程启动，穷举条件选择的 NZCV 状态，并保留游戏对测试映射 TSD 页的写入。测试覆盖检查器的损坏输入处理、源文件保护与内存写入比较。
- `dm/tools/prepare_p5r_shaders.py`：识别本地 NSO 中内嵌的 NVN 11 着色器，验证控制段、阶段、代码和常数段范围，写入新的仓库外目录。输出为诊断作业，不复用 D2R 的资源类型表。P5R 控制段按 `0x850` 字节取键；图形后端拒绝未知布局，并要求显式指定 P5R 的映射和库目录。
- `dm/host/guest_bootstrap.c`：抽出通用 SDK 启动，执行前检查九个必要符号，再按 libc、系统、模块初始化、参数设置、游戏入口的顺序调用。`DM_GUEST_PROFILE=p5r` 选择实验模式；启动域锁定后不可切换。缺省仍为 D2R。
- P5R 启动域跳过 D2R 的启动钩子、TACT 预取、物品/技能/光标输入链、存档预置与提交前扩展、固定地址堆统计和渲染比例修改，也不报告 D2R 的术士 DLC。未实现导入会中止并报告接口名。
- 音频接管补齐带事件和不带事件的 `OpenDefaultAudioOut` 重载、默认设备名称查询，以及 `subsdk0` 导入的 `GetAudioOutPlayedSampleCount`。采样数按实际消耗的 PCM 帧累计，停止和空队列补零不计，跨缓冲保留半帧余数，重新打开时归零。可选接管表允许旧 SDK 没有这些符号；既有 D2R 必需接管检查仍保留。与真实 Switch 的完整行为一致性仍需验证。
- NVN 组合纹理绑定已实现 `GetTextureHandle`、`GetTexelFetchHandle`、`BindTexture`、`BindTextures`，并补齐单个分离纹理重载。组合槽与分离槽独立保存状态；反射接受显式的组合纹理/采样器/缓冲纹理种类，Metal 参数编码、驱动表和资源读取跟踪均覆盖组合槽。取采样器编号时排除句柄标记位。
- `.github/workflows/p5r-runtime-tests.yml`：macOS 编译检查、SDK 启动 C 测试、音频/控制块/组合句柄测试、iOS ARM64 组件编译与 46 个 Python 工具测试，另有 macOS/iOS 合成 Metal 原生编译测试；仅使用源码和合成数据，不构建游戏安装包。文字扫描同时支持旧版 Python 和 Python 3.14 的 f-string 分词。

静态依赖候选包括条件编译声明、占位实现与原版 Switch SDK 内部函数。名字匹配不代表宿主服务或驱动可用。检查器目前要求 NSO 头带动态符号表描述，支持 LZ4 与未压缩段，不支持 Zbic。

## 在 Windows 上运行

使用 Python 3.11 或更高版本的独立环境。在仓库根目录执行：

```powershell
python -m venv E:\port-tools-venv
E:\port-tools-venv\Scripts\python.exe -m pip install lz4 capstone unicorn
E:\port-tools-venv\Scripts\python.exe -X utf8 dm/tools/prepare_port.py "E:\games\P5R\ExeFS" "E:\p5r-work" --verify --jobs 2
```

输入必须是已经解包、包含 `main` 的 ExeFS 文件夹；工具不解包 NSP/XCI。命令只读取源文件并写入本地产物，生成 `exefs-inspection.json`、`port-preparation.json`、`rewritten/`、日志与可选逐模块等价验证 TSV。`equivalence_passed` 仅表示指令试验通过，不代表游戏可以启动。失败会保留未完成清单与对应阶段日志。

不需要游戏文件的测试：

```powershell
python -m unittest discover -s dm/tools -p test_inspect_exefs.py -v
python -m unittest discover -s dm/verify -p test_equiv_compare.py -v
python -m unittest discover -s dm/i18n -p test_scan_literals.py -v
python -m unittest discover -s dm/tools -p test_prepare_p5r_shaders.py -v
python -m unittest discover -s dm/tools -p test_diagnose_p5r_shaders.py -v
python -m unittest discover -s dm/tools -p test_nvn_handle_layout.py -v
```

内嵌着色器诊断准备（输出目录必须尚不存在）：

```powershell
python dm/tools/prepare_p5r_shaders.py "E:\games\P5R\ExeFS\main" "E:\p5r-work\shaders"
```

`diagnostic-jobs.json` 可交给仓内 `dmsh_xlate` 做本地 SPIR-V 诊断。当前使用未验证的资源/渲染状态缺省值，关闭 AST 优化器并保持严格浮点；生成 SPIR-V 或通过结构校验都不代表反射信息正确、覆盖全部游戏着色器或完成 Metal 库。现有 `dmsh_build.py` 仍绑定 D2R 的映射和类型事实，不能直接用于这些作业。

可复用的 `diagnose_p5r_shaders.py` 流程校验代码与附加常数段的 SHA-256 散列，翻译全部作业，运行 SPIR-V 验证，转换 MSL，并记录原始贴图句柄、常量/存储缓冲及未解决的绑定。各阶段保留日志；部分失败返回非零退出码并保留报告。输出必须是仓库和提取目录之外的新目录。旧的提取结果缺少常数散列，需要重新提取。

```powershell
python dm/tools/diagnose_p5r_shaders.py "E:\p5r-work\shaders" "E:\p5r-work\diagnostic" --translator "E:\tools\dmsh_xlate.exe" --spirv-val "E:\tools\spirv-val.exe" --spirv-cross "E:\tools\spirv-cross.exe"
```

使用与翻译器 .NET 目标相符的运行时；若另行安装，可设置 `DOTNET_ROOT`。在具有苹果 Metal 编译器的 Mac 上，加 `--metal-sdk macosx --metal-sdk iphoneos` 可以编译两个目标的诊断库。Xcode 可能需要额外安装 [Metal 工具链组件](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)。这些库仍是诊断产物：流程不生成运行时反射、映射表或 `b-<chain>` 缓存；编译通过不代表 NVN 绑定或 GPU 输出正确。CI 使用合成内核测试两个目标，游戏衍生着色器保留在本地。

## 可玩版本之前仍需完成

1. 将通用装载器和平台服务与暗黑 2 的启动钩子、固定地址、功能代码、TACT 资源及生成表分离。
2. 验证 P5R 的 SDK 初始化、线程、文件系统、手柄、音频及视频与宿主的兼容性，补齐所需服务，不能依赖原版 Switch 驱动的导出。
3. 找到 P5R 的着色器二进制和反射信息，生成专用翻译数据库，实现它使用的图形调用。暗黑 2 的 shader map/facts 不能作为 P5R 数据复用。
4. 实现 P5R 应用壳、资源挂载、存档路径与合适的触控操作。原来的暗黑 2 无 Xcode 打包壳不包含这个新运行时。
5. 完成完整 iOS 应用的链接、打包与签名，并在真机验证启动、画面、声音、存档读写和游戏流程。新增组件已通过 iOS SDK 26.5 的 ARM64 编译，iOS 27 真机目标尚未测试。

## 验证范围

本地 P5R 模块可由改写器处理，没有应用暗黑 2 专用剪口或观测钩子。逐处检查使用 Unicorn 验证改写 CPU 指令；SVC/计时器宿主门、苹果 ABI、GPU 输出与游戏本身需要另行验证。完整苹果宿主/图形测试、独立 LLVM 结构检查、iOS 应用链接/打包及真机测试仍未完成。中文字面量扫描器已统一 Windows 路径并登记两个原有构建期诊断，扫描与字符串表一致性检查均通过。

源码云端测试已在 macOS 26 ARM64 运行：启动两组测试、音频缓冲释放顺序/事件、AudioUnit 暂停恢复、10 万块三线程队列和控制段范围测试通过。使用 iOS SDK 26.5 编译了 10 个改动的宿主组件，修改后的 Metal 后端同时通过 macOS/iOS 编译；这仅生成目标文件，不代表完整应用已链接或可安装。云端没有读取或上传本地游戏文件。

通用启动代码已使用 Windows C 编译器实际编译，D2R/P5R 两组测试通过：验证调用顺序、主线程/参数区传递、参数 ABI、九种缺入口时不执行 SDK、以及 P5R 不执行 D2R 钩子。它们使用假 SDK，不能代替苹果系统上执行真实游戏的验证。现有 iOS 壳与构建生成表仍绑定 D2R；仅设置启动环境变量不足以得到 P5R 应用。

仓库中未加入游戏程序、资源、密钥、生成着色器内容或安装包。

本地所给 P5R main 中找到 228 个有效内嵌控制块：10 个顶点、212 个片元、6 个计算，87 个带 256 字节附加常数段，无控制键冲突。关闭 AST 优化后，228 个诊断作业生成 SPIR-V，并通过 `spirv-val --target-env vulkan1.2`；启用 AST 优化时有 8 个片元着色器抛出异常。全部中间文件留在本地；这些结果不验证 GPU 输出或未知类型事实。

随后使用 SPIRV-Cross 源码提交 `300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1`，228 个文件均成功转换为 MSL 2.3 源码（参数缓冲、原生贴图缓冲、片元输出填充选项）。尚未将这些源码编译成苹果 Metal 库，也未验证 P5R 的贴图/采样器/常量缓冲绑定；不能当作可用的渲染资源。

初次可复用流水线完成了全部 228 个本地着色器的诊断，并发现纹理句柄不在之前支持的分离纹理表中。后续 SDK 分析确认了独立的组合绑定 API 表；诊断解码器现在可报告对应的组合纹理/采样器来源，但不据此推断资源类型。未知常量缓冲库、未实现的句柄模式及资源数组仍标为未解决。计算配置、类型事实、常量/存储缓冲槽映射、运行时反射生成及 GPU 输出仍需验证，翻译成功尚不能产出可用的渲染库。
