#!/usr/bin/env python3
"""Run permission-free transport/encoder diagnostics against current Swift sources.

This compiles the production Mac host and iOS transport on macOS, with synthetic
media, temporary device storage, and in-memory client credentials. It does not
capture the desktop or send input. Only the temporary host copy changes binding:
loopback, ephemeral port, no Bonjour advertisement. Results are not device FPS.
"""

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def declaration(path, start):
    """Extract an intact top-level declaration, including its nested braces."""
    source = (ROOT / path).read_text()
    begin = source.index(start)
    opening = source.index("{", begin)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[begin:end]


def main():
    host = "GlassyHost/Sources/GlassyHost/"
    client = "dejaview/Services/GlassyStream/"
    sources = [
        host + "Services/HostProtocol.swift",
        host + "Services/HostDeviceAccessStore.swift",
        host + "Services/PairingPasswordStore.swift",
        host + "Services/H264Encoder.swift",
        host + "Models/HostPairedDevice.swift",
        host + "Support/HostLog.swift",
        client + "GlassyStreamClient.swift",
        client + "GlassyStreamWire.swift",
        client + "GlassyStreamTypes.swift",
        client + "GlassyStreamRouteRace.swift",
        client + "GlassyStreamPairingPassword.swift",
        client + "GlassyStreamResumeCredentialStore.swift",
        "dejaview/Infrastructure/AppLog.swift",
        "script/performance/StreamAuditProbe.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="glassy-stream-audit-") as directory:
        work = Path(directory)
        # Keep these source declarations verbatim; avoid importing SwiftData/UI.
        support = "import Foundation\nimport Network\nimport CoreMedia\nimport CoreVideo\n"
        support += declaration("dejaview/Models/RemoteSessionTypes.swift", "enum RemoteSessionQuality:")
        support += "\n" + declaration(client + "GlassyStreamEndpoint.swift", "struct GlassyStreamDirectAddress:")
        support += "\n" + declaration(host + "Services/ScreenCaptureService.swift", "struct CapturedScreenFrame:")
        support += """
enum GlassyStreamEndpoint {
    static func isRecognizedTailscaleEndpoint(_ endpoint: NWEndpoint) -> Bool {
        preconditionFailure("Password-route discovery is outside this loopback probe")
    }
}
"""
        (work / "Support.swift").write_text(support)
        server = (ROOT / (host + "Services/HostServer.swift")).read_text()
        binding = "let parameters = NWParameters(tls: nil, tcp: tcpOptions)"
        assert server.count(binding) == 1
        server = server.replace(binding, binding + '\n                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)')
        advertisement = "listener.service = NWListener.Service(name: serviceName,\n                                                      type: HostProtocol.bonjourServiceType)"
        assert server.count(advertisement) == 1
        server = server.replace(advertisement, "// Probe is loopback-only; no advertisement.")
        (work / "HostServer.swift").write_text(server)
        binary = work / "stream-audit"
        subprocess.run(
            ["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
             *[str(ROOT / source) for source in sources],
             str(work / "Support.swift"), str(work / "HostServer.swift"),
             "-o", str(binary)], check=True, cwd=ROOT, timeout=180,
        )
        result = subprocess.run([str(binary), str(work)], check=True, text=True,
                                capture_output=True, timeout=60)
        print(json.dumps(json.loads(result.stdout), indent=2))


if __name__ == "__main__":
    main()
