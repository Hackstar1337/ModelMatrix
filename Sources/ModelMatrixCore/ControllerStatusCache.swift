import Foundation
import OSLog

public enum ControllerStatusCache {
    static let logger = Logger(subsystem: "io.github.hackstar1337.modelmatrix.core", category: "controller-status-cache")

    public static let cacheURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/io.github.hackstar1337.modelmatrix/controller-status.json")
    }()
}
