import Foundation
@testable import NSRemoteShell
import Testing

@Suite
struct CommandTests {
    @Test
    func commandExitCodeNonZero() async throws {
        print("testCommandExitCodeNonZero: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let (status1, _) = try await executeCapture(shell, "exit 0")
        print("testCommandExitCodeNonZero: exit 0 status=\(status1)")
        #expect(status1 == 0)

        let (status2, _) = try await executeCapture(shell, "exit 1")
        print("testCommandExitCodeNonZero: exit 1 status=\(status2)")
        #expect(status2 == 1)

        let (status3, _) = try await executeCapture(shell, "exit 42")
        print("testCommandExitCodeNonZero: exit 42 status=\(status3)")
        #expect(status3 == 42)

        let (status4, _) = try await executeCapture(shell, "exit 255")
        print("testCommandExitCodeNonZero: exit 255 status=\(status4)")
        #expect(status4 == 255)
    }

    @Test
    func commandStdoutComplete() async throws {
        print("testCommandStdoutComplete: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let lineCount = 1000
        let (status, output) = try await executeCapture(
            shell,
            "seq 1 \(lineCount)"
        )
        print("testCommandStdoutComplete: status=\(status) outputLines=\(output.components(separatedBy: "\n").count)")

        #expect(status == 0)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        #expect(lines.count == lineCount)
        #expect(lines.first == "1")
        #expect(lines.last == "\(lineCount)")
    }

    @Test
    func commandStderrComplete() async throws {
        print("testCommandStderrComplete: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let payload = "NSREMOTE_STDERR_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let stdoutPayload = "NSREMOTE_STDOUT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let command = "echo '\(stdoutPayload)' && echo '\(payload)' >&2"
        let (status, output) = try await executeCapture(shell, command)
        print("testCommandStderrComplete: status=\(status) output=\(output.utf8.count) bytes")

        #expect(status == 0)
        #expect(output.contains(payload))
        #expect(output.contains(stdoutPayload))
    }

    @Test
    func commandLargeOutput() async throws {
        print("testCommandLargeOutput: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let sizeKB = 512
        let (status, output) = try await executeCapture(
            shell,
            "dd if=/dev/zero bs=1024 count=\(sizeKB) 2>/dev/null | base64",
            timeout: 30
        )
        print("testCommandLargeOutput: status=\(status) outputBytes=\(output.utf8.count)")

        #expect(status == 0)
        let expectedMinSize = sizeKB * 1024 * 4 / 3 - 100
        #expect(output.utf8.count >= expectedMinSize)
    }

    @Test
    func commandCancelChannel() async throws {
        print("testCommandCancelChannel: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let cancelled = AtomicBool(false)
        let output = OutputBuffer()
        let startTime = Date()

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("testCommandCancelChannel: setting cancel flag")
            cancelled.set(true)
        }

        let status = try await shell.execute(
            "for i in $(seq 1 100); do echo \"line $i\"; sleep 0.05; done",
            timeout: 30,
            onOutput: { output.append($0) },
            shouldContinue: { !cancelled.get() }
        )

        let elapsed = Date().timeIntervalSince(startTime)
        print("testCommandCancelChannel: status=\(status) elapsed=\(elapsed)s outputBytes=\(output.count())")

        #expect(elapsed < 10)
        #expect(output.count() > 0)
    }
}
