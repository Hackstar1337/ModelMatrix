import Foundation
import ModelMatrixCore

extension MatrixStore {
    /// Live folder if the controller has reported one; otherwise the embedded
    /// controller's Application Support path so first-run Open Profiles Folder
    /// is not a no-op while status is still coming up.
    var profilesDirectoryToReveal: URL {
        if let trimmed = profilesDirectory.nonEmptyTrimmed {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ModelMatrix/Controller/model-profiles",
                isDirectory: true
            )
    }

    var controllerRootToReveal: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ModelMatrix/Controller",
                isDirectory: true
            )
    }

    var exampleProfilesDirectoryToReveal: URL {
        profilesDirectoryToReveal.appendingPathComponent("examples", isDirectory: true)
    }
}
