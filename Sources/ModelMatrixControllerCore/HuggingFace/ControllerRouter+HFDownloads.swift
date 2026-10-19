import Foundation

/// Downloads, settings and token:
///
///     GET    /api/hf/downloads                 list
///     POST   /api/hf/downloads                 {"name", "version"?, "engine"?, "context"?, "start_after"?}
///     GET    /api/hf/downloads/<id>            one download
///     POST   /api/hf/downloads/<id>/pause
///     POST   /api/hf/downloads/<id>/resume
///     POST   /api/hf/downloads/<id>/cancel     {"delete_files"?: bool}
///     POST   /api/hf/downloads/<id>/start      create the profile if needed, start and test the model
///     DELETE /api/hf/downloads/<id>            remove a finished entry from the list
///     GET    /api/hf/models                    downloaded models with disk usage and profile state
///     POST   /api/hf/models/delete             {"id", "delete_files"?: bool} delete the profile (and files)
///
/// Every download and model route takes `host` (query, or body for POST) to
/// act on a remote host; `?host=all` lists this Mac and every host. Ids
/// from a host also work without naming the host.
///
///     GET    /api/hf/settings
///     PUT    /api/hf/settings                  partial update
///     POST   /api/hf/token                     {"token"} (checked with Hugging Face, kept in the Keychain)
///     DELETE /api/hf/token
extension ControllerRouter {
  var huggingFaceDownloadRoutes: [RouteKey: Route] {
    [
      RouteKey(method: "GET", path: "/api/hf/downloads"): { [self] request in
        try hfAction {
          let hostQuery = Self.formQuery(request.target)["host"]
          var list: [HFDownloadJob]
          var unreachable: [String]?
          if hostQuery?.lowercased() == "all" {
            (list, unreachable) = hub.allDownloads()
          } else if let host = try hub.remoteHost(hostQuery) {
            list = try hub.remoteDownloads(host)
          } else {
            list = hub.downloads.list()
          }
          if wantsText(request) {
            let missing = (unreachable ?? []).map { "\($0) couldn't be reached, so its downloads aren't listed.\n" }
            return hfText(HFDownloadText.render(list) + missing.joined())
          }
          return try hfJSON(HFDownloadList(downloads: list, unreachable: unreachable))
        }
      },
      RouteKey(method: "POST", path: "/api/hf/downloads"): { [self] request in
        try hfAction {
          let started = try hub.startDownload(HFHub.DownloadRequest(json: try requestObject(request)))
          return try hfDownload(started.job, request, existing: started.existing, status: started.existing ? 200 : 202)
        }
      },
      RouteKey(method: "GET", path: "/api/hf/models"): { [self] request in
        try hfAction {
          let hostQuery = Self.formQuery(request.target)["host"]
          var models: [HFDownloadedModel] = []
          var untracked: [HFUntrackedFolder] = []
          var unreachable: [String]?
          if let host = hostQuery?.lowercased() == "all" ? nil : try hub.remoteHost(hostQuery) {
            models = try hub.remoteDownloads(host).filter { $0.state == .completed }.map(HFHub.remoteModel)
          } else {
            (models, untracked) = hub.profiles.downloadedModels()
            if hostQuery?.lowercased() == "all" {
              let all = hub.allDownloads()
              models += all.downloads.filter { $0.host != nil && $0.state == .completed }.map(HFHub.remoteModel)
              unreachable = all.unreachable
            }
          }
          if wantsText(request) {
            let missing = (unreachable ?? []).map { "\($0) couldn't be reached, so its models aren't listed.\n" }
            return hfText(HFProfileText.render(models, untracked: untracked) + missing.joined())
          }
          return try hfJSON(HFDownloadedModelList(models: models, untracked: untracked, unreachable: unreachable))
        }
      },
      RouteKey(method: "POST", path: "/api/hf/models/delete"): { [self] request in
        try hfAction {
          let body = try requestObject(request)
          guard let id = body["id"] as? String, Self.validDownloadID(id) else {
            throw HFError.invalidSetting("Send the model's download id as {\"id\": \"...\"}.")
          }
          let deleteFiles = body["delete_files"] as? Bool ?? false
          if let host = try hub.downloadHost(id, hint: body["host"] as? String) {
            let result = try hub.remoteDelete(id, deleteFiles: deleteFiles, host: host)
            let freed = deleteFiles && !result.keptInOllama ? result.job.map { HFHub.remoteModel($0).bytesOnDisk } ?? 0 : 0
            var answer: [String: Any] = [
              "removed": id, "files_deleted": deleteFiles, "freed_bytes": freed, "host": host.name,
              "kept_in_ollama": result.keptInOllama,
            ]
            answer["profile_deleted"] = result.job?.profile ?? NSNull()
            return try json(answer)
          }
          let result = try hub.profiles.delete(id, deleteFiles: deleteFiles)
          var answer: [String: Any] = ["removed": id, "files_deleted": deleteFiles, "freed_bytes": result.freedBytes]
          answer["profile_deleted"] = result.profile ?? NSNull()
          answer["kept_in_ollama"] = result.keptInOllama
          return try json(answer)
        }
      },
      RouteKey(method: "GET", path: "/api/hf/settings"): { [self] _ in
        try json(["settings": hub.settingsPayload])
      },
      RouteKey(method: "PUT", path: "/api/hf/settings"): { [self] request in
        try hfAction {
          _ = try hub.updateSettings(try requestObject(request))
          return try json(["settings": hub.settingsPayload])
        }
      },
      RouteKey(method: "POST", path: "/api/hf/settings"): { [self] request in
        try hfAction {
          _ = try hub.updateSettings(try requestObject(request))
          return try json(["settings": hub.settingsPayload])
        }
      },
      RouteKey(method: "POST", path: "/api/hf/token"): { [self] request in
        try hfAction {
          guard let token = try requestObject(request)["token"] as? String else {
            throw HFError.invalidSetting("Send the token as {\"token\": \"hf_...\"}.")
          }
          let user = try hub.saveToken(token)
          return try json(["saved": true, "user": user])
        }
      },
      RouteKey(method: "DELETE", path: "/api/hf/token"): { [self] _ in
        try hfAction {
          try hub.deleteToken()
          return try json(["saved": false])
        }
      },
    ]
  }

  /// `/api/hf/downloads/<id>[/<action>]`.
  func huggingFaceDownloadPrefixRoute(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse? {
    let prefix = "/api/hf/downloads/"
    guard request.path.hasPrefix(prefix) else { return nil }
    let parts = request.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard (1...2).contains(parts.count), Self.validDownloadID(parts[0]) else {
      return try error(status: 404, code: "not_found", message: "not found")
    }
    let id = parts[0]
    let action = parts.count == 2 ? parts[1] : nil
    return try hfAction {
      var hint = Self.formQuery(request.target)["host"]
      if hint == nil, request.method == "POST", !request.body.isEmpty {
        hint = (try? requestObject(request))?["host"] as? String
      }
      if let host = try hub.downloadHost(id, hint: hint) {
        return try remoteDownloadRoute(request, id: id, action: action, host: host)
      }
      switch (request.method, action) {
      case ("GET", nil):
        guard let job = hub.downloads.job(id) else { throw HFError.unknownItem("No download with id \(id).") }
        return try hfDownload(job, request)
      case ("DELETE", nil):
        try hub.downloads.remove(id)
        return try json(["removed": id])
      case ("POST", "pause"):
        return try hfDownload(try hub.downloads.pause(id), request)
      case ("POST", "resume"):
        return try hfDownload(try hub.downloads.resume(id), request)
      case ("POST", "cancel"):
        let body = try requestObject(request)
        let delete = body["delete_files"] as? Bool ?? false
        return try hfDownload(try hub.downloads.cancel(id, deleteFiles: delete), request)
      case ("POST", "start"):
        return try hfDownload(try hub.profiles.start(id), request, status: 202)
      default:
        return try error(status: 404, code: "not_found", message: "not found")
      }
    }
  }

  /// The same download actions, on the host that has the download.
  func remoteDownloadRoute(_ request: ControllerHTTPRequest, id: String, action: String?, host: HFRemoteHost) throws
    -> ControllerHTTPResponse
  {
    func current() throws -> HFDownloadJob {
      guard let job = try hub.remoteDownloads(host).first(where: { $0.id == id }) else {
        throw HFError.unknownItem("No download with id \(id) on \(host.name).")
      }
      return job
    }
    switch (request.method, action) {
    case ("GET", nil):
      return try hfDownload(try current(), request)
    case ("DELETE", nil):
      let job = try current()
      if job.state.isActive || job.state == .paused {
        throw HFError.conflict("Pause or cancel the download before removing it from the list.")
      }
      if job.state == .completed {
        throw HFError.conflict(
          "This model is downloaded on \(host.name). To remove it, use: modelmatrixctl model delete \(id) (add --files to delete its files too).")
      }
      _ = try hub.remoteDelete(id, deleteFiles: false, host: host)
      return try json(["removed": id])
    case ("POST", "pause"), ("POST", "resume"), ("POST", "start"):
      let job = try hub.remoteDownloadAction(id, action: action ?? "", host: host)
      return try hfDownload(job, request, status: action == "start" ? 202 : 200)
    case ("POST", "cancel"):
      let delete = (try requestObject(request))["delete_files"] as? Bool ?? false
      return try hfDownload(try hub.remoteDownloadAction(id, action: "cancel", deleteFiles: delete, host: host), request)
    default:
      return try error(status: 404, code: "not_found", message: "not found")
    }
  }

  static func validDownloadID(_ id: String) -> Bool {
    (1...40).contains(id.count) && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
      && id.allSatisfy(\.isASCII)
  }

  func wantsText(_ request: ControllerHTTPRequest) -> Bool {
    Self.formQuery(request.target)["format"] == "text"
  }

  func hfText(_ text: String, status: Int = 200) -> ControllerHTTPResponse {
    ControllerHTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
  }

  func hfDownload(
    _ job: HFDownloadJob, _ request: ControllerHTTPRequest, existing: Bool? = nil, status: Int = 200
  ) throws -> ControllerHTTPResponse {
    if wantsText(request) {
      let prefix = existing == true ? "Already in the downloads list:\n" : ""
      return hfText(prefix + HFDownloadText.render(job), status: status)
    }
    return try hfJSON(HFDownloadEnvelope(download: job, existing: existing), status: status)
  }

  func hfJSON<T: Encodable>(_ value: T, status: Int = 200) throws -> ControllerHTTPResponse {
    ControllerHTTPResponse(status: status, body: try HFJSON.data(value))
  }

  /// Runs a Hugging Face action, turning its errors into JSON error answers.
  func hfAction(_ body: () throws -> ControllerHTTPResponse) throws -> ControllerHTTPResponse {
    do {
      return try body()
    } catch let failure as HFError {
      return try huggingFaceError(failure, text: false)
    }
  }
}

struct HFDownloadList: Encodable {
  let downloads: [HFDownloadJob]
  /// With ?host=all: hosts that couldn't be reached.
  var unreachable: [String]?
}

struct HFDownloadEnvelope: Encodable {
  let download: HFDownloadJob
  let existing: Bool?
}
