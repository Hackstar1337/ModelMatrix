import Foundation
import ModelMatrixCore

enum HTTPParseResult {
  case request(ControllerHTTPRequest)
  case needMore
  case error(Int, String, String)
}
