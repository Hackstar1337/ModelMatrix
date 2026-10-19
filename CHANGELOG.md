# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- **Hugging Face model check**: `modelmatrixctl check <owner/name>` (or a link, `owner/name:VERSION`, or search words) tells you, before anything is downloaded, the model's format (GGUF, MLX, MLC-LLM, original weights, AWQ/GPTQ/EXL2 and others), whether it is a chat model, its licence and login requirement, every version with its download size, quality and memory fit on this Mac, a recommended version and context length, and which engine it needs and whether that engine is installed. Formats ModelMatrix can't run point to ready-to-run versions of the same model. The check is read-only: it downloads no model and installs nothing. Also available as `GET /api/hf/check` and `GET /api/hf/search`.
- **Optimize** frees as much memory as possible: it unloads idle Ollama models, stops idle model servers and clears the macOS file cache (after the standard password dialog), then shows memory before and after. Choose **Maximum** or **Recommended** or tick items yourself; anything answering a request is left alone. Available from the web dashboard (header and This Mac card), the menu bar (sparkles icon) and `modelmatrixctl optimize`. It also lists the other apps using the most memory: tick the ones to close (or **Select all apps that can quit**), confirm the list, and they close the way they do with ⌘Q as part of the same run, with each reported as closed, still open or not allowed.

### Changed

- The menu bar icon is now the dot-matrix "M" from the app icon. The whole M lights up when a model is ready, the two outer columns light while one is starting, and the M dims when nothing is running.
- The dashboard's model profile form explains itself. **Launch mode** and **Health check** are now dropdowns that say what each choice does, including the runtime's default and whether ModelMatrix can launch that runtime by itself or needs a `START_COMMAND`. **Port** shows that it comes from Base URL when left empty. The **Capture mode** switch is greyed out, with the reason, for Ollama, for servers you run yourself, and when no port is set.

### Fixed

- Picking a different **Start from** template in the new-profile form (dashboard and menu bar) now replaces the Profile ID the previous template filled in, instead of keeping it. An ID you typed yourself is still kept.
- The menu bar now follows changes made from the web dashboard, `modelmatrixctl` or other clients within about three seconds. Before, a model started elsewhere while nothing was running could take up to ten minutes to appear.
- `Scripts/uninstall.sh` clears the app's cached preferences as well as the file, so a reinstall no longer picks up old values.
- Local installs are ad-hoc signed again. When the app was built in a synced folder such as `~/Documents`, Finder and File Provider attributes made signing fail silently and the app was left unsigned; the build and install scripts now clear them first.

## [1.0.0] - 2026-10-19

### Added

- First release of ModelMatrix: a macOS menu bar app and local controller for switching between local LLM runtimes (llama.cpp, MLX, Ollama, vLLM, SGLang, TGI, and more) with probe-based readiness, benchmarks, remote GPU gateways, and Raycast / SwiftBar integrations.
