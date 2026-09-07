#!/usr/bin/env python3
"""Run permission-free transport/encoder diagnostics against current Swift sources.

This compiles the production Mac host and iOS transport on macOS, with synthetic
media, temporary device storage, and in-memory client credentials. It does not
capture the desktop or send input. Only the temporary host copy changes binding:
loopback, ephemeral port, no Bonjour advertisement. Results are not device FPS.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
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
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=["healthy-best", "slow-bootstrap", "regression"])
    parser.add_argument("--compatibility", choices=["legacy-client", "legacy-host"],
                        help="Compile the selected peer's pre-adaptive committed source against the current other peer")
    parser.add_argument("--legacy-revision", default="485335bc393c173d5f6e39cd5ef73932036ee6fa",
                        help="Pre-adaptive commit used for compatibility peers")
    args = parser.parse_args()
    host = "GlassyHost/Sources/GlassyHost/"
    client = "dejaview/Services/GlassyStream/"
    sources = [
        host + "Services/HostProtocol.swift",
        host + "Services/HostDeviceAccessStore.swift",
        host + "Services/PairingPasswordStore.swift",
        host + "Services/H264Encoder.swift",
        host + "Models/HostAdaptiveStreamPolicy.swift",
        host + "Models/HostStreamQualityConfiguration.swift",
        host + "Models/HostPairedDevice.swift",
        host + "Support/HostLog.swift",
        client + "GlassyStreamClient.swift",
        client + "GlassyStreamEventDelivery.swift",
        client + "GlassyStreamWire.swift",
        client + "GlassyStreamTypes.swift",
        client + "GlassyStreamRouteRace.swift",
        client + "GlassyStreamPairingPassword.swift",
        client + "GlassyStreamResumeCredentialStore.swift",
        "dejaview/Infrastructure/AppLog.swift",
        "script/performance/StreamCompatibilityProbe.swift" if args.compatibility else "script/performance/StreamAuditProbe.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="glassy-stream-audit-") as directory:
        work = Path(directory)
        # Keep these source declarations verbatim; avoid importing SwiftData/UI.
        support = "import Foundation\nimport Network\nimport CoreMedia\nimport CoreVideo\n"
        support += declaration("dejaview/Models/RemoteSessionTypes.swift", "enum RemoteSessionQuality:")
        support += "\n" + declaration(client + "GlassyStreamEndpoint.swift", "struct GlassyStreamDirectAddress:")
        support += "\n" + declaration(host + "Services/ScreenCaptureService.swift", "struct CapturedScreenFrame:")
        support += "\n" + declaration(host + "Services/ScreenCaptureService.swift", "struct ScreenCaptureConfiguration:")
        support += """
enum GlassyStreamEndpoint {
    static func isRecognizedTailscaleEndpoint(_ endpoint: NWEndpoint) -> Bool {
        preconditionFailure("Password-route discovery is outside this loopback probe")
    }
}
"""
        (work / "Support.swift").write_text(support)
        compile_sources = [ROOT / source for source in sources]
        def committed_source(source):
            return subprocess.run(["git", "show", args.legacy_revision + ":" + source], cwd=ROOT,
                                  check=True, text=True, capture_output=True).stdout
        legacy_sources = []
        if args.compatibility == "legacy-client":
            legacy_sources = [client + "GlassyStreamClient.swift"]
        elif args.compatibility == "legacy-host":
            legacy_sources = [host + "Services/HostProtocol.swift"]
        for source in legacy_sources:
            legacy = work / ("Legacy" + Path(source).name)
            legacy.write_text(committed_source(source))
            compile_sources[compile_sources.index(ROOT / source)] = legacy
        server = (committed_source(host + "Services/HostServer.swift") if args.compatibility == "legacy-host"
                  else (ROOT / (host + "Services/HostServer.swift")).read_text())
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
             *[str(source) for source in compile_sources],
             str(work / "Support.swift"), str(work / "HostServer.swift"),
             "-o", str(binary)], check=True, cwd=ROOT, timeout=180,
        )
        scenarios = ["healthy-best", "slow-bootstrap"] if args.scenario == "regression" else [args.compatibility or args.scenario]
        reports = {}
        for scenario in scenarios:
            probe_args = [str(binary), str(work)] + ([scenario] if scenario else [])
            result = subprocess.run(probe_args, text=True, capture_output=True, timeout=120)
            if result.returncode:
                print(result.stdout, file=sys.stderr)
                print(result.stderr, file=sys.stderr)
                result.check_returncode()
            reports[scenario or "audit"] = json.loads(result.stdout)
        print(json.dumps(reports if len(reports) > 1 else next(iter(reports.values())), indent=2))


if __name__ == "__main__":
    main()
