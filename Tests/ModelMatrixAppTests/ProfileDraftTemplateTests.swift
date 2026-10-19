import Testing
@testable import ModelMatrixApp

/// Picking a "Start from" template fills in the Profile ID. Picking another
/// template replaces an ID that a template filled in, but never one the user typed.
@Suite struct ProfileDraftTemplateTests {
    static func template(_ id: String, _ values: [String: String]) -> JSONRow {
        JSONRow(["id": id, "label": id, "values": values])
    }

    let ollama = template("ollama", ["RUNTIME": "ollama", "BASE_URL": "http://127.0.0.1:11434/v1"])
    let lmStudio = template("lm-studio", ["RUNTIME": "lm-studio", "LAUNCH_MODE": "external"])
    let gguf = template("llama-cpp-profile", ["RUNTIME": "llama.cpp", "PORT": "8080"])

    @Test func switchingTemplatesReplacesTheTemplateID() {
        var draft = ProfileDraft.new(template: ollama)
        #expect(draft.profileID == "ollama")
        draft.apply(template: lmStudio)
        #expect(draft.profileID == "lm-studio")
        #expect(draft.values["RUNTIME"] == "lm-studio")
    }

    @Test func exampleTemplatesDropTheProfileSuffix() {
        let draft = ProfileDraft.new(template: gguf)
        #expect(draft.profileID == "llama-cpp")
    }

    @Test func typedIDIsKeptWhenSwitchingTemplates() {
        var draft = ProfileDraft.new(template: ollama)
        draft.profileID = "my-model"
        draft.apply(template: lmStudio)
        #expect(draft.profileID == "my-model")
        #expect(draft.values["RUNTIME"] == "lm-studio")
    }

    @Test func editingAnExistingProfileNeverChangesItsID() {
        var draft = ProfileDraft.existing(JSONRow(["profile": "qwen", "format": "env", "values": ["RUNTIME": "ollama"]]))
        draft.apply(template: lmStudio)
        #expect(draft.profileID == "qwen")
    }
}
