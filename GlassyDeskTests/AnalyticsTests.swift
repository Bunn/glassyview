import Foundation
import Testing
@testable import GlassyDesk

actor AnalyticsTransportSpy: AnalyticsTransporting {
    private var results: [AnalyticsDeliveryResult]
    private var recordedBatches: [[AnalyticsEvent]] = []

    init(results: [AnalyticsDeliveryResult] = [.accepted]) {
        self.results = results
    }

    func send(_ events: [AnalyticsEvent]) async -> AnalyticsDeliveryResult {
        recordedBatches.append(events)
        return results.isEmpty ? .accepted : results.removeFirst()
    }

    func batches() -> [[AnalyticsEvent]] {
        recordedBatches
    }
}

actor SuspendedAnalyticsTransport: AnalyticsTransporting {
    private var recordedBatches: [[AnalyticsEvent]] = []
    private var continuations: [CheckedContinuation<AnalyticsDeliveryResult, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ events: [AnalyticsEvent]) async -> AnalyticsDeliveryResult {
        recordedBatches.append(events)
        resumeSatisfiedWaiters()

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForSendCount(_ count: Int) async {
        guard recordedBatches.count < count else { return }

        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func resumeSend(at index: Int, with result: AnalyticsDeliveryResult) {
        continuations[index].resume(returning: result)
    }

    func batches() -> [[AnalyticsEvent]] {
        recordedBatches
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = countWaiters.filter { recordedBatches.count >= $0.0 }
        countWaiters.removeAll { recordedBatches.count >= $0.0 }
        satisfied.forEach { $0.1.resume() }
    }
}

#if DEBUG
@MainActor
private final class DebugAnalyticsEventLogSpy {
    private(set) var entries: [(AnalyticsEventName, AnalyticsEventContext?)] = []

    func record(_ event: AnalyticsEventName, context: AnalyticsEventContext?) {
        entries.append((event, context))
    }
}
#endif

@MainActor
@Suite("Privacy-preserving analytics", .serialized)
struct AnalyticsTests {
    private let metadata = AnalyticsAppMetadata(
        platform: "ios",
        deviceClass: .iPad,
        appVersion: "1.2",
        build: "34",
        osMajor: 26
    )

    @Test("Collection is enabled by default")
    func collectionIsEnabledByDefault() {
        #expect(AnalyticsPreference.defaultCollectionEnabled)
    }

    @Test("Payload contains only allowlisted aggregate fields")
    func payloadContainsOnlyAllowlistedFields() throws {
        let event = AnalyticsEvent(
            name: .paywallDismissed,
            context: AnalyticsEventContext(
                source: .sessionLimit,
                outcome: .cancelled
            ),
            metadata: metadata
        )
        let data = try JSONEncoder().encode(AnalyticsBatch(events: [event]))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(json["events"] as? [[String: Any]])
        let encodedEvent = try #require(events.first)

        #expect(Set(encodedEvent.keys) == Set([
            "schemaVersion", "event", "app", "platform",
            "deviceClass", "appVersion", "build", "osMajor", "context",
        ]))
        #expect(encodedEvent["event"] as? String == "paywall_dismissed")
        #expect(encodedEvent["app"] as? String == "glassydesk")
        #expect(encodedEvent["deviceClass"] as? String == "ipad")

        let context = try #require(encodedEvent["context"] as? [String: Any])
        #expect(Set(context.keys) == Set(["source", "outcome"]))
        #expect(context["source"] as? String == "session_limit")
        #expect(context["outcome"] as? String == "cancelled")

        let serialized = try #require(String(data: data, encoding: .utf8))
        for forbiddenField in [
            "host", "machine", "credential", "sessionId", "installation",
            "userId", "timestamp", "duration", "address",
        ] {
            #expect(!serialized.contains(forbiddenField))
        }
    }

    @Test("Device idioms map to coarse analytics classes")
    func deviceClassMapping() {
        #expect(AnalyticsDeviceClass(interfaceIdiom: .phone) == .iPhone)
        #expect(AnalyticsDeviceClass(interfaceIdiom: .pad) == .iPad)
        #expect(AnalyticsDeviceClass(interfaceIdiom: .unspecified) == .other)
    }

    @Test("Rate-limit token stays in the header")
    func rateLimitTokenIsHeaderOnly() throws {
        let token = "temporary-rate-limit-token"
        let event = AnalyticsEvent(name: .appOpened, context: nil, metadata: metadata)
        let request = try AnalyticsRequestBuilder().makeRequest(
            events: [event],
            token: token
        )

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Analytics-Token") == token)
        let body = try #require(request.httpBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))
        #expect(!bodyString.contains(token))
        #expect(body.count <= AnalyticsRequestBuilder.maximumBodySize)
    }

    @Test("Request builder enforces batch limits")
    func requestBuilderEnforcesBatchLimits() {
        let event = AnalyticsEvent(name: .appOpened, context: nil, metadata: metadata)
        let oversizedBatch = Array(
            repeating: event,
            count: AnalyticsRequestBuilder.maximumEventCount + 1
        )

        #expect(throws: AnalyticsRequestError.tooManyEvents) {
            try AnalyticsRequestBuilder().makeRequest(
                events: oversizedBatch,
                token: "temporary-rate-limit-token"
            )
        }
        #expect(throws: AnalyticsRequestError.invalidToken) {
            try AnalyticsRequestBuilder().makeRequest(events: [event], token: "short")
        }
    }

    @Test("HTTP response handling follows the Worker contract")
    func responseHandling() {
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 202) == .accepted)
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 400) == .discard)
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 413) == .discard)
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 415) == .discard)
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 429) == .retry)
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 500) == .retry)
        #expect(CloudflareAnalyticsTransport.deliveryResult(for: 503) == .retry)
    }

    @Test("Stored opt-out prevents queueing and delivery")
    func optOutPreventsCollection() async {
        let transport = AnalyticsTransportSpy()
        let tracker = CloudflareAnalyticsTracker(
            transport: transport,
            metadata: metadata,
            retryDelays: []
        )

        tracker.track(.appOpened)
        await tracker.waitForPendingDelivery()

        #expect(tracker.pendingEventCount == 0)
        #expect(await transport.batches().isEmpty)
    }

    @Test("Enabled collection delivers sanitized events")
    func enabledCollectionDeliversEvents() async {
        let transport = AnalyticsTransportSpy()
        let tracker = CloudflareAnalyticsTracker(
            transport: transport,
            metadata: metadata,
            retryDelays: []
        )
        tracker.setCollectionEnabled(true)

        tracker.track(.freeSessionStarted)
        tracker.track(.paywallPresented)
        await tracker.waitForPendingDelivery()

        let batches = await transport.batches()
        #expect(batches.flatMap { $0 }.map(\.event) == [
            .freeSessionStarted,
            .paywallPresented,
        ])
    }

    @Test("Opting out delivers a final event before disabling collection")
    func optOutDeliversFinalEventBeforeDisablingCollection() async throws {
        let transport = AnalyticsTransportSpy()
        let tracker = CloudflareAnalyticsTracker(
            transport: transport,
            metadata: metadata,
            retryDelays: []
        )
        tracker.setCollectionEnabled(true)
        tracker.track(.appOpened)

        await tracker.disableCollectionAfterTrackingOptOut()

        tracker.track(.purchaseStarted)
        await tracker.waitForPendingDelivery()

        let events = await transport.batches().flatMap { $0 }
        #expect(events.map(\.event) == [.appOpened, .analyticsDisabled])

        let optOut = try #require(events.last)
        #expect(optOut.context == AnalyticsEventContext(
            source: .settings,
            outcome: .success
        ))
        #expect(tracker.pendingEventCount == 0)
    }

    @Test("Retryable failures retain a batch for a later flush")
    func retryableFailureIsRetained() async {
        let transport = AnalyticsTransportSpy(results: [.retry, .accepted])
        let tracker = CloudflareAnalyticsTracker(
            transport: transport,
            metadata: metadata,
            retryDelays: []
        )
        tracker.setCollectionEnabled(true)
        tracker.track(.purchaseStarted)

        await tracker.waitForPendingDelivery()
        #expect(tracker.pendingEventCount == 1)

        tracker.flush()
        await tracker.waitForPendingDelivery()

        let batches = await transport.batches()
        #expect(batches.count == 2)
        #expect(batches[0] == batches[1])
        #expect(tracker.pendingEventCount == 0)
    }

    @Test("Queue evicts the oldest events at its bound")
    func queueEvictsOldestEvents() async {
        let transport = SuspendedAnalyticsTransport()
        let tracker = CloudflareAnalyticsTracker(
            transport: transport,
            metadata: metadata,
            batchSize: 3,
            maximumQueueSize: 3,
            retryDelays: []
        )
        tracker.setCollectionEnabled(true)
        tracker.track(.appOpened)
        await transport.waitForSendCount(1)

        tracker.track(.freeSessionStarted)
        tracker.track(.freeSessionRestarted)
        tracker.track(.paywallPresented)
        tracker.track(.paywallDismissed)
        #expect(tracker.pendingEventCount == 3)

        await transport.resumeSend(at: 0, with: .accepted)
        await transport.waitForSendCount(2)
        let batches = await transport.batches()
        #expect(batches[1].map(\.event) == [
            .freeSessionRestarted,
            .paywallPresented,
            .paywallDismissed,
        ])

        await transport.resumeSend(at: 1, with: .accepted)
        await tracker.waitForPendingDelivery()
        #expect(tracker.pendingEventCount == 0)
    }

    @Test("Hosted tests suppress production analytics")
    func hostedTestsSuppressProductionAnalytics() {
        #expect(AnalyticsRuntime.isUnitTestHost)
        #expect(!AnalyticsRuntime.shouldRunProductionAnalytics)
    }

    @Test("Debug uses console analytics while Release uses production analytics")
    func buildFlavorSelectsAnalyticsDestination() {
        #expect(AnalyticsRuntime.resolveMode(
            buildFlavor: .debug,
            isUnitTestHost: false,
            isUITestingLaunch: false
        ) == .console)
        #expect(AnalyticsRuntime.resolveMode(
            buildFlavor: .release,
            isUnitTestHost: false,
            isUITestingLaunch: false
        ) == .production)
    }

    @Test("Tests never select an analytics destination")
    func testsDisableAnalyticsDestinations() {
        for buildFlavor in [AnalyticsBuildFlavor.debug, .release] {
            #expect(AnalyticsRuntime.resolveMode(
                buildFlavor: buildFlavor,
                isUnitTestHost: true,
                isUITestingLaunch: false
            ) == .disabled)
            #expect(AnalyticsRuntime.resolveMode(
                buildFlavor: buildFlavor,
                isUnitTestHost: false,
                isUITestingLaunch: true
            ) == .disabled)
        }
    }

    #if DEBUG
    @Test("Debug analytics prints events without queueing a delivery")
    func debugAnalyticsIsConsoleOnly() async {
        let log = DebugAnalyticsEventLogSpy()
        let tracker = DebugConsoleAnalyticsTracker { event, context in
            log.record(event, context: context)
        }
        let context = AnalyticsEventContext(
            source: .sessionLimit,
            outcome: .cancelled,
            reason: .unknown
        )

        tracker.setCollectionEnabled(true)
        tracker.track(.paywallDismissed, context: context)
        tracker.flush()

        #expect(log.entries.count == 1)
        #expect(log.entries.first?.0 == .paywallDismissed)
        #expect(log.entries.first?.1 == context)

        await tracker.disableCollectionAfterTrackingOptOut()
        tracker.track(.purchaseStarted)

        #expect(log.entries.map(\.0) == [
            .paywallDismissed,
            .analyticsDisabled,
        ])
    }
    #endif
}
