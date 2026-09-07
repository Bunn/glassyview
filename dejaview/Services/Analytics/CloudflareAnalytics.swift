import Foundation
import OSLog

enum AnalyticsDeliveryResult: Equatable, Sendable {
    case accepted
    case discard
    case retry
}

enum AnalyticsRequestError: Error, Equatable {
    case emptyBatch
    case tooManyEvents
    case bodyTooLarge
    case invalidToken
}

struct AnalyticsRequestBuilder: Sendable {
    static let maximumEventCount = 50
    static let maximumBodySize = 64 * 1_024

    let endpoint: URL

    init(endpoint: URL = URL(string: "https://analytics.bunn.dev/v1/events")!) {
        self.endpoint = endpoint
    }

    func makeRequest(events: [AnalyticsEvent], token: String) throws -> URLRequest {
        guard !events.isEmpty else { throw AnalyticsRequestError.emptyBatch }
        guard events.count <= Self.maximumEventCount else {
            throw AnalyticsRequestError.tooManyEvents
        }
        guard Self.isValidRateLimitToken(token) else {
            throw AnalyticsRequestError.invalidToken
        }

        let body = try JSONEncoder().encode(AnalyticsBatch(events: events))
        guard body.count <= Self.maximumBodySize else {
            throw AnalyticsRequestError.bodyTooLarge
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("GlassyDesk-Analytics/1", forHTTPHeaderField: "User-Agent")
        request.setValue(token, forHTTPHeaderField: "X-Analytics-Token")
        request.httpBody = body
        return request
    }

    private static func isValidRateLimitToken(_ token: String) -> Bool {
        guard (16...128).contains(token.count) else { return false }

        return token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }
}

protocol AnalyticsTransporting: Sendable {
    func send(_ events: [AnalyticsEvent]) async -> AnalyticsDeliveryResult
}

actor CloudflareAnalyticsTransport: AnalyticsTransporting {
    private let session: URLSession
    private let requestBuilder: AnalyticsRequestBuilder

    init(
        endpoint: URL = URL(string: "https://analytics.bunn.dev/v1/events")!,
        session: URLSession? = nil
    ) {
        requestBuilder = AnalyticsRequestBuilder(endpoint: endpoint)
        self.session = session ?? Self.makeEphemeralSession()
    }

    func send(_ events: [AnalyticsEvent]) async -> AnalyticsDeliveryResult {
        guard !events.isEmpty else { return .accepted }

        do {
            // This header only partitions rate limits. A fresh token for every
            // upload prevents it from becoming a persistent installation ID.
            let request = try requestBuilder.makeRequest(
                events: events,
                token: UUID().uuidString
            )
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                #if DEBUG
                AppLog.analytics.error(
                    "Delivery failed; reason=non_http_response"
                )
                #endif
                return .retry
            }

            let result = Self.deliveryResult(for: response.statusCode)

            #if DEBUG
            if result != .accepted {
                AppLog.analytics.error(
                    "Delivery failed; reason=http_status status=\(response.statusCode, privacy: .public) result=\(String(describing: result), privacy: .public)"
                )
            }
            #endif

            return result
        } catch is CancellationError {
            #if DEBUG
            AppLog.analytics.debug("Delivery cancelled")
            #endif
            return .retry
        } catch let error as AnalyticsRequestError {
            #if DEBUG
            AppLog.analytics.error(
                "Request construction failed; reason=\(String(describing: error), privacy: .public)"
            )
            #endif

            switch error {
            case .emptyBatch:
                return .accepted
            case .tooManyEvents, .bodyTooLarge, .invalidToken:
                return .discard
            }
        } catch {
            #if DEBUG
            let error = error as NSError
            AppLog.analytics.error(
                "Delivery failed; reason=transport_error domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
            )
            #endif

            // Never log analytics bodies, headers, or localized error text.
            // Product behavior must remain correct even when every upload fails.
            return .retry
        }
    }

    nonisolated static func deliveryResult(for statusCode: Int) -> AnalyticsDeliveryResult {
        switch statusCode {
        case 200..<300:
            .accepted
        case 429, 500...599:
            .retry
        case 400..<500:
            .discard
        default:
            .retry
        }
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class CloudflareAnalyticsTracker: AnalyticsTracking {
    private let transport: any AnalyticsTransporting
    private let metadata: AnalyticsAppMetadata
    private let batchSize: Int
    private let maximumQueueSize: Int
    private let retryDelays: [Duration]

    private var isCollectionEnabled = false
    private var queue: [AnalyticsEvent] = []
    private var deliveryTask: Task<Void, Never>?
    private var deliveryGeneration = 0

    init(
        transport: any AnalyticsTransporting,
        metadata: AnalyticsAppMetadata? = nil,
        batchSize: Int = 20,
        maximumQueueSize: Int = 200,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    ) {
        self.transport = transport
        self.metadata = metadata ?? .current
        self.batchSize = min(max(batchSize, 1), AnalyticsRequestBuilder.maximumEventCount)
        self.maximumQueueSize = max(maximumQueueSize, self.batchSize)
        self.retryDelays = retryDelays
    }

    static func live() -> CloudflareAnalyticsTracker {
        CloudflareAnalyticsTracker(transport: CloudflareAnalyticsTransport())
    }

    func setCollectionEnabled(_ enabled: Bool) {
        #if DEBUG
        AppLog.analytics.debug(
            "Collection changed; enabled=\(enabled, privacy: .public) pendingBeforeChange=\(self.queue.count, privacy: .public)"
        )
        #endif

        isCollectionEnabled = enabled

        if enabled {
            scheduleDeliveryIfNeeded()
        } else {
            deliveryGeneration &+= 1
            deliveryTask?.cancel()
            deliveryTask = nil
            queue.removeAll(keepingCapacity: false)
        }
    }

    func track(_ event: AnalyticsEventName, context: AnalyticsEventContext?) {
        guard isCollectionEnabled else {
            #if DEBUG
            AppLog.analytics.debug(
                "Ignored event; name=\(event.rawValue, privacy: .public) reason=collection_disabled"
            )
            #endif
            return
        }

        queue.append(AnalyticsEvent(name: event, context: context, metadata: metadata))
        let overflowCount = max(queue.count - maximumQueueSize, 0)
        if queue.count > maximumQueueSize {
            queue.removeFirst(overflowCount)
        }

        #if DEBUG
        let source = context?.source?.rawValue ?? "none"
        let outcome = context?.outcome?.rawValue ?? "none"
        let reason = context?.reason?.rawValue ?? "none"
        AppLog.analytics.debug(
            "Queued event; name=\(event.rawValue, privacy: .public) source=\(source, privacy: .public) outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) deviceClass=\(self.metadata.deviceClass.rawValue, privacy: .public) queueDepth=\(self.queue.count, privacy: .public) evicted=\(overflowCount, privacy: .public)"
        )
        #endif

        scheduleDeliveryIfNeeded()
    }

    func flush() {
        #if DEBUG
        AppLog.analytics.debug(
            "Flush requested; queueDepth=\(self.queue.count, privacy: .public)"
        )
        #endif
        scheduleDeliveryIfNeeded()
    }

    func waitForPendingDelivery() async {
        await deliveryTask?.value
    }

    var pendingEventCount: Int {
        queue.count
    }

    private func scheduleDeliveryIfNeeded() {
        guard isCollectionEnabled, !queue.isEmpty, deliveryTask == nil else { return }

        deliveryGeneration &+= 1
        let generation = deliveryGeneration
        deliveryTask = Task { [weak self] in
            await self?.drainQueue(generation: generation)
        }
    }

    private func drainQueue(generation: Int) async {
        defer {
            if deliveryGeneration == generation {
                deliveryTask = nil
            }
        }

        while deliveryGeneration == generation,
              isCollectionEnabled,
              !queue.isEmpty,
              !Task.isCancelled {
            let batch = Array(queue.prefix(batchSize))

            #if DEBUG
            let eventNames = batch.map(\.event.rawValue).joined(separator: ",")
            AppLog.analytics.debug(
                "Sending batch; count=\(batch.count, privacy: .public) events=\(eventNames, privacy: .public)"
            )
            #endif

            var result = await transport.send(batch)

            #if DEBUG
            AppLog.analytics.debug(
                "Batch attempt finished; count=\(batch.count, privacy: .public) result=\(String(describing: result), privacy: .public)"
            )
            #endif

            guard deliveryGeneration == generation else { return }

            if result == .retry {
                for (retryIndex, delay) in retryDelays.enumerated() {
                    #if DEBUG
                    AppLog.analytics.debug(
                        "Batch retry scheduled; attempt=\(retryIndex + 1, privacy: .public) count=\(batch.count, privacy: .public)"
                    )
                    #endif

                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }

                    guard deliveryGeneration == generation,
                          isCollectionEnabled,
                          !Task.isCancelled else { return }

                    result = await transport.send(batch)

                    #if DEBUG
                    AppLog.analytics.debug(
                        "Batch retry finished; attempt=\(retryIndex + 1, privacy: .public) count=\(batch.count, privacy: .public) result=\(String(describing: result), privacy: .public)"
                    )
                    #endif

                    if result != .retry { break }
                }
            }

            guard deliveryGeneration == generation,
                  isCollectionEnabled else { return }

            // The bounded queue may evict an in-flight oldest event while the
            // network request is suspended. In that case, continue with the
            // current sanitized queue instead of removing unrelated events.
            guard Array(queue.prefix(batch.count)) == batch else { continue }

            switch result {
            case .accepted, .discard:
                queue.removeFirst(batch.count)

                #if DEBUG
                AppLog.analytics.debug(
                    "Batch removed from queue; count=\(batch.count, privacy: .public) result=\(String(describing: result), privacy: .public) remaining=\(self.queue.count, privacy: .public)"
                )
                #endif
            case .retry:
                #if DEBUG
                AppLog.analytics.debug(
                    "Batch retained after retries; count=\(batch.count, privacy: .public) remaining=\(self.queue.count, privacy: .public)"
                )
                #endif

                // Retain the batch for a later lifecycle flush without blocking UI.
                return
            }
        }
    }
}
