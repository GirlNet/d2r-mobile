# P5R port preparation

中文: [P5R_PORT.zh-CN.md](P5R_PORT.zh-CN.md)

Status: **experimental runtime adaptation in progress; P5R does not yet run on iOS through this project.** The user-specified target is iPhone 18 Pro on iOS 27, without device verification. Module preparation is complete and separation of D2R startup, input and save logic has begun; graphics, video, touch controls and real game startup remain unfinished.

Preset-cache coverage now includes bounded local CPK/@UTF reading and CRILAYLA decoding. Pass repeated `--cpk` arguments to `prepare_p5r_shaders.py` to include GFDNX `.GSC` caches alongside embedded shaders. Each selected entry records stored/decoded hashes and shader origins; identical controls are deduplicated and conflicting keys fail. A local inventory found 30,646 unique shaders across the executable and nine preset caches. This expands coverage, without establishing translation, resource format or gameplay correctness. Only synthetic archives enter source control and CI.

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
- Exit-request handling sections use an optional host takeover with a mutex-protected process-wide nesting counter. They do not dereference Horizon service objects after host oe initialization. Native environment tests cover paired/nested calls and concurrent entry/leave; Horizon exit-request delivery is not implemented by this counter.
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

Continue implementation through source audits, synthetic CPU/GPU tests and
cloud iOS builds without requesting a device installation for each interface.
The next report on 2026-10-17 records successful Darwin cache maintenance, then
stops at an unhandled service connection (`SVC 0x1f`); the syscall number alone
does not identify the service. Related coverage adds older BSD socket overloads,
offline account-context lifetimes, a host notification event for the stable
default audio device, and missing host controller/touch overloads. Unknown IPC
is not treated as successful. `nvnQueueWaitSync` schedules a Metal shared-event
GPU dependency without blocking the submitting CPU and rejects unfenced,
cross-device, finalized and future fences. A synthetic two-queue copy checks
dependency ordering. Game output and playable flows still require final device
acceptance; synthetic cloud tests cannot establish those results.

The original-instruction texture audit also covers TEX/TEXS/TLD/TLDS and
supported query/derivative families. It matches shapes within the same shader
and immediate handle, retaining 1D/buffer ambiguity, bank mismatches, conflicts,
unknown and unsupported instructions. All 571 two-dimensional texture
declarations in the 228 embedded programs have matching original shape bits.
This does not validate bound objects, sampling formats, draw state or complete
external-shader coverage, and does not promote diagnostic reflection to ready.
New diagnostic reports record these constraints independently.

The next device log on 2026-10-17 passed the linear render-target size check,
then faulted on the `CTR_EL0` read in `nn::os::FlushDataCache`. Optional forced
symbol adapters now forward this API to Darwin's `sys_dcache_flush`, and map
the compiler ABI `__clear_cache(begin,end)` to
`sys_icache_invalidate(begin,end-begin)`. These adapters cover relocated module
references; they do not rewrite internal SDK direct branches or enable JIT.
Synthetic tests cover range forwarding, unaligned and empty ranges, and loader
takeover of existing SDK definitions. Complete startup, game GPU output and
playable flows still require device validation after this fix.

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

The startup probe can now use all four `nn::fs::ReadFile` overloads with the same host file handle. The optional counted overload with `ReadOption` previously fell back to the SDK and dereferenced a host descriptor as a `FileAccessor*`. Verified option value 0 is supported; other options stop the diagnostic explicitly. Exact reads preserve the SDK short-read result `0x177a02`. Native regression checks cover real file data, offsets, EOF, output preservation, invalid handles and option rejection. Successful counted option reads add a probe checkpoint. This does not establish complete resource integrity on the phone or game graphics readiness.

Fast-clear registration now stores actual per-device host metadata for float, signed/unsigned integer color and depth. A guest can require registration success during initialization, so merely reporting unavailable is insufficient. The host table holds 64 color keys (argument kind, format, raw bits) and 16 depth values, reuses exact duplicates, rejects invalid/unsupported color formats and non-finite or out-of-range depth, and preserves existing entries on capacity exhaustion. Mutex protection covers concurrent registration, reinitialization and finalization. These are host software limits, not Tegra compression hardware claims; registration creates no GPU work and existing Metal clear commands retain their own payloads. Eleven additional P5R procedure names receive static counting thunks that retain named unimplemented-operation stops, rather than null addresses. Their ABI and behavior are not implemented. The original 523 name indices are preserved. Bootstrap regression uses the real procedure lookup and thunks without issuing GPU work; the startup probe still stops before backend GPU initialization.

The launcher now exposes a separate graphics-initialization probe. This fourth mode runs nnMain, grants one thread permission to initialize Metal objects and compile the auxiliary deswizzle pipeline, and parks that thread before returning to the guest. Other initialization callers wait for the process to restart rather than using a partially initialized device. It skips the optional GPU-submitting UDC self-test even when requested. Success records `stopped_after_gpu_initialization`, backend/device names and `gpu_initialization_completed=true`; guest-submission, runtime-ready and graphics-verified markers remain false. Queue submission and backend begin/commit paths retain explicit probe stops, as do unimplemented APIs. Legacy startup probes still stop before backend setup. A 30-second deadline and first-terminal-state preservation apply to all modes. Native regression checks cover exclusive ownership, wrong-owner completion, failure, timeout and submission stops. A source-only Metal 3 CI probe runs the actual backend initializer; Metal 4 device setup still requires the target iPhone. The Metal 3 backend retains its existing per-encoder resource declarations if residency sets are unavailable (including virtual runner devices); the Metal 4 path still requires a residency set and reports its creation error.

The fifth probe mode continues CPU resource initialization and NVN command recording after Metal setup. Initialization waiters are released only after the owning thread has recorded completion; errors, timeouts and wrong-owner completions remain terminal. All 19 explicit Metal command/queue commits in the production NVN backend now pass a shared pre-evaluation probe guard, including upload/readback/clear/present paths. Residency-set metadata commits remain separate. Existing high-level NVN submit/backend begin/commit guards still stop before replay. Memory-pool, queue and shader-registration metadata are checkpointed without exporting guest code. The launcher labels this mode **Probe Before Submission**. Runtime/graphics readiness stays false; diagnostic shader reflection remains rejected. Source-only tests include successful owner/waiter release, terminal-state preservation and an actual Metal 3 backend drain whose command-buffer commit is blocked.

Buffer objects now retain a bounded view of an existing host memory pool: device-preserving defaults, storage/query accessors, pointer-ABI pool lookup, initialization/finalization, mapping/address lookup and stable per-lifetime IDs. Invalid or overflowing ranges and unsupported virtual/physical pools fail without changing a prior object. CPU-inaccessible pools cannot be mapped. Buffers do not own pool storage or submit GPU work; mapped flush/invalidate use existing shared-memory coherence and do not wait for GPU completion. The pre-submit probe remains active.

Memory-pool and builder accessors return the actual retained flags, size, device and storage pointer. Builder defaults preserve the selected device. The storage getter uses pointer return ABI; pool mapping respects CPU-no-access and excludes virtual/physical pools. Shared-memory flush/invalidate validates the range and does not submit GPU work or claim completion. The native pre-submit test now registers a real Metal-backed pool, checks these queries, then parks at the existing drain submission gate.

The startup API batch adds 108 interfaces across queue/window builders, descriptor pools, texture metadata/views, samplers, render-state queries, optional debug labels and six command-recording adapters. Native tests call every new static thunk and validate independent values, pointer returns, narrow boolean output guards and command payloads without GPU submission. audit_p5r_api.py checks registered implementations and direct batch-call coverage; its counts describe source coverage, not game compatibility. 347 of 534 registered interfaces now have host implementations; 187 retain explicit named stops, including advanced rendering and unverified newer APIs. Texture-pool and callback-data pointer-return declarations were corrected. Normal game launch and unverified reflection remain disabled.

Known-ABI unimplemented void recording calls can now capture argument bits only in an active pre-submit probe after Metal setup completes. These 66 interfaces do not produce executable GPU commands and are counted separately from host implementations. Other modes and inactive use reject them; submission gates remain active. The report aggregates bounded per-interface counts and last argument bits, marks the stream unverified, and preserves the first terminal outcome. Two multisample setters retain CPU metadata under this same diagnostic gate. The host storage-class query uses the generic uncompressed class token 0x100 (host kind policy 0), not Tegra compression equivalence. Source counts are now 351 host implementations, 66 diagnostic-only interfaces and 117 named unimplemented interfaces out of 534. The original binary static call-pattern audit and instruction-level encoding/boolean probes stay local; they do not validate game GPU output.


## Sampler startup compatibility (2026-10-17)

The latest source-matched iPhone report reached `nvnSamplerBuilderSetReductionFilter` after Metal 4 setup and three diagnostic-only commands. No guest GPU submission occurred. Twelve related sampler interfaces now preserve/query reduction, LOD snap and raw integer border words, assign lifetime debug IDs and support builder-based pool registration. Original local SDK builder functions were executed for 270 cases: reduction uses the low four bits, LOD snap retains raw float bits, and border getters return the same four words across numeric types. These checks do not verify sampler descriptor encoding or game rendering.

Metal sampler mapping now forwards LOD bias and average/minimum/maximum reduction on Apple10 devices with OS 26 or newer. See [Apple feature requirements](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf) and [reduction filter restrictions](https://developer.apple.com/documentation/metal/mtlsamplerdescriptor/reductionmode). Strict P5R rendering rejects unsupported hardware, nonzero LOD snap and reduction filter combinations Metal ignores. The synthetic GPU check distinguishes unavailable hardware from executed output comparisons. CPU object layouts remain within NVN reserved sizes. Build fingerprints now include local headers and inline files as well as compilation units.

This remains a pre-submit diagnostic build. Game shader resource/render-state facts, command replay compatibility and actual gameplay remain unverified; the launch readiness gate stays false.


## Texture sampling state (2026-10-17)

The source-matched sampler-batch phone report passes the previous sampler stop and reaches `nvnTextureViewSetSwizzle`, with no guest GPU submission. Ten related builder/object/view interfaces now retain swizzle and depth/stencil sampling selection. Original local SDK functions passed 2,630 execution cases, including all 1,296 valid swizzles for each of builders and views. Builder enum words are preserved; view swizzles retain bytes, view aspect retains two bits, and unset view getters still write zero defaults. Native tests use real typed APIs and guard the reserved object sizes.

Sampled Metal descriptors now compose format channel mapping with either the builder swizzle or an explicit overriding view. Raw storage and render attachments retain physical order. Combined depth/stencil formats use an X32 stencil view when requested. Views retain selected mip/layer/type and registration snapshots; cache invalidation follows descriptor replacement and base serial changes. Unsupported sampling state or failed view creation is an explicit failure. A synthetic test exercises the production registration/view/cache path with 1,296 GPU channel combinations, inheritance/override, mip/layer selection, no-alpha format composition, depth/stencil reads and output guards. This test is separate from actual game rendering.


## Independent linear render-target storage flag (2026-10-17)

The texture-state phone package continues beyond the previous missing API and then traps in the original engine's `SetupSurfaceInfoMemoryInside` assertion, `ctx.memorySize <= localmemsetupinfo.memorySize`; the preserved local-memory allocation register is 1,024 bytes. The JSON report is a pre-crash `running` snapshot; the runtime log records SIGTRAP. The exact texture descriptor was not captured.

A related storage bug is reproduced independently: `LINEAR_RENDER_TARGET` (0x40) alone selects linear storage in the original SDK, whereas the host previously required `LINEAR` (0x10). A synthetic 16x16 RGBA8 texture with a 128-byte stride and flags 0x44 returns 1,024 bytes on the old host and 2,048 bytes on the SDK. The original engine row-size helper, executed with a synthetic 128-byte DeviceGetInteger contract, also computes 2,048 bytes. Across 360 original SDK cases, linear/render-target flag combinations retain explicit stride times height with 32/128-byte alignment. These are synthetic inputs, not a captured phone descriptor.

Storage layout, mip-offset classification and block-linear conversion rejection now share the 0x50 flag test. A portable 1,322-check regression catches the old implementation and preserves normal tiled layout; typed API checks cover builder queries and initialized texture properties. Storage-size probe checkpoints now record target, format, dimensions, flags, levels, stride, size and alignment to make later assertions diagnosable. No guest assertion is patched out and guest GPU submission stays blocked.
