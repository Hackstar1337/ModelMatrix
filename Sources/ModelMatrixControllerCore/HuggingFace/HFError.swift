import Foundation

/// Failures of a Hugging Face check, each with a message a user can act on.
public enum HFError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The typed name or link is not a valid model reference.
  case invalidName(String)
  /// The repository does not exist, or it is private.
  case notFound(String)
  /// The files need a Hugging Face login (gated model).
  case loginRequired(String)
  /// Hugging Face asked us to slow down.
  case rateLimited(retryAfterSeconds: Int?)
  /// Hugging Face (or the mirror) could not be reached.
  case unreachable(String)
  /// Hugging Face answered with an unexpected status.
  case upstream(status: Int)
  /// Hugging Face sent something we could not read, or too much of it.
  case badResponse(String)

  public var description: String {
    switch self {
    case .invalidName(let message): return message
    case .notFound(let repo):
      return "No public model named \(repo) was found on Hugging Face. Check the spelling; private models are not supported yet."
    case .loginRequired(let repo):
      return "\(repo) needs a Hugging Face login and accepting its license on huggingface.co before its files can be read."
    case .rateLimited(let seconds):
      if let seconds { return "Hugging Face is limiting requests. Try again in \(seconds) seconds." }
      return "Hugging Face is limiting requests. Try again in a minute."
    case .unreachable(let detail):
      return "Can't reach Hugging Face (\(detail)). Check the internet connection, proxy or mirror setting."
    case .upstream(let status):
      return "Hugging Face answered with an error (HTTP \(status)). Try again later."
    case .badResponse(let detail):
      return "Hugging Face sent an unexpected answer (\(detail))."
    }
  }

  /// Stable machine-readable code for API clients.
  public var code: String {
    switch self {
    case .invalidName: return "invalid_name"
    case .notFound: return "not_found"
    case .loginRequired: return "login_required"
    case .rateLimited: return "rate_limited"
    case .unreachable: return "hf_unreachable"
    case .upstream: return "hf_error"
    case .badResponse: return "hf_bad_response"
    }
  }

  /// HTTP status the controller answers with.
  public var httpStatus: Int {
    switch self {
    case .invalidName: return 400
    case .notFound: return 404
    case .loginRequired: return 403
    case .rateLimited: return 429
    case .unreachable, .upstream, .badResponse: return 502
    }
  }
}
