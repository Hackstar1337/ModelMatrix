# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- The menu bar icon is now the dot-matrix "M" from the app icon. The whole M lights up when a model is ready, the two outer columns light while one is starting, and the M dims when nothing is running.

### Fixed

- The menu bar now follows changes made from the web dashboard, `modelmatrixctl` or other clients within about three seconds. Before, a model started elsewhere while nothing was running could take up to ten minutes to appear.
- `Scripts/uninstall.sh` clears the app's cached preferences as well as the file, so a reinstall no longer picks up old values.

## [1.0.0] - 2026-10-19

### Added

- First release of ModelMatrix: a macOS menu bar app and local controller for switching between local LLM runtimes (llama.cpp, MLX, Ollama, vLLM, SGLang, TGI, and more) with probe-based readiness, benchmarks, remote GPU gateways, and Raycast / SwiftBar integrations.
