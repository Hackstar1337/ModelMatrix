import Foundation

extension ControllerRouter {
  func queryItems(_ request: ControllerHTTPRequest) -> [String: String] {
    var items: [String: String] = [:]
    for item in URLComponents(string: request.target)?.queryItems ?? [] {
      items[item.name] = item.value ?? ""
    }
    return items
  }

  func usageFilter(_ request: ControllerHTTPRequest) -> UsageFilter {
    let query = queryItems(request)
    return UsageFilter(
      range: query["range"] ?? "24h", host: query["host"] ?? "all", tier: query["tier"] ?? "all")
  }

  func requireUsage() throws -> UsageService {
    guard let usage else {
      throw ControllerError.unsupported("usage metering is disabled")
    }
    return usage
  }

  /// Like `mapped`, but keeps the validation message so the editor can show it.
  func detailed(_ body: () throws -> ControllerHTTPResponse) throws -> ControllerHTTPResponse {
    do {
      return try body()
    } catch ControllerError.usage(let message) {
      return try error(status: 400, code: "usage_error", message: message)
    } catch ControllerError.invalidProfile(let message) {
      return try error(status: 400, code: "invalid_profile", message: message)
    } catch ControllerError.invalidConfiguration(let message) {
      return try error(status: 400, code: "invalid_configuration", message: message)
    } catch ControllerError.operationFailed(let message) {
      return try error(status: 500, code: "operation_failed", message: message)
    }
  }

  func stringValues(_ value: Any?) throws -> [String: String]? {
    guard let value else { return nil }
    guard let object = value as? [String: Any] else {
      throw ControllerError.usage("values must be an object")
    }
    var values: [String: String] = [:]
    for (key, raw) in object {
      switch raw {
      case let string as String: values[key] = string
      case let number as NSNumber: values[key] = number.stringValue
      case is NSNull: continue
      default: throw ControllerError.usage("value for \(key) must be a string")
      }
    }
    return values
  }

  var dashboardRoutes: [RouteKey: Route] {
    [
      RouteKey(method: "GET", path: "/api/dashboard/info"): { [self] _ in
        var info: [String: Any] = [
          "name": "ModelMatrix",
          "version": ControllerVersion.current,
          "controller_url": "http://\(service.configuration.host):\(service.configuration.port)",
          "token_required": authToken != nil,
          "profiles_dir": service.configuration.profilesDirectory.path,
          "controller_root": service.configuration.root.path,
        ]
        if let usage { info["relay"] = usage.relayStatus() }
        return try json(info)
      },
      RouteKey(method: "GET", path: "/api/host/metrics"): { [self] _ in
        try json(hostMetrics.payload())
      },
      // Profiles
      RouteKey(method: "GET", path: "/api/profiles/runtimes"): { [self] _ in
        try json([
          "runtimes": ControllerService.runtimeList(),
          "templates": service.profileTemplates(),
        ])
      },
      RouteKey(method: "GET", path: "/api/profiles/document"): { [self] request in
        guard let name = queryItems(request)["profile"], !name.isEmpty else {
          throw ControllerError.usage("missing profile")
        }
        return try json(service.profileDocument(name))
      },
      RouteKey(method: "POST", path: "/api/profiles/save"): { [self] request in
        try detailed {
          let payload = try requestObject(request)
          let name = try requiredString(payload, key: "profile")
          let text = payload["text"] as? String
          let values = try stringValues(payload["values"])
          guard text != nil || values != nil else {
            throw ControllerError.usage("send values or text")
          }
          let saved = try service.saveProfile(
            name: name, values: values, text: text,
            originalName: payload["original_profile"] as? String,
            createOnly: JSONSupport.boolValue(payload["create"]) ?? false)
          return try json(saved)
        }
      },
      RouteKey(method: "POST", path: "/api/profiles/delete"): { [self] request in
        try detailed {
          let payload = try requestObject(request)
          try service.deleteProfile(try requiredString(payload, key: "profile"))
          return try json(["deleted": true])
        }
      },
      RouteKey(method: "POST", path: "/api/profiles/duplicate"): { [self] request in
        try detailed {
          let payload = try requestObject(request)
          return try json(
            service.duplicateProfile(
              try requiredString(payload, key: "profile"),
              as: try requiredString(payload, key: "new_profile")))
        }
      },
      RouteKey(method: "POST", path: "/api/profiles/capture"): { [self] request in
        try detailed {
          let payload = try requestObject(request)
          let name = try requiredString(payload, key: "profile")
          let enabled = JSONSupport.boolValue(payload["enabled"]) ?? false
          guard let file = service.profileFile(named: name) else {
            throw ControllerError.profileNotFound(name)
          }
          var values = try service.profiles.parseValues(file: file)
          values["PROFILE_NAME"] = nil
          if enabled { values["CAPTURE_MODE"] = "1" } else { values["CAPTURE_MODE"] = nil }
          try service.saveProfile(name: name, values: values, originalName: name)
          usage?.syncCaptureListeners()
          return try json(["profile": name, "capture": enabled, "capture_state": usage?.captureState() ?? []])
        }
      },
      // Ollama
      RouteKey(method: "GET", path: "/api/ollama/status"): { [self] _ in
        try json(try requireUsage().ollamaStatus())
      },
      // Usage
      RouteKey(method: "GET", path: "/api/usage/overview"): { [self] request in
        let usage = try requireUsage()
        let filter = usageFilter(request)
        return try json([
          "summary": usage.store.summary(filter),
          "totals": usage.store.totals(host: filter.host, tier: filter.tier),
          "host_stats": usage.store.hostStats(),
          "timeseries": usage.store.timeseries(filter),
          "models": usage.store.models(filter),
          "clients": Array(usage.store.clients(filter).prefix(12)),
          "recent": usage.store.recent(filter, limit: 30),
          "in_flight": usage.inflightSnapshot(),
          "last_id": usage.store.lastID(),
          "hosts": usage.store.hosts(),
          "relay": usage.relayStatus(),
          "generated_at": Date().timeIntervalSince1970,
        ])
      },
      RouteKey(method: "GET", path: "/api/usage/summary"): { [self] request in
        try json(try requireUsage().store.summary(usageFilter(request)))
      },
      RouteKey(method: "GET", path: "/api/usage/timeseries"): { [self] request in
        try json(["buckets": try requireUsage().store.timeseries(usageFilter(request))])
      },
      RouteKey(method: "GET", path: "/api/usage/models"): { [self] request in
        try json(["models": try requireUsage().store.models(usageFilter(request))])
      },
      RouteKey(method: "GET", path: "/api/usage/clients"): { [self] request in
        try json(["clients": try requireUsage().store.clients(usageFilter(request))])
      },
      RouteKey(method: "GET", path: "/api/usage/requests"): { [self] request in
        let usage = try requireUsage()
        let query = queryItems(request)
        let limit = Int(query["limit"] ?? "") ?? 100
        let offset = Int(query["offset"] ?? "") ?? 0
        return try json([
          "requests": usage.store.recent(
            usageFilter(request), limit: limit, offset: offset, search: query["q"]),
          "limit": limit, "offset": offset,
        ])
      },
      RouteKey(method: "GET", path: "/api/usage/live"): { [self] request in
        let usage = try requireUsage()
        let since = Int64(queryItems(request)["since"] ?? "")
        var filter = usageFilter(request)
        filter = UsageFilter(range: "30d", host: filter.host, tier: filter.tier)
        return try json([
          "in_flight": usage.inflightSnapshot(),
          "recent": usage.store.recent(filter, limit: 30, sinceID: since),
          "last_id": usage.store.lastID(),
        ])
      },
      RouteKey(method: "GET", path: "/api/usage/export.csv"): { [self] request in
        let usage = try requireUsage()
        let filter = usageFilter(request)
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return ControllerHTTPResponse(
          status: 200,
          headers: [
            "Content-Type": "text/csv; charset=utf-8",
            "Content-Disposition": "attachment; filename=\"modelmatrix-usage-\(filter.range)-\(stamp).csv\"",
            "Cache-Control": "no-store",
          ],
          body: Data(usage.store.csv(filter).utf8))
      },
      RouteKey(method: "GET", path: "/api/usage/settings"): { [self] _ in
        let usage = try requireUsage()
        var settings = usage.relayStatus()
        settings["capture"] = usage.captureState()
        return try json(settings)
      },
      RouteKey(method: "POST", path: "/api/usage/settings"): { [self] request in
        try detailed {
          let usage = try requireUsage()
          let payload = try requestObject(request)
          if let raw = payload["retention_days"] {
            guard let days = (raw as? NSNumber)?.intValue ?? Int(raw as? String ?? ""),
              (1...3650).contains(days)
            else { throw ControllerError.usage("retention_days must be 1-3650") }
            usage.store.setSetting("retention_days", String(days))
            usage.store.prune(olderThanDays: days)
          }
          var settings = usage.relayStatus()
          settings["capture"] = usage.captureState()
          return try json(settings)
        }
      },
      RouteKey(method: "POST", path: "/api/usage/clients/rename"): { [self] request in
        try detailed {
          let usage = try requireUsage()
          let payload = try requestObject(request)
          usage.store.renameClient(
            try requiredString(payload, key: "client_id"), to: payload["name"] as? String ?? "")
          return try json(["renamed": true])
        }
      },
      RouteKey(method: "POST", path: "/api/usage/reset"): { [self] request in
        try detailed {
          let usage = try requireUsage()
          let payload = try requestObject(request)
          guard JSONSupport.boolValue(payload["confirm"]) == true else {
            throw ControllerError.usage("send {\"confirm\": true} to delete all usage history")
          }
          usage.store.reset()
          return try json(["reset": true])
        }
      },
      // Bridge (menu bar app)
      RouteKey(method: "POST", path: "/api/bridge/heartbeat"): { [self] request in
        let payload = try requestObject(request)
        return try json(["commands": bridge.heartbeat(payload)])
      },
      RouteKey(method: "GET", path: "/api/bridge/state"): { [self] _ in
        try json(bridge.publicState())
      },
      RouteKey(method: "POST", path: "/api/bridge/commands"): { [self] request in
        try detailed {
          let payload = try requestObject(request)
          guard bridge.appConnected else {
            return try error(
              status: 503, code: "app_not_connected",
              message: "open the ModelMatrix menu bar app to run this action")
          }
          let command = try bridge.enqueue(
            type: try requiredString(payload, key: "type"),
            payload: payload["payload"] as? [String: Any] ?? [:])
          return try json(command.publicObject, status: 202)
        }
      },
      RouteKey(method: "POST", path: "/api/bridge/commands/result"): { [self] request in
        let payload = try requestObject(request)
        let found = bridge.complete(
          id: try requiredString(payload, key: "id"),
          ok: JSONSupport.boolValue(payload["ok"]) ?? false,
          message: payload["message"] as? String,
          result: payload["result"])
        return found
          ? try json(["recorded": true])
          : try error(status: 404, code: "not_found", message: "command not found")
      },
    ]
  }
}
