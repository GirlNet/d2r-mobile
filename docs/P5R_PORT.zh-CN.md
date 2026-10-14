# P5R 移植准备

English: [P5R_PORT.md](P5R_PORT.md)

状态：**实验性运行时适配进行中；本项目尚不能在 iOS 上运行 P5R。** 当前目标为用户提供的 iPhone 18 Pro、iOS 27，尚未做真机验证。已完成程序改写准备，并开始分离启动、输入和存档中的暗黑 2 逻辑；图形、视频及应用壳仍待适配。

## 已实现

- `dm/tools/inspect_exefs.py`：校验 NSO 段边界及启用的 SHA-256 散列，读取 ELF64 导入与导出，记录构建号，报告依赖提供者候选。宿主替代了原版装载器，因此不使用 `rtld` 的导出来满足依赖。
- `dm/tools/prepare_port.py`：生成本地清单，使用 native 规则域改写 `main`、`sdk`、`subsdkN`，可选逐处指令等价验证。游戏衍生产物保存在仓库外，清单始终明确标记运行时与原生宿主门尚未验证。
- `dm/verify/equiv.py`：支持 Windows 进程启动，穷举条件选择的 NZCV 状态，并保留游戏对测试映射 TSD 页的写入。测试覆盖检查器的损坏输入处理、源文件保护与内存写入比较。
- `dm/host/guest_bootstrap.c`：抽出通用 SDK 启动，执行前检查九个必要符号，再按 libc、系统、模块初始化、参数设置、游戏入口的顺序调用。`DM_GUEST_PROFILE=p5r` 选择实验模式；启动域锁定后不可切换。缺省仍为 D2R。
- P5R 启动域跳过 D2R 的启动钩子、TACT 预取、物品/技能/光标输入链、存档预置与提交前扩展、固定地址堆统计和渲染比例修改，也不报告 D2R 的术士 DLC。未实现导入会中止并报告接口名。
- 音频接管补齐带事件和不带事件的 `OpenDefaultAudioOut` 重载，以及默认设备名称查询。可选接管表允许旧 SDK 没有这些符号；既有 D2R 必需接管检查仍保留。原生音频行为尚待 macOS 测试。
- `.github/workflows/p5r-runtime-tests.yml`：macOS 编译检查、SDK 启动 C 测试、音频测试与 Python 测试；仅使用源码和合成数据，不构建游戏安装包。

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
```

## 可玩版本之前仍需完成

1. 将通用装载器和平台服务与暗黑 2 的启动钩子、固定地址、功能代码、TACT 资源及生成表分离。
2. 验证 P5R 的 SDK 初始化、线程、文件系统、手柄、音频及视频与宿主的兼容性，补齐所需服务，不能依赖原版 Switch 驱动的导出。
3. 找到 P5R 的着色器二进制和反射信息，生成专用翻译数据库，实现它使用的图形调用。暗黑 2 的 shader map/facts 不能作为 P5R 数据复用。
4. 实现 P5R 应用壳、资源挂载、存档路径与合适的触控操作。原来的暗黑 2 无 Xcode 打包壳不包含这个新运行时。
5. 在本地或云端的 macOS/Xcode 环境编译新增 iOS 原生代码，并在真机验证启动、画面、声音、存档读写和游戏流程。iOS 27 目标尚未测试。

## 验证范围

本地 P5R 模块可由改写器处理，没有应用暗黑 2 专用剪口或观测钩子。逐处检查使用 Unicorn 验证改写 CPU 指令；SVC/计时器宿主门、苹果 ABI、GPU 输出与游戏本身需要另行验证。这台 Windows 电脑尚未运行完整苹果宿主/图形测试、独立 LLVM 结构检查及 iOS 编译/真机测试。中文字面量扫描器已统一 Windows 路径并登记两个原有构建期诊断，扫描与字符串表一致性检查均通过。

通用启动代码已使用 Windows C 编译器实际编译，D2R/P5R 两组测试通过：验证调用顺序、主线程/参数区传递、参数 ABI、九种缺入口时不执行 SDK、以及 P5R 不执行 D2R 钩子。它们使用假 SDK，不能代替苹果系统上执行真实游戏的验证。现有 iOS 壳与构建生成表仍绑定 D2R；仅设置启动环境变量不足以得到 P5R 应用。

仓库中未加入游戏程序、资源、密钥、生成着色器内容或安装包。
