import Foundation

public enum CaptureSandbox {
    public static let executable = "/usr/bin/sandbox-exec"

    public static func profile(port: UInt16, unixSockets: [String] = []) throws -> String {
        guard unixSockets.allSatisfy({ path in
            !path.contains("\"") && !path.contains("\\") && !path.contains("\n") && !path.utf8.contains(0)
        }) else { throw CaptureError.sandboxUnavailable }
        let lines = [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(allow network-outbound (remote ip \"localhost:\(port)\"))"
        ] + unixSockets.map { "(allow network-outbound (remote unix-socket (path-literal \"\($0)\")))" }
        return lines.joined(separator: "\n")
    }

    public static func wrap(_ argv: [String], port: UInt16, unixSockets: [String]) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: executable), !argv.isEmpty else {
            throw CaptureError.sandboxUnavailable
        }
        return [executable, "-p", try profile(port: port, unixSockets: unixSockets)] + argv
    }

    public static func verify(port: UInt16, unixSockets: [String]) async throws {
        do {
            let argv = try wrap(["/usr/bin/true"], port: port, unixSockets: unixSockets)
            let handle = try SpawnLauncher().launch(
                argv: argv, environment: CaptureEnvironment.sanitized(ProcessInfo.processInfo.environment), cwd: NSTemporaryDirectory()
            )
            let status = await withTaskCancellationHandler {
                await handle.exitStatus()
            } onCancel: {
                Task { await handle.terminate() }
            }
            await handle.terminate()
            guard status == 0, !Task.isCancelled else { throw CaptureError.sandboxUnavailable }
        } catch {
            throw CaptureError.sandboxUnavailable
        }
    }
}
