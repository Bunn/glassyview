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


def declaration(path, start, source=None):
    """Extract an intact top-level declaration, including its nested braces."""
    source = (ROOT / path).read_text() if source is None else source
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
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--scenario", choices=["healthy-best", "slow-bootstrap", "regression", "codec-ordering"])
    selection.add_argument("--compatibility", choices=["legacy-client", "legacy-host", "released-client", "released-host"],
                           help="Test a historical peer against the current other peer; released-* snapshots the entire transport")
    parser.add_argument("--legacy-revision",
                        help="Historical peer's Git revision; required for released-*, defaults to the pre-adaptive commit for legacy-*")
    args = parser.parse_args()
    released = args.compatibility in ("released-client", "released-host")
    if released and not args.legacy_revision:
        parser.error("released-* requires --legacy-revision for the released peer")
    args.legacy_revision = args.legacy_revision or "485335bc393c173d5f6e39cd5ef73932036ee6fa"
    if args.compatibility:
        args.legacy_revision = subprocess.run(
            ["git", "rev-parse", "--verify", "--end-of-options", args.legacy_revision + "^{commit}"],
            cwd=ROOT, check=True, text=True, capture_output=True,
        ).stdout.strip()
    host = "GlassyHost/Sources/GlassyHost/"
    client = "dejaview/Services/GlassyStream/"

    def source_text(path):
        historical = (
            args.compatibility == "released-host" and path.startswith(host)
            or args.compatibility == "released-client" and (
                path.startswith(client)
                or path in ("dejaview/Models/RemoteSessionTypes.swift", "dejaview/Infrastructure/AppLog.swift")
            )
            or args.compatibility == "legacy-client" and path == client + "GlassyStreamClient.swift"
            or args.compatibility == "legacy-host" and path in (
                host + "Services/HostProtocol.swift", host + "Services/HostServer.swift"
            )
        )
        if historical:
            return subprocess.run(["git", "show", args.legacy_revision + ":" + path], cwd=ROOT,
                                  check=True, text=True, capture_output=True).stdout
        return (ROOT / path).read_text()

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
        "script/performance/ReleasedPeerCompatibilityProbe.swift" if released else (
            "script/performance/StreamCompatibilityProbe.swift" if args.compatibility else "script/performance/StreamAuditProbe.swift"
        ),
    ]
    with tempfile.TemporaryDirectory(prefix="glassy-stream-audit-") as directory:
        work = Path(directory)
        # Keep these source declarations verbatim; avoid importing SwiftData/UI.
        support = "import Foundation\nimport Network\nimport CoreMedia\nimport CoreVideo\n"
        for path, start in [
            ("dejaview/Models/RemoteSessionTypes.swift", "enum RemoteSessionQuality:"),
            (client + "GlassyStreamEndpoint.swift", "struct GlassyStreamDirectAddress:"),
            (host + "Services/ScreenCaptureService.swift", "struct CapturedScreenFrame:"),
            (host + "Services/ScreenCaptureService.swift", "struct ScreenCaptureConfiguration:"),
        ]:
            support += "\n" + declaration(path, start, source_text(path))
        support += """
enum GlassyStreamEndpoint {
    static func isRecognizedTailscaleEndpoint(_ endpoint: NWEndpoint) -> Bool {
        preconditionFailure("Password-route discovery is outside this loopback probe")
    }
}
"""
        (work / "Support.swift").write_text(support)
        server = source_text(host + "Services/HostServer.swift")
        binding = "let parameters = NWParameters(tls: nil, tcp: tcpOptions)"
        assert server.count(binding) == 1
        server = server.replace(binding, binding + '\n                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)')
        advertisement = "listener.service = NWListener.Service(name: serviceName,\n                                                      type: HostProtocol.bonjourServiceType)"
        assert server.count(advertisement) == 1
        server = server.replace(advertisement, "// Probe is loopback-only; no advertisement.")
        (work / "HostServer.swift").write_text(server)
        # Snapshot the source list before compilation: parallel UI work must
        # not invalidate a long Swift frontend read midway through this probe.
        snapshots = []
        for index, source in enumerate(sources):
            snapshot = work / (str(index) + "-" + Path(source).name)
            snapshot.write_text(source_text(source))
            snapshots.append(snapshot)
        compile_sources = snapshots
        binary = work / "stream-audit"
        # Match the app's Release compilation mode, including when both peers
        # share one diagnostic module. Swift 6.4's per-file -O build rejects valid
        # pairing codes here; debug and whole-module builds agree on the result.
        subprocess.run(
            ["xcrun", "swiftc", "-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
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
            if args.compatibility:
                reports[scenario or "audit"]["historical_peer_revision"] = args.legacy_revision
        print(json.dumps(reports if len(reports) > 1 else next(iter(reports.values())), indent=2))


if __name__ == "__main__":
    main()
