import Foundation
import Testing
import ModelMatrixCore

struct ControllerEndpointDefaultsTests {
    @Test func sharedLoopbackEndpointMatchesHistoricalDefaults() {
        #expect(ControllerEndpointDefaults.host == "127.0.0.1")
        #expect(ControllerEndpointDefaults.port == 7700)
        #expect(ControllerEndpointDefaults.baseURLString == "http://127.0.0.1:7700")
        #expect(ControllerEndpointDefaults.baseURLUserDefaultsKey == "controllerBaseURL")
    }
}
