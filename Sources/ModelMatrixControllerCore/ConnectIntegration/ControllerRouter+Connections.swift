import Foundation

extension ControllerRouter {
    func connectionRoute(_ request: ControllerHTTPRequest) throws -> ControllerHTTPResponse? {
        guard request.path.hasPrefix("/api/connect/") else { return nil }
        let value: [String: Any]
        do {
            if request.method == "GET" {
                let query = URLComponents(string: request.target)?.queryItems ?? []
                func parameter(_ name: String) -> String? { query.last { $0.name == name }?.value }
                switch request.path {
                case "/api/connect/profiles": value = connections.profilesPayload()
                case "/api/connect/targets": value = connections.targetsPayload()
                case "/api/connect/list": value = connections.listPayload()
                case "/api/connect/plan":
                    guard let id = parameter("plan_id"), !id.isEmpty else {
                        return try error(status: 400, code: "missing_plan", message: "Select a saved configuration plan first.")
                    }
                    value = try connections.planPayload(planID: id)
                case "/api/connect/details":
                    guard let profile = parameter("profile"), !profile.isEmpty else {
                        return try error(status: 400, code: "missing_profile", message: "Select a model profile first.")
                    }
                    value = try connections.details(profile: profile, connection: parameter("connection"))
                default: return try error(status: 404, code: "not_found", message: "Unknown connection API.")
                }
            } else if request.method == "POST" {
                let body = try requestObject(request)
                switch request.path {
                case "/api/connect/plan":
                    value = try connections.plan(profile: requiredString(body, key: "profile"),
                        target: requiredString(body, key: "target"), makeDefault: JSONSupport.boolValue(body["make_default"]) == true)
                case "/api/connect/apply":
                    value = try connections.apply(planID: requiredString(body, key: "plan_id"), approved: body["approved"] as? Bool == true)
                case "/api/connect/verify": value = try connections.verify(id: requiredString(body, key: "id"))
                case "/api/connect/disconnect":
                    value = try connections.disconnect(id: requiredString(body, key: "id"),
                        removeConfig: body["remove_config"] as? Bool ?? true, approved: body["approved"] as? Bool == true)
                case "/api/connect/undo":
                    value = try connections.undo(id: requiredString(body, key: "id"), approved: body["approved"] as? Bool == true)
                case "/api/connect/key":
                    value = try connections.secret(id: requiredString(body, key: "id"), approved: body["approved"] as? Bool == true)
                default: return try error(status: 404, code: "not_found", message: "Unknown connection API.")
                }
            } else {
                return try error(status: 405, code: "method_not_allowed", message: "Use GET or POST for connections.")
            }
            let answer = try json(value)
            var headers = answer.headers
            headers["Cache-Control"] = "no-store"
            headers["Pragma"] = "no-cache"
            return ControllerHTTPResponse(status: answer.status, headers: headers, body: answer.body)
        } catch let failure as ClientConnectionError {
            return try error(status: failure.status, code: failure.code, message: failure.message)
        } catch let failure as ClientConfigError {
            return try error(status: failure.status, code: failure.code, message: failure.message)
        }
    }
}
