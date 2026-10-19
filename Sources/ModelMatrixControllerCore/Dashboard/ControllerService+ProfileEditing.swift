import Foundation
import ModelMatrixCore

/// Profile editing for the dashboard and the menu bar app's profile editor.
///
/// Profiles stay plain files in the profiles folder (`<name>.env` or
/// `<name>.json`), so hand-edited files, the CLI and the app keep working.
extension ControllerService {
    static let profileNamePattern = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"

    /// Preferred key order when writing `.env` files; remaining keys follow alphabetically.
    static let preferredKeyOrder = [
        "DISPLAY_NAME", "RUNTIME", "LAUNCH_MODE", "MODEL_PATH", "MODEL_FILE", "MODEL_DIR",
        "MODEL_ID", "MODEL_REPO", "SERVER_BIN", "START_COMMAND", "HOST", "PORT", "BASE_URL",
        "REQUEST_MODEL", "SERVER_MODEL_ID", "HEALTHCHECK_MODE", "HEALTHCHECK_URL", "CONTEXT_SIZE",
        "N_PARALLEL", "GPU_LAYERS", "BATCH_SIZE", "UBATCH_SIZE", "FLASH_ATTN", "CAPTURE_MODE",
        "RUNTIME_TAGS", "SYNC_TO_DROID",
    ]

    public static func isValidProfileName(_ name: String) -> Bool {
        name.range(of: profileNamePattern, options: .regularExpression) != nil
    }

    /// Existing file backing a profile, if any.
    func profileFile(named name: String) -> URL? {
        let directory = configuration.profilesDirectory
        for ext in ["env", "json"] {
            let candidate = directory.appendingPathComponent("\(name).\(ext)")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func profileDocument(_ name: String) throws -> [String: Any] {
        guard Self.isValidProfileName(name), let file = profileFile(named: name) else {
            throw ControllerError.profileNotFound(name)
        }
        let values = try profiles.parseValues(file: file)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let running = (try? statusPayload(selected: [name]).statuses.first?.running) ?? false
        return [
            "profile": name,
            "file": file.path,
            "format": file.pathExtension.lowercased(),
            "values": values,
            "text": text,
            "running": running,
        ]
    }

    /// Creates or updates a profile.
    ///
    /// - Parameters:
    ///   - name: new profile name (file name without extension).
    ///   - values: KEY -> value map; ignored when `text` is supplied.
    ///   - text: raw `.env` contents from the advanced editor.
    ///   - originalName: when renaming, the profile's previous name.
    ///   - createOnly: fail instead of overwriting an existing profile.
    @discardableResult
    public func saveProfile(
        name: String,
        values: [String: String]?,
        text: String? = nil,
        originalName: String? = nil,
        createOnly: Bool = false
    ) throws -> [String: Any] {
        try withMutationLock {
            guard Self.isValidProfileName(name) else {
                throw ControllerError.usage(
                    "profile name must use letters, numbers, '.', '_' or '-' (max 64)")
            }
            let directory = configuration.profilesDirectory
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let renaming = originalName.map { $0 != name } ?? false
            let existing = profileFile(named: name)
            if existing != nil, createOnly || renaming {
                throw ControllerError.profileConflict("a profile named \(name) already exists")
            }
            var original: URL?
            if let originalName, renaming {
                guard let file = profileFile(named: originalName) else {
                    throw ControllerError.profileNotFound(originalName)
                }
                if (try? statusPayload(selected: [originalName]).statuses.first?.running) == true {
                    throw ControllerError.profileConflict(
                        "stop \(originalName) before renaming it")
                }
                original = file
            }
            let format = (existing ?? original)?.pathExtension.lowercased() ?? "env"
            let resolvedValues: [String: String]
            let body: String
            if let text {
                let scratch = fileManager.temporaryDirectory
                    .appendingPathComponent("modelmatrix-profile-\(UUID().uuidString).env")
                try text.write(to: scratch, atomically: true, encoding: .utf8)
                defer { try? fileManager.removeItem(at: scratch) }
                resolvedValues = try profiles.parseValues(file: scratch)
                _ = try ControllerProfile(name: name, values: resolvedValues)
                body = text.hasSuffix("\n") ? text : text + "\n"
                let target = directory.appendingPathComponent("\(name).env")
                try write(body, to: target, replacing: format == "json" ? (existing ?? original) : nil)
            } else {
                var cleaned: [String: String] = [:]
                for (key, value) in values ?? [:] {
                    let trimmedKey = key.trimmingCharacters(in: .whitespaces)
                    guard ProfileRepository.isValidProfileKey(trimmedKey) else {
                        throw ControllerError.usage("invalid profile key: \(key)")
                    }
                    if value.contains("\0") { throw ControllerError.usage("invalid value for \(key)") }
                    cleaned[trimmedKey] = value
                }
                cleaned["PROFILE_NAME"] = nil
                _ = try ControllerProfile(name: name, values: cleaned)
                resolvedValues = cleaned
                if format == "json" {
                    let data = try JSONSerialization.data(
                        withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys])
                    body = String(decoding: data, as: UTF8.self) + "\n"
                    try write(body, to: directory.appendingPathComponent("\(name).json"), replacing: nil)
                } else {
                    body = Self.envText(for: cleaned, header: Self.existingHeader(existing ?? original))
                    try write(body, to: directory.appendingPathComponent("\(name).env"), replacing: nil)
                }
            }
            if let original, original.deletingPathExtension().lastPathComponent != name {
                try? fileManager.removeItem(at: original)
                try? fileManager.removeItem(at: pidFile(originalName ?? ""))
            }
            return ["profile": name, "values": resolvedValues, "saved": true]
        }
    }

    func write(_ body: String, to target: URL, replacing other: URL?) throws {
        try body.write(to: target, atomically: true, encoding: .utf8)
        if let other, other.path != target.path { try? fileManager.removeItem(at: other) }
    }

    /// Leading comment block of an existing `.env` file, kept on save.
    static func existingHeader(_ file: URL?) -> String {
        guard let file, file.pathExtension.lowercased() == "env",
            let text = try? String(contentsOf: file, encoding: .utf8)
        else { return "" }
        var header: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#") { header.append(line) } else { break }
        }
        return header.isEmpty ? "" : header.joined(separator: "\n") + "\n"
    }

    static func envText(for values: [String: String], header: String = "") -> String {
        let ordered =
            preferredKeyOrder.filter { values[$0] != nil }
            + values.keys.filter { !preferredKeyOrder.contains($0) }.sorted()
        var lines: [String] = []
        for key in ordered {
            lines.append("\(key)=\(envQuoted(values[key] ?? ""))")
        }
        return header + lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a value so `ProfileRepository.parseValue` reads it back exactly.
    static func envQuoted(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let plainSafe = value.range(of: "^[A-Za-z0-9_./:@%+,=-]+$", options: .regularExpression) != nil
        if plainSafe { return value }
        if !value.contains("'"), !value.contains("\n"), !value.contains("\t") {
            return "'\(value)'"
        }
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    public func deleteProfile(_ name: String) throws {
        try withMutationLock {
            guard Self.isValidProfileName(name), let file = profileFile(named: name) else {
                throw ControllerError.profileNotFound(name)
            }
            if (try? statusPayload(selected: [name]).statuses.first?.running) == true {
                try stop(name)
            }
            try fileManager.removeItem(at: file)
            try? fileManager.removeItem(at: pidFile(name))
            if let active = try? String(contentsOf: configuration.activeProfileFile, encoding: .utf8),
                active.trimmingCharacters(in: .whitespacesAndNewlines) == name
            {
                try? fileManager.removeItem(at: configuration.activeProfileFile)
            }
        }
    }

    @discardableResult
    public func duplicateProfile(_ name: String, as newName: String) throws -> [String: Any] {
        guard let file = profileFile(named: name) else { throw ControllerError.profileNotFound(name) }
        var values = try profiles.parseValues(file: file)
        values["DISPLAY_NAME"] = "\(values["DISPLAY_NAME"] ?? name) copy"
        values["PROFILE_NAME"] = nil
        return try saveProfile(name: newName, values: values, createOnly: true)
    }

    public static func runtimeList() -> [[String: Any]] {
        RuntimeCatalog.specEntries
            .filter { $0.0 != "unknown" }
            .map { ["id": $0.0, "label": $0.1, "tags": $0.2, "launch_mode": $0.3] }
    }

    /// Starter templates offered by "New profile".
    public func profileTemplates() -> [[String: Any]] {
        var templates: [[String: Any]] = [
            [
                "id": "ollama", "label": "Ollama model",
                "values": [
                    "DISPLAY_NAME": "Ollama model", "RUNTIME": "ollama",
                    "BASE_URL": "http://127.0.0.1:11434/v1", "REQUEST_MODEL": "llama3.2:3b",
                    "SERVER_MODEL_ID": "llama3.2:3b", "HEALTHCHECK_MODE": "openai-models",
                ],
            ],
            [
                "id": "lm-studio", "label": "LM Studio server",
                "values": [
                    "DISPLAY_NAME": "LM Studio", "RUNTIME": "lm-studio", "LAUNCH_MODE": "external",
                    "BASE_URL": "http://127.0.0.1:1234/v1", "REQUEST_MODEL": "local-model",
                    "HEALTHCHECK_MODE": "openai-models",
                ],
            ],
            [
                "id": "external", "label": "Any OpenAI-compatible endpoint",
                "values": [
                    "DISPLAY_NAME": "OpenAI-compatible endpoint", "RUNTIME": "external",
                    "LAUNCH_MODE": "external", "BASE_URL": "http://127.0.0.1:8000/v1",
                    "REQUEST_MODEL": "model", "HEALTHCHECK_MODE": "openai-models",
                ],
            ],
        ]
        let candidates = [
            configuration.profilesDirectory.appendingPathComponent("examples", isDirectory: true),
            configuration.root.appendingPathComponent("model-profiles/examples", isDirectory: true),
        ]
        var seen = Set<String>()
        for directory in candidates {
            guard
                let files = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where ["env", "json"].contains(file.pathExtension.lowercased()) {
                let id = file.deletingPathExtension().lastPathComponent
                guard !seen.contains(id), let values = try? profiles.parseValues(file: file) else {
                    continue
                }
                seen.insert(id)
                templates.append([
                    "id": id,
                    "label": values["DISPLAY_NAME"] ?? id,
                    "values": values,
                ])
            }
        }
        return templates
    }
}
