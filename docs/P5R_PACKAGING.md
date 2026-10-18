# Experimental P5R iOS packaging

中文: [P5R_PACKAGING.zh-CN.md](P5R_PACKAGING.zh-CN.md)

This workflow links the complete P5R host and packages locally prepared game modules. The current result is **unsigned and experimental, with game launch disabled**: shader resources remain diagnostic and game startup has not been validated. Signing does not remove those limitations.

## Build the game-free host shell

On a Mac with Xcode's iOS SDK, from the repository root:

```sh
python3 dm/gfx/tools/dmsh_chain.py --header
python3 dm/ios/p5r/build_shell.py /absolute/path/out/p5r-shell
```

The game-free shell includes **Run GPU Self-Test**. After signing and installing it on an iPhone, this button runs synthetic resources without RomFS or a Guest framework. Results are saved as `Documents/p5r-gpu-selftest.json`, accessible through file sharing. Metal 3 and supported Metal 4 paths each run 48 cases; unsupported Metal 4 is reported separately. Passing does not verify P5R graphics or enable game launch. CI may expose only Metal 3 even with a newer SDK; compiling the Metal 4 path is not GPU execution proof.

The locally completed package enables **Probe Startup**, independently of the disabled game-launch button. It loads the signed Guest framework, runs SDK initialization, module constructors and argument setup, then enters `nnMain` under a 30-second probe deadline. Guest GPU initialization, unimplemented NVN operations, unresolved imports and unknown kernel operations stop at a recorded boundary before the operation. A deadline records a timeout and terminates the process if the probe has not already stopped. The SDK-only and module-only modes remain available through the probe API, stopping before constructors or `nnMain` respectively. This controlled startup mode does not enable game rendering or claim gameplay readiness.

Each run creates a new `Documents/p5r-boot-probe-<UUID>/` folder containing `boot-report.json`, `runtime.log`, and isolated `save`/`temp` directories. It never reuses the normal save directory. The report retains source/package metadata, SDK/module checkpoints and separate main-entry/main-return flags. `guest_gpu_work_submitted`, `runtime_ready` and `graphics_verified` remain false. `game_main_returned` records only that entry's return; it does not verify background work or graphics. Blocked, failed, timeout and interrupted running reports record incomplete execution. If the app exits early, retain both files. Close the app completely before another run. Reports and game-containing packages stay local.

The launcher requires a `Documents/romfs/` directory before starting this mode, without claiming its contents are complete, and enables filesystem operation logs. Keep the exact extracted resource paths/case; a separate local resource ZIP can be unpacked so that `romfs/` sits directly in Documents, not inside an extra archive-name folder. Mounting RomFS, opening files/directories and querying entry types add guest-path checkpoints; tracing preserves errno and the original operation's behavior. Missing resources and platform requirements must be resolved from the actual report, without substituting diagnostic shaders for verified game graphics.

The new output directory must be outside the repository. The builder compiles the loader, host gates, supported platform services, Metal backend and dedicated UIKit/controller front end, then performs a complete ARM64 iOS link. `DM_P5R_ONLY` removes D2R-only branches; D2R feature sources and generated tables are excluded. Unimplemented guest imports still fail explicitly.

Outputs include `P5RMobile-shell-unsigned.ipa`, `build-report.json`, compiler/linker logs and inspected Mach-O load commands. The executable must be an ARM64 iOS application with an entry point and no embedded game-module sections. The source-only CI job `ios-shell` runs the same builder and retains its outputs as the `p5r-ios-shell` artifact for seven days. The shell contains no game program, RomFS, generated shaders or saves.

## Add your local modules on Windows, Linux or macOS

First run the preparation and shader diagnostic tools described in [P5R_PORT.md](P5R_PORT.md). Module preparation must finish with `equivalence_passed`, and the shader diagnostic must complete successfully. Then run:

```sh
python3 dm/tools/p5r_pack.py /path/P5RMobile-shell-unsigned.ipa /path/port-preparation /path/shader-diagnostic /path/delivery/P5RMobile-experimental-unsigned.ipa
```

The preparation directory contains `port-preparation.json` and `rewritten/`; the diagnostic directory contains `diagnostic-report.json`, `reflection-plans/`, `spirv/` and `msl/`. Output must be new and outside the repository and both input trees.

The packager checks module hashes, segment/key-page bounds, distinct thread-key slots, absence of D2R private cuts/observations/parameters, and shader/report hashes. Shader and module sources must match. It writes all three modules (`main`, `sdk`, `subsdk0`) into `Frameworks/Guest.framework/Guest` using the existing portable Mach-O writer, adds loader metadata and retains shader assets under `p5r-diagnostics/`. Diagnostic assets are not promoted into runtime-ready shader libraries. ZIP paths, entry collisions and final CRCs are checked; existing output is preserved.

The adjacent `.report.json` records hashes and explicitly retains `runtime_ready=false`, `graphics_verified=false`, `device_verified=false` and `signed=false`. The UIKit launcher shows the graphics-pending state and keeps normal game launch disabled; its separate diagnostic button only runs the configured initialization stages. A future verified runtime package also requires the user's own RomFS at `Documents/romfs/`; RomFS is not bundled by this tool. Save and temporary paths are isolated as `save-p5r` and `temp-p5r`.

The app and Guest framework require signing together before installation. This workflow does not install anything, acquire certificates, modify provisioning profiles or upload game-derived files. Keep the completed game-containing IPA and diagnostic reports local.

Use **Probe Graphics Initialization** in the current launcher after importing local RomFS. The new probe permits backend object setup, then stops before returning to the guest or submitting game GPU work. A `stopped_after_gpu_initialization` result proves backend setup only, not game shaders, CPK integrity, rendering or playability. Send the new local boot report and runtime log after a device run. The application and Guest framework still require signing together; preserve the existing RomFS when updating.

The latest launcher uses **Probe Before Submission** to continue CPU resources and command recording after backend setup. Send the new boot report and runtime log after it reaches a submission boundary, unsupported operation or timeout. A setup-completed flag alone does not mean a frame was submitted or game graphics were verified. Existing local RomFS can be retained when updating the signed app/framework.

The dedicated shell defaults to Metal 3 so its production draw path matches cloud GPU comparisons. Pass `--metal-backend 4` to `dm/ios/p5r/build_shell.py` for the optional Metal 4 build. The selected backend is recorded in shell/build metadata and included in the source fingerprint; skipped Metal 4 comparisons are not runtime validation.

Locally compiled iOS diagnostic libraries can now be staged in the host's cache
layout. Use the shader extraction directory (not the module rewrite directory),
the completed native diagnostic directory and the chain printed by
`python dm/gfx/tools/dmsh_chain.py`:

```sh
python dm/tools/stage_p5r_shaders.py /path/shader-preparation /path/native-diagnostic /path/staged-shaders --chain <12-hex-chain>
```

This writes `dm/shader_map.tsv`, a conservative `dm/c1_full.tsv` and
`msl/b-<chain>/<control-key>_b.{metallib,metal,json}`. It verifies control/code/c1
provenance, native-library and MSL hashes, entry stages, slot coverage and compute
memory evidence. Every reflection retains diagnostic/unverified markers and the
loader continues to reject it. A failed run preserves an explicitly failed report;
it never overwrites a prior output. To include these files in an experimental IPA,
add `--shader-bundle /path/staged-shaders` to `p5r_pack.py`. The packager checks
the shell chain and diagnostic provenance, hashes copied assets, and keeps
`runtime_ready=false` and normal launch disabled. This completes cache layout and
transport only; translation defaults, actual game graphics and playability remain
unverified. All generated files stay local.
