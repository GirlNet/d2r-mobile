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

The locally completed package also enables **Probe SDK Initialization**, independently of the disabled game-launch button. It loads the signed Guest framework and runs only the six SDK startup entries, stopping before module initializers and `nnMain`. RomFS is not required for this initial probe. A GPU initialization attempt or unresolved import is recorded and parked before that operation. A 30-second deadline records a timeout and terminates the process if an entry has not returned. Do not interpret a stopped/blocked probe as verified game execution.

Each run creates a new `Documents/p5r-boot-probe-<UUID>/` folder containing `boot-report.json`, `runtime.log`, and isolated `save`/`temp` directories. It never reuses the normal save directory. The report includes host source fingerprint/package metadata where available, per-entry checkpoints and explicit false readiness/game/GPU markers. If the app exits early, retain both files; a `running` report means only that its last checkpoint was persisted, not that initialization completed. Close the app completely before another run. Reports and game-containing packages stay local.

The new output directory must be outside the repository. The builder compiles the loader, host gates, supported platform services, Metal backend and dedicated UIKit/controller front end, then performs a complete ARM64 iOS link. `DM_P5R_ONLY` removes D2R-only branches; D2R feature sources and generated tables are excluded. Unimplemented guest imports still fail explicitly.

Outputs include `P5RMobile-shell-unsigned.ipa`, `build-report.json`, compiler/linker logs and inspected Mach-O load commands. The executable must be an ARM64 iOS application with an entry point and no embedded game-module sections. The source-only CI job `ios-shell` runs the same builder and retains its outputs as the `p5r-ios-shell` artifact for seven days. The shell contains no game program, RomFS, generated shaders or saves.

## Add your local modules on Windows, Linux or macOS

First run the preparation and shader diagnostic tools described in [P5R_PORT.md](P5R_PORT.md). Module preparation must finish with `equivalence_passed`, and the shader diagnostic must complete successfully. Then run:

```sh
python3 dm/tools/p5r_pack.py /path/P5RMobile-shell-unsigned.ipa /path/port-preparation /path/shader-diagnostic /path/delivery/P5RMobile-experimental-unsigned.ipa
```

The preparation directory contains `port-preparation.json` and `rewritten/`; the diagnostic directory contains `diagnostic-report.json`, `reflection-plans/`, `spirv/` and `msl/`. Output must be new and outside the repository and both input trees.

The packager checks module hashes, segment/key-page bounds, distinct thread-key slots, absence of D2R private cuts/observations/parameters, and shader/report hashes. Shader and module sources must match. It writes all three modules (`main`, `sdk`, `subsdk0`) into `Frameworks/Guest.framework/Guest` using the existing portable Mach-O writer, adds loader metadata and retains shader assets under `p5r-diagnostics/`. Diagnostic assets are not promoted into runtime-ready shader libraries. ZIP paths, entry collisions and final CRCs are checked; existing output is preserved.

The adjacent `.report.json` records hashes and explicitly retains `runtime_ready=false`, `graphics_verified=false`, `device_verified=false` and `signed=false`. The UIKit launcher shows the graphics-pending state and does not enter guest code. A future verified runtime package also requires the user's own RomFS at `Documents/romfs/`; RomFS is not bundled by this tool. Save and temporary paths are isolated as `save-p5r` and `temp-p5r`.

The app and Guest framework require signing together before installation. This workflow does not install anything, acquire certificates, modify provisioning profiles or upload game-derived files. Keep the completed game-containing IPA and diagnostic reports local.
