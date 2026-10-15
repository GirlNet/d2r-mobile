# P5R port preparation

中文: [P5R_PORT.zh-CN.md](P5R_PORT.zh-CN.md)

Status: **experimental runtime adaptation in progress; P5R does not yet run on iOS through this project.** The user-specified target is iPhone 18 Pro on iOS 27, without device verification. Module preparation is complete and separation of D2R startup, input and save logic has begun; graphics, video and the app shell remain unfinished.

## What is implemented

- `dm/tools/inspect_exefs.py`: validates NSO segment bounds and enabled SHA-256 hashes, reads ELF64 imports/exports, records build IDs and reports candidate dependency providers. Original `rtld` exports are excluded because the host replaces that loader.
- `dm/tools/prepare_port.py`: writes a local inventory, rewrites all `main`/`sdk`/`subsdkN` modules with the native rule domain, and optionally runs per-site instruction equivalence checks. Game-derived outputs stay outside the repository. The manifest always marks runtime and native host gates as unverified.
- `dm/verify/equiv.py`: supports Windows process spawning, covers all NZCV states for conditional selections and preserves guest writes to the test-mapped TSD page. Tests cover the inspector's malformed-input handling, source-file protection and memory-write comparison.
- `dm/tools/prepare_p5r_shaders.py`: finds embedded NVN 11 shaders in a local NSO, validates controls, stages, code and constant ranges, and writes a new output directory outside the repository. Jobs are diagnostic and do not reuse D2R resource types. P5R controls use a `0x850`-byte hash span; the Metal backend rejects unknown layouts and requires explicit P5R map/library paths.
- `dm/host/guest_bootstrap.c`: extracts generic SDK startup, validates nine required symbols before execution, then calls libc, system, module initialization, argument setup and the game entry in order. `DM_GUEST_PROFILE=p5r` selects the experimental profile; selection becomes immutable. D2R remains the default.
- The P5R profile skips D2R bootstrap hooks, TACT prefetch, item/skill/cursor input rewriting, save seeding and pre-commit extensions, fixed-address heap statistics and render scaling, and does not report D2R's Warlock DLC. Unimplemented imports abort with the interface name.
- Audio takeover adds both event and no-event `OpenDefaultAudioOut` overloads, default-device name queries and the `GetAudioOutPlayedSampleCount` import in `subsdk0`. Count consumed PCM frames, excluding stopped/empty-queue silence, carrying partial-frame remainders across buffers and resetting on reopen. An optional takeover table permits older SDKs to omit these symbols, retaining D2R's existing required-entry checks. Full behavioral parity with the actual Switch remains unverified.
- NVN combined-texture binding now implements `GetTextureHandle`, `GetTexelFetchHandle`, `BindTexture` and `BindTextures`, plus the single separate-texture overload. Combined and separate slots retain independent state. Reflection accepts explicit combined texture/sampler/buffer-texture kinds; Metal argument encoding, driver tables and resource-read tracking include them. Handle tags are excluded when extracting sampler IDs.
- `.github/workflows/p5r-runtime-tests.yml`: macOS compilation checks, SDK bootstrap C tests, audio/control/combined-handle tests, iOS ARM64 component compilation and 46 Python tool tests plus a native macOS/iOS synthetic Metal compilation test; uses source and synthetic data only and does not build a game package. Literal scanning supports both older Python and Python 3.14 f-string tokenization.

Static symbol providers include conditional declarations, stubs and functions inside the original Switch SDK. A matching name is not evidence that the host service or driver works. The inspector currently requires the dynamic-table descriptors in the NSO header and supports LZ4/uncompressed segments, not Zbic.

## Run on Windows

Use Python 3.11 or later in an isolated environment. From the repository root:

```powershell
python -m venv E:\port-tools-venv
E:\port-tools-venv\Scripts\python.exe -m pip install lz4 capstone unicorn
E:\port-tools-venv\Scripts\python.exe -X utf8 dm/tools/prepare_port.py "E:\games\P5R\ExeFS" "E:\p5r-work" --verify --jobs 2
```

The source must be an already extracted ExeFS directory containing `main`; NSP/XCI extraction is not performed. This command reads the inputs and writes local output only. It produces `exefs-inspection.json`, `port-preparation.json`, `rewritten/`, logs and optional per-module equivalence TSVs. `equivalence_passed` means instruction trials passed, not that the game launches. Failures leave an incomplete manifest and the failing stage's log.

Tests without game files:

```powershell
python -m unittest discover -s dm/tools -p test_inspect_exefs.py -v
python -m unittest discover -s dm/verify -p test_equiv_compare.py -v
python -m unittest discover -s dm/i18n -p test_scan_literals.py -v
python -m unittest discover -s dm/tools -p test_prepare_p5r_shaders.py -v
python -m unittest discover -s dm/tools -p test_diagnose_p5r_shaders.py -v
python -m unittest discover -s dm/tools -p test_nvn_handle_layout.py -v
```

Prepare embedded shader diagnostics (output directory must not exist):

```powershell
python dm/tools/prepare_p5r_shaders.py "E:\games\P5R\ExeFS\main" "E:\p5r-work\shaders"
```

Pass `diagnostic-jobs.json` to the in-repo `dmsh_xlate` for local SPIR-V diagnostics. Resource/render-state defaults remain unverified; jobs disable the AST optimizer and keep strict floating-point behavior. Generating SPIR-V or passing structural validation does not prove reflection correctness, complete shader coverage or a finished Metal library. Existing `dmsh_build.py` remains tied to D2R maps/type facts and cannot directly build these jobs.

The reproducible `diagnose_p5r_shaders.py` pipeline checks code and extra-constant SHA-256 digests, translates all jobs, runs SPIR-V validation, converts to MSL and records raw texture handles, constant/storage buffers and unresolved bindings. Each stage keeps its log; partial failures return a nonzero exit code and preserve the report. Output must be a new directory outside the repository and extraction tree. Older extractions lack constant digests and must be regenerated.

```powershell
python dm/tools/diagnose_p5r_shaders.py "E:\p5r-work\shaders" "E:\p5r-work\diagnostic" --translator "E:\tools\dmsh_xlate.exe" --spirv-val "E:\tools\spirv-val.exe" --spirv-cross "E:\tools\spirv-cross.exe"
```

Use a runtime matching the translator's .NET target; set `DOTNET_ROOT` to a separately installed runtime if required. On a Mac with Apple's Metal compiler, add `--metal-sdk macosx --metal-sdk iphoneos` to compile diagnostic libraries for both targets. Xcode may require the additional [Metal toolchain component](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components). Libraries remain diagnostic: the pipeline does not generate runtime reflection, shader maps or `b-<chain>` caches. Compilation alone does not verify NVN bindings or GPU output. CI compiles a synthetic kernel for both targets; game-derived shaders stay local.

## Remaining work before a playable build

1. Separate the generic loader and platform services from D2R-specific bootstrap hooks, fixed addresses, feature code, TACT resources and generated tables.
2. Verify P5R's SDK initialization, threading, filesystem, controller, audio and video behavior against the host; implement required services rather than relying on original Switch driver exports.
3. Locate P5R shader binaries and reflection, build their translation database and implement the graphics calls they use. D2R's shader maps/facts cannot be reused as P5R data.
4. Build a P5R app shell with resource mounting, save paths and suitable touch controls. The existing D2R no-Xcode shell does not implement this new runtime.
5. Link, package and sign the complete iOS app, and run on-device startup, graphics, audio, save/load and gameplay checks. Changed components compile for ARM64 with iOS SDK 26.5; the iOS 27 device target remains untested.

## Validation limits

The local P5R modules were accepted by the rewriter without D2R-specific cuts or observation hooks. Per-site checks exercise rewritten CPU instructions in Unicorn; SVC/timer host gates, Apple ABI behavior, GPU output and the game itself require separate validation. Full Apple host/graphics tests, independent LLVM structural checks, complete iOS app linkage/packaging and device tests remain unfinished. The literal scanner now normalizes Windows paths and registers two existing build-only diagnostics; both the literal scan and string-table consistency check pass.

Source-only cloud tests ran on macOS 26 ARM64: both bootstrap suites, audio-buffer release order/events, AudioUnit suspend/resume, the three-thread 100,000-buffer queue test and control-span tests passed. Ten changed host components compile with iOS SDK 26.5; the changed Metal backend also compiles for both macOS and iOS. These are object files, not a linked or installable app. No local game files were read or uploaded in CI.

The generic bootstrap was compiled with a Windows C compiler and passed both D2R/P5R suites: call ordering, main-thread/argument-area forwarding, argument ABI, no SDK execution for each of nine missing-entry cases, and P5R skipping D2R hooks. These use a fake SDK and do not replace running the actual game on Apple systems. The existing iOS shell and generated build tables remain D2R-specific; a startup environment variable alone does not produce a P5R app.

No game executables, assets, keys, generated shader content or install packages are added to the repository.

The supplied local P5R main contains 228 validated embedded controls: 10 vertex, 212 fragment and 6 compute, with 87 carrying 256-byte extra constants and no control-key collisions. Without AST optimization, all 228 diagnostic jobs generate SPIR-V and pass `spirv-val --target-env vulkan1.2`; enabling AST optimization throws exceptions in eight fragment shaders. All intermediate files stay local. These results do not validate GPU output or unknown resource facts.

Using SPIRV-Cross source commit `300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1`, all 228 files also convert to MSL 2.3 source with argument buffers, native texture buffers and padded fragment outputs. These sources have not been compiled into Apple Metal libraries; P5R texture/sampler/constant-buffer bindings remain unverified. They are not ready-to-use rendering assets.

The initial reproducible pipeline passed on all 228 local shaders and found the texture handles outside the previously supported separate-texture table. Follow-up SDK analysis identified the distinct combined-binding API table. The diagnostic decoder now reports the corresponding combined texture/sampler source, independently of resource type facts; unknown banks, unsupported packed-handle modes and resource arrays remain unresolved. Compute configuration, shader type facts, constant/storage-buffer slot mapping, runtime reflection generation and GPU output still require verification. Successful translation alone does not provide a usable rendering library.
