# P5R port preparation

中文: [P5R_PORT.zh-CN.md](P5R_PORT.zh-CN.md)

Status: **experimental runtime adaptation in progress; P5R does not yet run on iOS through this project.** The user-specified target is iPhone 18 Pro on iOS 27, without device verification. Module preparation is complete and separation of D2R startup, input and save logic has begun; graphics, video, touch controls and real game startup remain unfinished.

## What is implemented

- `dm/tools/inspect_exefs.py`: validates NSO segment bounds and enabled SHA-256 hashes, reads ELF64 imports/exports, records build IDs and reports candidate dependency providers. Original `rtld` exports are excluded because the host replaces that loader.
- `dm/tools/prepare_port.py`: writes a local inventory, rewrites all `main`/`sdk`/`subsdkN` modules with the native rule domain, and optionally runs per-site instruction equivalence checks. Game-derived outputs stay outside the repository. The manifest always marks runtime and native host gates as unverified.
- `dm/verify/equiv.py`: supports Windows process spawning, covers all NZCV states for conditional selections and preserves guest writes to the test-mapped TSD page. Tests cover the inspector's malformed-input handling, source-file protection and memory-write comparison.
- `dm/tools/prepare_p5r_shaders.py`: finds embedded NVN 11 shaders in a local NSO, validates controls, stages, code and constant ranges, and writes a new output directory outside the repository. Jobs are diagnostic and do not reuse D2R resource types. P5R controls use a `0x850`-byte hash span; the Metal backend rejects unknown layouts and requires explicit P5R map/library paths.
- `dm/host/guest_bootstrap.c`: extracts generic SDK startup, validates nine required symbols before execution, then calls libc, system, module initialization, argument setup and the game entry in order. `DM_GUEST_PROFILE=p5r` selects the experimental profile; selection becomes immutable. D2R remains the default.
- The P5R profile skips D2R bootstrap hooks, TACT prefetch, item/skill/cursor input rewriting, save seeding and pre-commit extensions, fixed-address heap statistics and render scaling, and does not report D2R's Warlock DLC. Unimplemented imports abort with the interface name.
- Audio takeover adds both event and no-event `OpenDefaultAudioOut` overloads, default-device name queries and the `GetAudioOutPlayedSampleCount` import in `subsdk0`. Count consumed PCM frames, excluding stopped/empty-queue silence, carrying partial-frame remainders across buffers and resetting on reopen. An optional takeover table permits older SDKs to omit these symbols, retaining D2R's existing required-entry checks. Full behavioral parity with the actual Switch remains unverified.
- NVN combined-texture binding now implements `GetTextureHandle`, `GetTexelFetchHandle`, `BindTexture` and `BindTextures`, plus the single separate-texture overload. Combined and separate slots retain independent state. Reflection accepts explicit combined texture/sampler/buffer-texture kinds; Metal argument encoding, driver tables and resource-read tracking include them. Handle tags are excluded when extracting sampler IDs.
- Compute diagnostic jobs now take their workgroup dimensions from the supported NVN 11 control, rather than defaulting to one thread. Extraction schema 2 saves hashed controls; diagnostic loading checks dimensions against them, then verifies SPIR-V's literal LocalSize before MSL conversion. Runtime compute reflection rejects missing, fractional, zero, overflowing or unsupported dimensions. The preparation limit is 1024 threads; this does not attest to GPU execution or validate local/shared memory configuration.
- `dmsh_build.py` now interprets Ryujinx's buffer Write flag as bit 0. Previously writable storage buffers could be reflected as read-only. The shader cache version changes with this fix: rebuild route B shader libraries/reflection and regenerate `c1_full.tsv` through the existing preparation workflow. Old libraries are not accepted; an old guard table uses conservative exclusive constant buffers.
- `p5r_reflection.py` produces diagnostic reflection plans from MSL argument members and translator descriptors. Storage buffers match explicit translator slots, independently of descriptor ordering or Metal argument ids. Each binding records its source, candidate NVN slot, write access and outstanding verification; missing descriptors and unsupported members remain visible. Runtime loading rejects diagnostic/unverified plans, and P5R reflection requires explicit readiness markers.
- Buffer slot decoding now follows independently checked SDK binding commands/queue records. Graphics uniform banks 3–16 map to API slots 0–13; compute direct banks are limited to 3–7, with other uniform pointers in the driver table. The Metal backend now fills the compute uniform address table alongside storage addresses when a shader reads driver bank 0. Synthetic C tests cover stage tables, isolation, bounds and unbinding. This establishes CPU-side interface mapping, not GPU output.
- `maxwell_memory_audit.py` scans the translator's full decoded compute extent with the vendored Maxwell instruction table, skipping scheduling words and retaining unknown/ambiguous instructions as blockers. Local/shared-memory operations prevent an unused-memory proof. Rebuild `dmsh_xlate` for its new `decoded_size` metadata; an old translator is rejected for compute diagnostics. This source change also changes the shader cache version.
- `dmsh_xlate` records resource/pipeline query answers and their provenance in query audit schema 1. Diagnostic reports group default answers by query, handle and constant-buffer bank, preserving the affected shader keys. Job inputs, missing/invalid inputs and fixed defaults remain distinct; the audit does not cover every inherited host-capability query. Rebuild the translator before rerunning diagnostics. `maxwell_texture_audit.py` adds same-shader TEXS/TLDS immediate-handle constraints with instruction offsets and source hashes; 1D/buffer ambiguity, unknown instructions and conflicting types do not corroborate an answer. These constraints are diagnostic evidence only: they do not validate bound texture objects, formats or draw state, and never enable runtime loading. The translator change requires the normal shader-cache/header regeneration; do not commit locally generated cache files.
- `t_nvn_texture_gpu.m` runs the shared `nvn_texture_selftest.m` against synthetic 2D resources through supported Metal 3/4 compute queues. It parses real reflection metadata, uses the same bounded handle selector as the backend, and compares raw argument words with Apple's argument encoder. Cases cover combined/separate slot isolation, state slices for stages 0/1/5, combined slots 0/1/2/31, rebind/unbind, tagged high sampler IDs, nearest/clamp and linear/repeat sampling, texel reads, dimensions, driver-table bytes and output guards. Exit 77 means no device; exit 78 means 48 Metal 3 cases passed while Metal 4 is unsupported and skipped. Supporting both APIs runs 96 cases. This is synthetic compute coverage, not actual P5R objects, raster output or all texture/view types. The iOS shell exposes the same self-test and saves a local report without changing game readiness.
- Existing fetch-specialization proofs have a two-word bitmap for separate texture slots only. Combined slots now reject that optimization before indexing the bitmap; the normal texture path remains available. C tests cover both bitmap boundaries and all combined slots.
- ELF import resolution preserves unresolved weak symbols as zero after checking guest and host definitions. Optional SDK callbacks therefore keep their null-check fallback; missing strong imports still receive diagnostic stubs. Synthetic tests exercise the actual relocation/resolver code for ABS64, GLOB_DAT and JUMP_SLOT, existing providers, addends and strong/weak references to the same name. This follows the [ELF gABI symbol rules](https://www.sco.com/developers/gabi/1998-04-29/ch4.symtab.html).
- The allocation diagnostic wrapper resolves `StandardAllocator::Allocate` by the loaded guest export, with an atomic cache, instead of using a fixed SDK address. It forwards the original allocator object, size, alignment and return value; missing or recursive originals fail explicitly. Native synthetic tests cover concurrent initial calls and null results without substituting a host allocator.
- The staged probe supports SDK-only, module-only and controlled startup modes. The launcher enters `nnMain` after initialization, records main entry/return and guest-path filesystem checkpoints, and blocks GPU initialization, unimplemented NVN/imports and unknown kernel operations. A 30-second deadline persists timeout state and terminates unfinished execution. Readiness and graphics markers remain false; see [P5R_PACKAGING.md](P5R_PACKAGING.md).
- Dedicated UIKit/controller shell and cross-platform local packaging: see [P5R_PACKAGING.md](P5R_PACKAGING.md). The complete game-free ARM64 iOS host links in CI; local rewritten modules can be added as Guest.framework. Resulting experimental packages remain unsigned and disable game launch while graphics are diagnostic.
- `.github/workflows/p5r-runtime-tests.yml`: macOS compilation checks, SDK bootstrap C tests, audio/control/combined-handle tests, iOS ARM64 component compilation and Python tool tests plus a native macOS/iOS synthetic Metal compilation test; uses source and synthetic data only and does not build a game package. Literal scanning supports both older Python and Python 3.14 f-string tokenization.

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
python dm/gfx/tools/dmsh_chain.py --header
python -m unittest discover -s dm/tools -p test_shader_buffer_reflection.py -v
python -m unittest discover -s dm/tools -p test_p5r_reflection.py -v
python -m unittest discover -s dm/tools -p test_maxwell_memory_audit.py -v
python -m unittest discover -s dm/tools -p test_maxwell_texture_audit.py -v
python -m unittest discover -s dm/tools -p test_shader_query_audit.py -v
```

Prepare embedded shader diagnostics (output directory must not exist):

```powershell
python dm/tools/prepare_p5r_shaders.py "E:\games\P5R\ExeFS\main" "E:\p5r-work\shaders"
```

Pass `diagnostic-jobs.json` to the in-repo `dmsh_xlate` for local SPIR-V diagnostics. Resource/render-state defaults remain unverified; jobs disable the AST optimizer and keep strict floating-point behavior. Generating SPIR-V or passing structural validation does not prove reflection correctness, complete shader coverage or a finished Metal library. Existing `dmsh_build.py` remains tied to D2R maps/type facts and cannot directly build these jobs.

The reproducible `diagnose_p5r_shaders.py` pipeline checks code, control and extra-constant SHA-256 digests, translates all jobs, runs SPIR-V validation, converts to MSL and records raw texture handles, constant/storage buffers and unresolved bindings. Compute LocalSize must match the hashed control. Each stage keeps its log; partial failures return a nonzero exit code and preserve the report. Output must be a new directory outside the repository and extraction tree. Schema 1 extractions must be regenerated; schema 2 adds a `control/` directory and source-backed workgroup dimensions.

```powershell
python dm/tools/diagnose_p5r_shaders.py "E:\p5r-work\shaders" "E:\p5r-work\diagnostic" --translator "E:\tools\dmsh_xlate.exe" --spirv-val "E:\tools\spirv-val.exe" --spirv-cross "E:\tools\spirv-cross.exe"
```

Use a runtime matching the translator's .NET target; set `DOTNET_ROOT` to a separately installed runtime if required. On a Mac with Apple's Metal compiler, add `--metal-sdk macosx --metal-sdk iphoneos` to compile diagnostic libraries for both targets. Xcode may require the additional [Metal toolchain component](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components). Libraries remain diagnostic: the pipeline does not generate runtime reflection, shader maps or `b-<chain>` caches. Compilation alone does not verify NVN bindings or GPU output. CI compiles a synthetic kernel for both targets; game-derived shaders stay local.

The pipeline now also writes `reflection-plans/<key>.plan.json`. Plans link hashed controls, code and constants to hashed SPIR-V, translator descriptors and MSL. `binding_coverage_complete` means every reported descriptor has a matching supported MSL member and every member has a candidate binding; it does not verify resource types, buffer mappings, translation state or GPU output. All plans retain `diagnostic_only=true`, `resource_facts_verified=false` and `runtime_ready=false`; they are not runtime shader packages. The report keeps counts of missing/unresolved and unverified bindings for follow-up work.

`slot_mapping_verified` distinguishes supported SDK buffer/table mappings from unresolved banks; `resource_type_verified` remains separate. Compute plans also include `compute_memory_audit`: `memory_unused_proven` requires no local/shared/ambiguous memory operations or unknown instruction words anywhere in the decoded extent. These checks cover the extracted code and supported layout, not external shaders or actual GPU execution. CI builds the translator and tests synthetic Maxwell code. A separate synthetic Metal compute test checks raw argument pointers, write access and 32/64-thread groups when the runner exposes a Metal device; exit 77 produces an explicit skipped warning and is not GPU validation.

## Remaining work before a playable build

1. Separate the generic loader and platform services from D2R-specific bootstrap hooks, fixed addresses, feature code, TACT resources and generated tables.
2. Verify P5R's SDK initialization, threading, filesystem, controller, audio and video behavior against the host; implement required services rather than relying on original Switch driver exports.
3. Locate P5R shader binaries and reflection, build their translation database and implement the graphics calls they use. D2R's shader maps/facts cannot be reused as P5R data.
4. Validate P5R resource mounting and save paths in the dedicated shell, and add suitable touch controls. The new shell uses direct controller state and isolated save/temp paths.
5. Complete verified runtime graphics packaging, sign the application/framework together, and run on-device startup, graphics, audio, save/load and gameplay checks. Full host linkage and experimental unsigned packaging have a dedicated path; the iOS 27 device target remains untested.

## Validation limits

The local P5R modules were accepted by the rewriter without D2R-specific cuts or observation hooks. Per-site checks exercise rewritten CPU instructions in Unicorn; SVC/timer host gates, Apple ABI behavior, GPU output and the game itself require separate validation. Full game host/graphics tests, independent LLVM structural checks and device tests remain unfinished. Complete host linkage and experimental unsigned IPA packaging now pass through the dedicated P5R workflow. The literal scanner now normalizes Windows paths and registers two existing build-only diagnostics; both the literal scan and string-table consistency check pass.

Source-only cloud tests ran on macOS 26 ARM64: both bootstrap suites, audio-buffer release order/events, AudioUnit suspend/resume, the three-thread 100,000-buffer queue test and control-span tests passed. Ten changed host components compile with iOS SDK 26.5; the changed Metal backend also compiles for both macOS and iOS. The separate ios-shell job now compiles all 45 selected host/backend/front-end sources, links an ARM64 iOS executable, checks its Mach-O entry/platform and packages an unsigned game-free shell. No local game files were read or uploaded in CI.

The generic bootstrap was compiled with a Windows C compiler and passed both D2R/P5R suites: call ordering, main-thread/argument-area forwarding, argument ABI, no SDK execution for each of nine missing-entry cases, and P5R skipping D2R hooks. These use a fake SDK and do not replace running the actual game on Apple systems. The original iOS shell and generated build tables remain D2R-specific; the dedicated P5R shell excludes those feature sources and tables. Linking and packaging still do not validate actual game startup.

No game executables, assets, keys, generated shader content or install packages are added to the repository.

The supplied local P5R main contains 228 validated embedded controls: 10 vertex, 212 fragment and 6 compute, with 87 carrying 256-byte extra constants and no control-key collisions. Without AST optimization, all 228 diagnostic jobs generate SPIR-V and pass `spirv-val --target-env vulkan1.2`; enabling AST optimization throws exceptions in eight fragment shaders. All intermediate files stay local. These results do not validate GPU output or unknown resource facts.

Using SPIRV-Cross source commit `300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1`, all 228 files also convert to MSL 2.3 source with argument buffers, native texture buffers and padded fragment outputs. These sources have not been compiled into Apple Metal libraries; P5R texture/sampler/constant-buffer bindings remain unverified. They are not ready-to-use rendering assets.

The initial reproducible pipeline passed on all 228 local shaders and found the texture handles outside the previously supported separate-texture table. Follow-up SDK analysis identified the distinct combined-binding API table. The diagnostic decoder now reports the corresponding combined texture/sampler source, independently of resource type facts; unknown banks, unsupported packed-handle modes and resource arrays remain unresolved. Compute workgroup dimensions have since been checked against SDK metadata access and SPIR-V output. Buffer mappings are checked at the SDK command/state level, and compute memory use is audited from decoded instructions. Shader type/state facts, verified runtime shader packaging and actual GPU output still require work. Successful translation alone does not provide a usable rendering library.
