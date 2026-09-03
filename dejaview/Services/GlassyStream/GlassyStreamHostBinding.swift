import Foundation

/// Saves route hints only after the encrypted connection has authenticated.
/// Every later route must still prove the same pinned host identity.
enum GlassyStreamHostBinding {
    static func applying(
        _ authentication: GlassyStreamAuthentication,
        to machine: SavedMachine,
        via candidate: GlassyStreamEndpointCandidate,
        knownAddresses: [GlassyStreamDirectAddress] = []
    ) throws -> SavedMachine {
        guard authentication.hostIdentifier.count == GlassyStreamWire.identifierLength else {
            throw GlassyStreamSessionError.transport(.protocolViolation("invalid authenticated host identity"))
        }
        let pinnedIdentifier = machine.glassyHostIdentifier.flatMap { Data(base64Encoded: $0) }
        if let pinnedIdentifier,
           pinnedIdentifier.count == GlassyStreamWire.identifierLength,
           pinnedIdentifier != authentication.hostIdentifier {
            throw GlassyStreamSessionError.transport(.hostIdentityMismatch)
        }
        if let invitationIdentifier = candidate.expectedHostIdentifier,
           invitationIdentifier != authentication.hostIdentifier {
            throw GlassyStreamSessionError.transport(.hostIdentityMismatch)
        }

        var result = machine
        result.glassyHostIdentifier = authentication.hostIdentifier.base64EncodedString()
        let name = authentication.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.glassyHostName = name.isEmpty ? candidate.name : name

        // Save the route that actually won, rather than the first address in
        // the QR code, which may belong to a LAN this device cannot reach.
        let connectedAddress = authentication.connectedAddress ?? candidate.directAddress
        if let connectedAddress {
            result.host = connectedAddress.host
            result.port = connectedAddress.port
        }

        let priorRoutes = pinnedIdentifier == authentication.hostIdentifier
            ? machine.glassyHostAddresses : []
        let priorAddresses = priorRoutes.compactMap {
            GlassyStreamEndpoint.directAddress(from: $0)
        }
        let routes = [connectedAddress].compactMap { $0 }
            + candidate.allDirectAddresses + knownAddresses + priorAddresses
        var seen = Set<String>()
        result.glassyHostAddresses = routes.compactMap { route in
            guard let validated = GlassyStreamEndpoint.directAddress(from: route.displayValue),
                  seen.insert(validated.displayValue.lowercased()).inserted else { return nil }
            return validated.displayValue
        }.prefix(8).map { $0 }
        return result
    }
}
