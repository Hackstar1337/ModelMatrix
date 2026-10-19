# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- **Models from Hugging Face**, from the dashboard (**Models & Servers → Add from Hugging Face**), the menu bar (download arrow in the header) and the terminal (`modelmatrixctl check`, `pull`, `downloads`, `models`, `engines`, `engine`, `hf-settings`, `hf-token`). Type a model name, link or search words and ModelMatrix first checks it without downloading anything: format (GGUF, MLX, MLC-LLM, original weights, AWQ/GPTQ/EXL2 and others), chat or not, licence and login requirement, every version with its size, quality and memory fit on the chosen machine, a recommended version and context length, and the engine it needs. Formats it can't run point to ready-to-run versions of the same model. Downloads are resumable across network drops, sleep and restarts, use several connections per file, are checked against Hugging Face's SHA-256, reuse files you already have, and can be paused, resumed or cancelled. When a download finishes, ModelMatrix creates the profile, starts it and sends a test message; failures show the reason and a suggested fix. Works on Apple Silicon and Intel Macs and on remote Linux hosts, where models download straight onto the host.
- **Engine installs only with your approval**: when llama.cpp, mlx-lm or Ollama is missing, ModelMatrix shows the exact plan (Homebrew command, or the official release with its SHA-256, location, size and how to remove it) and installs only after you approve. Approvals are single-use and expire after 10 minutes. Engines already installed are found automatically, and ModelMatrix only updates or removes engines it installed itself.
- Hugging Face settings: models folder, mirror address, connections per file, speed limit, start after download, keep the Mac awake, custom engine paths, and a Hugging Face token for gated models (stored in the Keychain and sent only to Hugging Face). Notifications in the menu bar app when a model is ready or needs attention.
- **Optimize** frees as much memory as possible: it unloads idle Ollama models, stops idle model servers and clears the macOS file cache (after the standard password dialog), then shows memory before and after. Choose **Maximum** or **Recommended** or tick items yourself; anything answering a request is left alone. Available from the web dashboard (header and This Mac card), the menu bar (sparkles icon) and `modelmatrixctl optimize`. It also lists the other apps using the most memory: tick the ones to close (or **Select all apps that can quit**), confirm the list, and they close the way they do with ⌘Q as part of the same run, with each reported as closed, still open or not allowed.

### Changed

- The menu bar icon is now the dot-matrix "M" from the app icon. The whole M lights up when a model is ready, the two outer columns light while one is starting, and the M dims when nothing is running.
- The dashboard's model profile form explains itself. **Launch mode** and **Health check** are now dropdowns that say what each choice does, including the runtime's default and whether ModelMatrix can launch that runtime by itself or needs a `START_COMMAND`. **Port** shows that it comes from Base URL when left empty. The **Capture mode** switch is greyed out, with the reason, for Ollama, for servers you run yourself, and when no port is set.

### Fixed
- Hugging Face quality and estimated memory-fit warnings are now **suggestions, not download blockers**. Dashboard and menu-bar users can select a supported version and confirm **Download anyway**; the CLI can explicitly name a version. Low-quality versions that fit are no longer incorrectly labelled “too big”. Warnings remain attached to the download, and login/access, unsupported-format and disk-space checks remain enforced, including on managed Linux hosts.
- Profiles using current llama.cpp builds start again. The launcher reads the installed `llama-server`'s own option list and adapts options that newer versions renamed or re-typed (for example `--reasoning`, `--flash-attn` and memory-mapping options), and reports a model server that exits during startup at once instead of waiting for the timeout.
- The usage relay can route a request to a profile whose server knows the model under a different name (as mlx-lm does), by replacing the `model` field with the name that server expects.
- Hugging Face checks measure free space on the disk holding the configured models folder and use the same safety margin as downloads. If the disk fills during a multi-connection download, the real error is shown instead of leaving the job stuck; downloading resumes when space becomes available.
- Parameter counts use the correct unit at the million/billion boundary. Engine install summaries include the version and accurately label official builds, private MLX environments and install actions.

- Picking a different **Start from** template in the new-profile form (dashboard and menu bar) now replaces the Profile ID the previous template filled in, instead of keeping it. An ID you typed yourself is still kept.
- The menu bar now follows changes made from the web dashboard, `modelmatrixctl` or other clients within about three seconds. Before, a model started elsewhere while nothing was running could take up to ten minutes to appear.
- `Scripts/uninstall.sh` clears the app's cached preferences as well as the file, so a reinstall no longer picks up old values.
- Local installs are ad-hoc signed again. When the app was built in a synced folder such as `~/Documents`, Finder and File Provider attributes made signing fail silently and the app was left unsigned; the build and install scripts now clear them first.

## [1.0.0] - 2026-10-19

### Added

- First release of ModelMatrix: a macOS menu bar app and local controller for switching between local LLM runtimes (llama.cpp, MLX, Ollama, vLLM, SGLang, TGI, and more) with probe-based readiness, benchmarks, remote GPU gateways, and Raycast / SwiftBar integrations.
