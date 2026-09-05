import Foundation

@main
enum GlassyHostMain {
    @MainActor
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], HostPermissionStatusProbe.argument] {
            let snapshot = HostPermissionStatusProbe.currentProcessSnapshot()
            if let data = try? JSONEncoder().encode(snapshot) {
                FileHandle.standardOutput.write(data)
            }
            return
        }
        GlassyHostApp.main()
    }
}
