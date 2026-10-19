import Foundation
import Testing
import ModelMatrixCore
import ModelMatrixTestSupport
@testable import ModelMatrixApp

private let remoteContext = GatewayContext(id: "gw-test", name: "GPUBox")

@MainActor
private func makeRemoteStore(
    loopbackEndpointProbe: MatrixStore.LoopbackEndpointProbe? = nil,
    controllerClientFactory: MatrixStore.ControllerClientFactory? = nil
) -> MatrixStore {
    MatrixStore(
        controllerBaseURL: "http://127.0.0.1:9911",
        gateway: remoteContext,
        autoStartRefresh: false,
        loopbackEndpointProbe: loopbackEndpointProbe,
        controllerClientFactory: controllerClientFactory
            ?? { try ControllerClient(baseURLString: $0, authToken: $1) }
    )
}

@MainActor
@Test func remoteStoreSkipsLoopbackEndpointProbe() async {
    let recorder = ProbeRecorder()
    let store = makeRemoteStore { profiles in
        _ = await recorder.record(profiles)
        return []
    }

    // Remote agents report loopback URLs that are only loopback on the remote
    // host; the store must never probe them from this Mac.
    store.statuses = [ModelFixtures.profileStatus()]
    store.lastUpdated = .now

    await store.probeLoopbackEndpointsIfNeeded()
    #expect(await recorder.calls == 0)
    #expect(store.statuses.filter(\.running).count == 1)

    store.startLoopbackEndpointProbe()
    #expect(store.loopbackEndpointProbeTask == nil)
}

@MainActor
@Test func remoteStoreStaysEmptyWhenRefreshFailsWithoutCache() async {
    let store = makeRemoteStore(controllerClientFactory: { _, _ in
        struct Boom: Error {}
        throw Boom()
    })

    await store.refresh()

    // A remote store must not fall back to the local gateway's cache file.
    #expect(store.statuses.isEmpty)
    #expect(store.lastError != nil)
    // Structured provenance, not message text: the failure is a plain .failed,
    // never the cached-state fallback.
    #expect(store.statusFreshness(relativeTo: .now) != .cached)
}

@MainActor
@Test func remoteStoreNamespacesLastActiveProfilesKey() {
    let legacyKey = "modelmatrix.last-active-profiles"
    let namespacedKey = "\(legacyKey).gw-test"
    let defaults = UserDefaults.standard
    let savedLegacy = defaults.stringArray(forKey: legacyKey)
    defaults.removeObject(forKey: legacyKey)
    defer {
        defaults.removeObject(forKey: namespacedKey)
        if let savedLegacy {
            defaults.set(savedLegacy, forKey: legacyKey)
        } else {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    let store = makeRemoteStore()
    #expect(store.lastActiveProfilesDefaultsKey == namespacedKey)
    #expect(store.benchmarkCooldownDefaultsKey == "modelmatrix.last-benchmark-started-at.gw-test")

    store.rememberLastActiveProfiles(from: [ModelFixtures.profileStatus(profile: "gpubox-only")])

    #expect(defaults.stringArray(forKey: namespacedKey) == ["gpubox-only"])
    #expect(defaults.stringArray(forKey: legacyKey) == nil)
}

@MainActor
@Test func localStoreKeepsLegacyDefaultsKeys() {
    let store = MatrixStore(
        controllerBaseURL: ControllerEndpointDefaults.baseURLString,
        autoStartRefresh: false
    )
    #expect(store.gateway == .local)
    #expect(store.lastActiveProfilesDefaultsKey == "modelmatrix.last-active-profiles")
    #expect(store.benchmarkCooldownDefaultsKey == "modelmatrix.last-benchmark-started-at")
}
