import Foundation

extension ControllerRouter {
  var routes: [RouteKey: Route] {
    var combined = getRoutes
    for (key, route) in postRoutes {
      combined[key] = route
    }
    for (key, route) in dashboardRoutes {
      combined[key] = route
    }
    for (key, route) in optimizeRoutes {
      combined[key] = route
    }
    for (key, route) in huggingFaceRoutes {
      combined[key] = route
    }
    for (key, route) in huggingFaceDownloadRoutes {
      combined[key] = route
    }
    for (key, route) in huggingFaceEngineRoutes {
      combined[key] = route
    }
    return combined
  }
}
