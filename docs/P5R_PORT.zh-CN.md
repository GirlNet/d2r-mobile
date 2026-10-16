# P5R 移植准备

English: [P5R_PORT.md](P5R_PORT.md)

状态：**实验性运行时适配进行中；本项目尚不能在 iOS 上运行 P5R。** 当前目标为用户提供的 iPhone 18 Pro、iOS 27，尚未做真机验证。已完成程序改写准备，并开始分离启动、输入和存档中的暗黑 2 逻辑；图形、视频、触控操作及真实游戏启动仍待适配。

## 已实现

- `dm/tools/inspect_exefs.py`：校验 NSO 段边界及启用的 SHA-256 散列，读取 ELF64 导入与导出，记录构建号，报告依赖提供者候选。宿主替代了原版装载器，因此不使用 `rtld` 的导出来满足依赖。
- `dm/tools/prepare_port.py`：生成本地清单，使用 native 规则域改写 `main`、`sdk`、`subsdkN`，可选逐处指令等价验证。游戏衍生产物保存在仓库外，清单始终明确标记运行时与原生宿主门尚未验证。
- `dm/verify/equiv.py`：支持 Windows 进程启动，穷举条件选择的 NZCV 状态，并保留游戏对测试映射 TSD 页的写入。测试覆盖检查器的损坏输入处理、源文件保护与内存写入比较。
- `dm/tools/prepare_p5r_shaders.py`：识别本地 NSO 中内嵌的 NVN 11 着色器，验证控制段、阶段、代码和常数段范围，写入新的仓库外目录。输出为诊断作业，不复用 D2R 的资源类型表。P5R 控制段按 `0x850` 字节取键；图形后端拒绝未知布局，并要求显式指定 P5R 的映射和库目录。
- `dm/host/guest_bootstrap.c`：抽出通用 SDK 启动，执行前检查九个必要符号，再按 libc、系统、模块初始化、参数设置、游戏入口的顺序调用。`DM_GUEST_PROFILE=p5r` 选择实验模式；启动域锁定后不可切换。缺省仍为 D2R。
- P5R 启动域跳过 D2R 的启动钩子、TACT 预取、物品/技能/光标输入链、存档预置与提交前扩展、固定地址堆统计和渲染比例修改，也不报告 D2R 的术士 DLC。未实现导入会中止并报告接口名。
- 音频接管补齐带事件和不带事件的 `OpenDefaultAudioOut` 重载、默认设备名称查询，以及 `subsdk0` 导入的 `GetAudioOutPlayedSampleCount`。采样数按实际消耗的 PCM 帧累计，停止和空队列补零不计，跨缓冲保留半帧余数，重新打开时归零。可选接管表允许旧 SDK 没有这些符号；既有 D2R 必需接管检查仍保留。与真实 Switch 的完整行为一致性仍需验证。
- NVN 组合纹理绑定已实现 `GetTextureHandle`、`GetTexelFetchHandle`、`BindTexture`、`BindTextures`，并补齐单个分离纹理重载。组合槽与分离槽独立保存状态；反射接受显式的组合纹理/采样器/缓冲纹理种类，Metal 参数编码、驱动表和资源读取跟踪均覆盖组合槽。取采样器编号时排除句柄标记位。
- 计算诊断作业现在从受支持的 NVN 11 控制块提取线程组尺寸，不再缺省为单线程。提取清单升级为 schema 2 并保存带散列的控制块；诊断加载核对尺寸后，在转换 MSL 前再次核对 SPIR-V 的 LocalSize。运行时计算反射拒绝缺失、小数、零、溢出及不支持的尺寸。准备流程上限为 1024 个线程，不代表 GPU 执行或局部/共享内存配置已验证。
- `dmsh_build.py` 修正 Ryujinx 缓冲 Write 标志为第 0 位；此前可写存储缓冲可能被反射成只读。修正后着色器缓存版本改变：需要按原准备流程重建 B 路线的库/反射并重新生成 `c1_full.tsv`。旧库不会被接受；旧的保护表会触发保守的独占常数缓冲。
- `p5r_reflection.py` 根据 MSL 参数成员和翻译器描述符生成诊断反射草案。存储缓冲按明确的翻译器槽对应，不依赖描述符顺序或 Metal 参数编号。每个绑定记录来源、候选 NVN 槽、写权限与待验证事项；缺失描述符和不支持的成员会明确保留。运行时拒绝加载诊断或未验证草案，P5R 反射还必须具有明确的就绪标记。
- 缓冲槽解码现在依据独立核对过的 SDK 绑定命令/队列记录。图形阶段 uniform 库 3–16 对应 API 槽 0–13；计算阶段直接库仅为 3–7，其余 uniform 指针在驱动表中。着色器读取驱动库 0 时，Metal 后端现在同时填写计算 uniform 地址表和 storage 地址表。合成 C 测试覆盖阶段表、隔离、边界及解绑。这确认的是 CPU 接口映射，不是 GPU 输出。
- `maxwell_memory_audit.py` 使用仓内 Maxwell 指令表扫描翻译器完整已解码计算范围，跳过调度字，将未知/有歧义的指令保留为阻塞项。出现局部/共享内存操作就不能证明内存未使用。需要重新编译 `dmsh_xlate` 以输出新增的 `decoded_size` 元数据；计算诊断拒绝旧版翻译器。本次源码变化也改变了着色器缓存版本。
- `dmsh_xlate` 用查询审计 schema 1 记录资源/管线查询的实际回答及其来源。诊断报告按查询、句柄与常量缓冲库汇总缺省回答，并保留受影响的着色器键。作业输入、缺失/无效输入和固定缺省值分开记录；审计不覆盖全部继承的宿主能力查询。重跑诊断前需重编译翻译器。`maxwell_texture_audit.py` 另外记录同着色器 TEXS/TLDS 立即数句柄的类型约束，附指令位置和来源散列；1D/缓冲歧义、未知指令及类型冲突均不能确认为旁证。这些约束仅是诊断依据，不验证已绑定的纹理对象、格式或绘制状态，也不会开启运行时加载。翻译器变化后需按原流程重新生成着色器缓存/头文件；本地生成的缓存文件不提交。
- `t_nvn_texture_gpu.m` 调用共享的 `nvn_texture_selftest.m`，在设备支持的 Metal 3/4 计算队列上测试合成 2D 资源。测试解析真实反射元数据，复用后端的有界句柄选择器，并将原始参数字与苹果参数编码器比较。用例覆盖组合/分离槽隔离、阶段 0/1/5 的状态切片、组合槽 0/1/2/31、重绑/解绑、带标记的高位采样器编号、最近点/钳制及线性/重复采样、逐像素读取、尺寸、驱动表字节和输出边界。退出 77 表示没有设备；退出 78 表示 48 组 Metal 3 用例通过、Metal 4 不支持且已跳过。两种 API 均支持时运行 96 组。此范围仅为合成计算测试，不验证实际 P5R 对象、光栅输出或所有纹理/视图类型。iOS 壳提供同一自检入口并保存本地报告，不修改游戏就绪状态。
- 既有 fetch 特化证明仅有覆盖分离纹理槽的两字位图。组合槽现在会在索引位图前拒绝这项优化，继续使用普通纹理路径。C 测试覆盖位图两端和全部组合槽。
- ELF 导入解析在检查客体和宿主定义后，将仍未定义的弱符号保持为零，让可选 SDK 回调继续使用空指针检查的缺省路径；缺失强符号仍分配诊断桩。合成测试直接运行真实重定位/解析代码，覆盖 ABS64、GLOB_DAT、JUMP_SLOT、已有提供者、加数，以及同名强弱引用。依据 [ELF gABI 符号规则](https://www.sco.com/developers/gabi/1998-04-29/ch4.symtab.html)。
- 分配诊断包装函数按已装客体导出名解析 `StandardAllocator::Allocate`，并用原子缓存代替固定 SDK 地址。原样转发分配器对象、大小、对齐和返回值；缺失或递归入口会明确失败。原生合成测试覆盖并发首次调用和空返回，不替换为宿主分配器。
- 退出请求处理临界区使用可选宿主接管，以互斥锁保护进程级嵌套计数，避免宿主 oe 初始化后访问 Horizon 服务对象。原生运行环境测试覆盖配对、嵌套及并发进出；此计数器不实现 Horizon 退出请求投递。
- 分阶段诊断支持只执行 SDK、只执行模块初始化及受控启动三种模式。启动器会在初始化后进入 `nnMain`，记录主函数进入/返回及客体文件路径检查点，阻止 GPU 初始化、未实现的 NVN/导入及未知内核操作。30 秒期限会保存超时状态并结束尚未停止的执行。就绪和图形标记保持为假；见 [P5R_PACKAGING.zh-CN.md](P5R_PACKAGING.zh-CN.md)。
- 专用 UIKit/手柄壳及跨平台本地打包见 [P5R_PACKAGING.zh-CN.md](P5R_PACKAGING.zh-CN.md)。完整无游戏内容的 ARM64 iOS 宿主已在 CI 链接，本地改写模块可作为 Guest.framework 加入。产物仍是未签名实验包；图形资源仍为诊断时，游戏启动保持禁用。
- `.github/workflows/p5r-runtime-tests.yml`：macOS 编译检查、SDK 启动 C 测试、音频/控制块/组合句柄测试、iOS ARM64 组件编译与 Python 工具测试，另有 macOS/iOS 合成 Metal 原生编译测试；仅使用源码和合成数据，不构建游戏安装包。文字扫描同时支持旧版 Python 和 Python 3.14 的 f-string 分词。

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
python dm/gfx/tools/dmsh_chain.py --header
python -m unittest discover -s dm/tools -p test_shader_buffer_reflection.py -v
python -m unittest discover -s dm/tools -p test_p5r_reflection.py -v
python -m unittest discover -s dm/tools -p test_maxwell_memory_audit.py -v
python -m unittest discover -s dm/tools -p test_maxwell_texture_audit.py -v
python -m unittest discover -s dm/tools -p test_shader_query_audit.py -v
```

内嵌着色器诊断准备（输出目录必须尚不存在）：

```powershell
python dm/tools/prepare_p5r_shaders.py "E:\games\P5R\ExeFS\main" "E:\p5r-work\shaders"
```

`diagnostic-jobs.json` 可交给仓内 `dmsh_xlate` 做本地 SPIR-V 诊断。当前使用未验证的资源/渲染状态缺省值，关闭 AST 优化器并保持严格浮点；生成 SPIR-V 或通过结构校验都不代表反射信息正确、覆盖全部游戏着色器或完成 Metal 库。现有 `dmsh_build.py` 仍绑定 D2R 的映射和类型事实，不能直接用于这些作业。

可复用的 `diagnose_p5r_shaders.py` 流程校验代码、控制块与附加常数段的 SHA-256 散列，翻译全部作业，运行 SPIR-V 验证，转换 MSL，并记录原始贴图句柄、常量/存储缓冲及未解决的绑定。计算 LocalSize 必须与带散列的控制块一致。各阶段保留日志；部分失败返回非零退出码并保留报告。输出必须是仓库和提取目录之外的新目录。schema 1 提取结果需要重新生成；schema 2 新增 `control/` 目录及有来源依据的线程组尺寸。

```powershell
python dm/tools/diagnose_p5r_shaders.py "E:\p5r-work\shaders" "E:\p5r-work\diagnostic" --translator "E:\tools\dmsh_xlate.exe" --spirv-val "E:\tools\spirv-val.exe" --spirv-cross "E:\tools\spirv-cross.exe"
```

使用与翻译器 .NET 目标相符的运行时；若另行安装，可设置 `DOTNET_ROOT`。在具有苹果 Metal 编译器的 Mac 上，加 `--metal-sdk macosx --metal-sdk iphoneos` 可以编译两个目标的诊断库。Xcode 可能需要额外安装 [Metal 工具链组件](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)。这些库仍是诊断产物：流程不生成运行时反射、映射表或 `b-<chain>` 缓存；编译通过不代表 NVN 绑定或 GPU 输出正确。CI 使用合成内核测试两个目标，游戏衍生着色器保留在本地。

流水线现在还写出 `reflection-plans/<key>.plan.json`，以散列关联控制块、代码、常数段及 SPIR-V、翻译器描述符和 MSL。`binding_coverage_complete` 表示每个已报告描述符都有受支持的 MSL 成员对应，且每个成员都有候选绑定；不代表资源类型、缓冲映射、翻译状态或 GPU 输出已经验证。所有草案均保留 `diagnostic_only=true`、`resource_facts_verified=false`、`runtime_ready=false`，不能作为运行时着色器包。报告统计缺失/未解析及未验证绑定，供后续处理。

`slot_mapping_verified` 区分受支持的 SDK 缓冲/地址表映射与未解析的库；`resource_type_verified` 独立记录资源类型。计算草案另含 `compute_memory_audit`：只有已解码范围内没有局部/共享/有歧义的内存操作及未知指令字，`memory_unused_proven` 才为真。这些检查覆盖已提取代码和受支持布局，不覆盖外部着色器或实际 GPU 执行。CI 编译翻译器并测试合成 Maxwell 代码；另一个合成 Metal 计算测试在运行器具有 Metal 设备时核对原始参数指针、写权限及 32/64 线程组，退出 77 会明确警告已跳过，不能视为 GPU 验证。

## 可玩版本之前仍需完成

1. 将通用装载器和平台服务与暗黑 2 的启动钩子、固定地址、功能代码、TACT 资源及生成表分离。
2. 验证 P5R 的 SDK 初始化、线程、文件系统、手柄、音频及视频与宿主的兼容性，补齐所需服务，不能依赖原版 Switch 驱动的导出。
3. 找到 P5R 的着色器二进制和反射信息，生成专用翻译数据库，实现它使用的图形调用。暗黑 2 的 shader map/facts 不能作为 P5R 数据复用。
4. 在专用壳中验证 P5R 资源挂载和存档路径，并加入合适的触控操作。新壳直接接手柄状态，存档/临时目录独立。
5. 完成经过验证的运行时图形出包，同时签名应用/框架，并在真机验证启动、画面、声音、存档读写和游戏流程。宿主完整链接与实验性未签名打包已有专用流程，iOS 27 真机目标尚未测试。

## 验证范围

本地 P5R 模块可由改写器处理，没有应用暗黑 2 专用剪口或观测钩子。逐处检查使用 Unicorn 验证改写 CPU 指令；SVC/计时器宿主门、苹果 ABI、GPU 输出与游戏本身需要另行验证。完整游戏宿主/图形测试、独立 LLVM 结构检查及真机测试仍未完成。宿主完整链接和实验性未签名 IPA 打包现已通过专用 P5R 流程。中文字面量扫描器已统一 Windows 路径并登记两个原有构建期诊断，扫描与字符串表一致性检查均通过。

源码云端测试已在 macOS 26 ARM64 运行：启动两组测试、音频缓冲释放顺序/事件、AudioUnit 暂停恢复、10 万块三线程队列和控制段范围测试通过。使用 iOS SDK 26.5 编译了 10 个改动的宿主组件，修改后的 Metal 后端同时通过 macOS/iOS 编译；另有 ios-shell 任务编译全部 45 个所选宿主/后端/前端源码，链接 ARM64 iOS 可执行文件，核对 Mach-O 入口/平台并打包无游戏内容的未签名壳。云端没有读取或上传本地游戏文件。

通用启动代码已使用 Windows C 编译器实际编译，D2R/P5R 两组测试通过：验证调用顺序、主线程/参数区传递、参数 ABI、九种缺入口时不执行 SDK、以及 P5R 不执行 D2R 钩子。它们使用假 SDK，不能代替苹果系统上执行真实游戏的验证。原有 iOS 壳与构建生成表仍绑定 D2R；专用 P5R 壳排除了这些功能源码和生成表。链接和打包依然不能验证真实游戏启动。

仓库中未加入游戏程序、资源、密钥、生成着色器内容或安装包。

本地所给 P5R main 中找到 228 个有效内嵌控制块：10 个顶点、212 个片元、6 个计算，87 个带 256 字节附加常数段，无控制键冲突。关闭 AST 优化后，228 个诊断作业生成 SPIR-V，并通过 `spirv-val --target-env vulkan1.2`；启用 AST 优化时有 8 个片元着色器抛出异常。全部中间文件留在本地；这些结果不验证 GPU 输出或未知类型事实。

随后使用 SPIRV-Cross 源码提交 `300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1`，228 个文件均成功转换为 MSL 2.3 源码（参数缓冲、原生贴图缓冲、片元输出填充选项）。尚未将这些源码编译成苹果 Metal 库，也未验证 P5R 的贴图/采样器/常量缓冲绑定；不能当作可用的渲染资源。

初次可复用流水线完成了全部 228 个本地着色器的诊断，并发现纹理句柄不在之前支持的分离纹理表中。后续 SDK 分析确认了独立的组合绑定 API 表；诊断解码器现在可报告对应的组合纹理/采样器来源，但不据此推断资源类型。未知常量缓冲库、未实现的句柄模式及资源数组仍标为未解决。计算线程组尺寸后来已与 SDK 元数据读取和 SPIR-V 输出核对。缓冲映射已在 SDK 命令/状态层核对，计算内存使用已加入解码指令审计；类型/状态事实、经过验证的运行时着色器出包与实际 GPU 输出仍待完成。翻译成功尚不能产出可用的渲染库。
