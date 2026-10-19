import Foundation

extension HFMachine {
  /// A remote host, from its agent's `GET /api/hf/host` answer.
  static func remote(_ facts: [String: Any], host: HFRemoteHost) throws -> HFMachine {
    func number(_ key: String) -> Int64? { (facts[key] as? NSNumber)?.int64Value }
    func text(_ key: String) -> String? { (facts[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } }
    guard let memory = number("memory_bytes"), memory > 0, let budget = number("budget_bytes"), budget > 0 else {
      throw HFError.badResponse("\(host.name) didn't report its memory.")
    }
    let architecture: String
    switch (text("architecture") ?? "").lowercased() {
    case "arm64", "aarch64": architecture = "arm64"
    case "x86_64", "amd64", "x64": architecture = "x86_64"
    case let other: architecture = other.isEmpty ? "unknown" : other
    }
    var machine = HFMachine(
      kind: text("kind") ?? "linux", os: text("os") ?? "Linux", architecture: architecture, appleSilicon: false,
      chip: text("chip") ?? architecture, memoryBytes: memory, budgetBytes: min(budget, memory * 4),
      budgetSource: text("budget_source") ?? "cpu", accelerator: text("accelerator") ?? "cpu",
      modelsFolder: text("models_folder") ?? "~/ModelMatrix/Models", freeDiskBytes: number("free_disk_bytes"))
    machine.host = host.id
    machine.hostName = host.name
    machine.gpu = text("gpu")
    machine.cudaVersion = text("cuda_version")
    machine.vulkan = facts["vulkan"] as? Bool
    machine.rocm = facts["rocm"] as? Bool
    machine.glibc = text("glibc")
    machine.availableMemoryBytes = number("available_memory_bytes")
    machine.enginesFolder = text("engines_folder")
    return machine
  }
}

/// The official llama.cpp build that suits a Linux host.
struct HFLinuxBuild: Sendable, Equatable {
  /// Release file name part, e.g. "ubuntu-cuda-12.8-x64".
  var platform: String
  /// Also needs the matching CUDA runtime archive (cudart-...).
  var runtime: Bool
  /// Plain-English name, e.g. "Linux x64, NVIDIA CUDA 12.8".
  var label: String
  var notes: [String] = []

  /// The glibc version the official Ubuntu builds are made with.
  static let builtWithGlibc = (2, 35)

  static func choose(_ machine: HFMachine) -> HFLinuxBuild? {
    let arch: String
    switch machine.architecture {
    case "x86_64": arch = "x64"
    case "arm64": arch = "arm64"
    case "s390x": return HFLinuxBuild(platform: "ubuntu-s390x", runtime: false, label: "Linux s390x, processor only")
    default: return nil
    }
    let cuda = version(machine.cudaVersion)
    let vulkan = machine.vulkan == true
    var build: HFLinuxBuild
    switch machine.accelerator {
    case "cuda" where cuda.map { $0 >= (13, 0) } == true:
      build = HFLinuxBuild(platform: "ubuntu-cuda-13.4-\(arch)", runtime: true, label: "Linux \(arch), NVIDIA CUDA 13")
    case "cuda" where arch == "x64" && cuda.map { $0 >= (12, 8) } == true:
      build = HFLinuxBuild(platform: "ubuntu-cuda-12.8-x64", runtime: true, label: "Linux x64, NVIDIA CUDA 12.8")
    case "cuda":
      let needed = arch == "x64" ? "12.8" : "13"
      let driver = machine.cudaVersion.map { " (it supports CUDA \($0))" } ?? ""
      build = vulkan
        ? HFLinuxBuild(platform: "ubuntu-vulkan-\(arch)", runtime: false, label: "Linux \(arch), GPU through Vulkan")
        : HFLinuxBuild(platform: "ubuntu-\(arch)", runtime: false, label: "Linux \(arch), processor only")
      build.notes.append(
        "The NVIDIA driver is too old for the CUDA builds\(driver). Update it to CUDA \(needed) or newer for the fastest GPU build, then update llama.cpp in ModelMatrix.")
    case "amd" where vulkan:
      build = HFLinuxBuild(platform: "ubuntu-vulkan-\(arch)", runtime: false, label: "Linux \(arch), AMD GPU through Vulkan")
    case "amd":
      build = HFLinuxBuild(platform: "ubuntu-\(arch)", runtime: false, label: "Linux \(arch), processor only")
      build.notes.append(
        "To use the AMD GPU, install its Vulkan driver (on Ubuntu: sudo apt install mesa-vulkan-drivers libvulkan1), then update llama.cpp in ModelMatrix.")
    default:
      build = HFLinuxBuild(platform: "ubuntu-\(arch)", runtime: false, label: "Linux \(arch), processor only")
    }
    if !build.usesGPU, machine.accelerator != "cpu" {
      build.notes.append("With this build models run on the processor, so they are slower than on a GPU.")
    }
    if let glibc = version(machine.glibc), glibc < builtWithGlibc {
      build.notes.append(
        "This host's C library (glibc \(machine.glibc ?? "")) is older than the one the official builds need (2.35). If the build doesn't run here, the install stops and nothing changes.")
    } else if machine.glibc == nil {
      build.notes.append(
        "This host doesn't report a glibc version (for example Alpine Linux). If the official build doesn't run here, the install stops and nothing changes.")
    }
    return build
  }

  var usesGPU: Bool { platform.contains("cuda") || platform.contains("vulkan") }

  /// "12.8" -> (12, 8).
  static func version(_ text: String?) -> (Int, Int)? {
    guard let text else { return nil }
    let parts = text.split(separator: ".").compactMap { Int($0) }
    guard let major = parts.first else { return nil }
    return (major, parts.count > 1 ? parts[1] : 0)
  }
}

/// Engines on a remote host, in the same shape as this Mac's.
enum HFRemoteEngines {
  static func statuses(_ list: [[String: Any]], machine: HFMachine) -> [HFEngineStatus] {
    let hostName = machine.hostName ?? "the host"
    let folder = machine.enginesFolder ?? "~/ModelMatrix/Engines"
    func entry(_ id: String) -> [String: Any] { list.first { $0["id"] as? String == id } ?? [:] }
    func text(_ item: [String: Any], _ key: String) -> String? {
      (item[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
    }

    let llama = entry("llama.cpp")
    let llamaInstalled = llama["installed"] as? Bool ?? false
    let managed = llama["managed"] as? Bool ?? false
    let build = HFLinuxBuild.choose(machine)
    var llamaStatus = HFEngineStatus(
      id: .llamaCpp, name: HFEngineID.llamaCpp.displayName, applicable: true, installed: llamaInstalled,
      path: text(llama, "path"), version: text(llama, "version"), installedBy: text(llama, "installed_by"),
      note: text(llama, "note"))
    if let build {
      llamaStatus.install = HFInstallOption(
        method: "official",
        summary: "ModelMatrix installs the official llama.cpp build for this host (\(build.label)) from GitHub, checked against its SHA-256.",
        command: nil, source: "https://github.com/ggml-org/llama.cpp/releases",
        location: "\(folder)/llama.cpp on \(hostName)",
        removal: "modelmatrixctl engine uninstall llama.cpp --host \(hostName)")
    } else if !llamaInstalled {
      llamaStatus.note = llamaStatus.note
        ?? "There is no official llama.cpp build for \(machine.architecture) Linux. Build llama-server yourself and put it on the PATH."
    }
    llamaStatus.managed = managed
    var actions: [String] = []
    if !llamaInstalled && build != nil { actions.append(HFEngineAction.install.rawValue) }
    if managed {
      if build != nil { actions.append(HFEngineAction.update.rawValue) }
      actions.append(HFEngineAction.uninstall.rawValue)
    }
    llamaStatus.actions = actions

    let mlx = HFEngineStatus(
      id: .mlxLM, name: HFEngineID.mlxLM.displayName, applicable: false, installed: false,
      note: "MLX runs only on Apple Silicon Macs.", managed: false, actions: [])

    let ollama = entry("ollama")
    let ollamaInstalled = ollama["installed"] as? Bool ?? false
    var ollamaStatus = HFEngineStatus(
      id: .ollama, name: HFEngineID.ollama.displayName, applicable: true, installed: ollamaInstalled,
      path: text(ollama, "path"), version: text(ollama, "version"), installedBy: text(ollama, "installed_by"),
      running: ollama["running"] as? Bool, note: text(ollama, "note"), managed: false, actions: [])
    if !ollamaInstalled {
      ollamaStatus.install = HFInstallOption(
        method: "manual",
        summary: "Ollama's Linux installer sets Ollama up as a system service, so it needs an administrator password (sudo). Run it on \(hostName) yourself, then check again.",
        command: "curl -fsSL https://ollama.com/install.sh | sh", source: "https://ollama.com/download/linux",
        location: "/usr/local on \(hostName) (for all users)",
        removal: "the uninstall steps at https://github.com/ollama/ollama/blob/main/docs/linux.md")
    }
    return [llamaStatus, mlx, ollamaStatus]
  }
}
