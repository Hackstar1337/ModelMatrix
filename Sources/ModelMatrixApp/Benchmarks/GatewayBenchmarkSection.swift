import Foundation
import ModelMatrixCore

struct GatewayBenchmarkSection: Identifiable, Equatable {
    let id: String
    let name: String
    let benchmark: BenchmarkStatus?
    let activeBenchmarkProfiles: [String]
    let cooldownEndsAt: Date?
}
