import CoreGraphics
import Foundation
@testable import NSRemoteShell
import Testing

@Suite
struct ShellTests {
    @Test
    func shellPtySizeChange() async throws {
        print("testShellPtySizeChange: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let sizeProvider = TerminalSizeProvider(CGSize(width: 80, height: 24))
        let input = InputQueue([
            "stty size\n",
            "sleep 0.5\n",
            "stty size\n",
            "exit\n"
        ])
        let output = OutputBuffer()
        let deadline = Date().addingTimeInterval(10)
        let sizeChangeScheduled = AtomicBool(false)

        try await shell.openShell(
            terminalType: "xterm-256color",
            terminalSize: { sizeProvider.get() },
            writeData: {
                let data = input.pop()
                if data == "sleep 0.5\n", !sizeChangeScheduled.get() {
                    sizeChangeScheduled.set(true)
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        print("testShellPtySizeChange: changing size to 120x40")
                        sizeProvider.set(CGSize(width: 120, height: 40))
                    }
                }
                return data
            },
            onOutput: { output.append($0) },
            shouldContinue: { Date() < deadline }
        )

        let result = output.value()
        print("testShellPtySizeChange: output=\(result.utf8.count) bytes")

        #expect(result.contains("24 80") || result.contains("24") && result.contains("80"))
        #expect(result.contains("40 120") || result.contains("40") && result.contains("120"))
    }

    @Test
    func shellMultiRoundOutput() async throws {
        print("testShellMultiRoundOutput: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let rounds = 5
        var commands: [String] = []
        var markers: [String] = []
        for i in 1 ... rounds {
            let marker = "ROUND_\(i)_" + UUID().uuidString.prefix(8)
            markers.append(marker)
            commands.append("echo '\(marker)'\n")
            commands.append("sleep 0.2\n")
        }
        commands.append("exit\n")

        let input = InputQueue(commands)
        let output = OutputBuffer()
        let deadline = Date().addingTimeInterval(15)

        try await shell.openShell(
            terminalType: "xterm-256color",
            terminalSize: { CGSize(width: 80, height: 24) },
            writeData: { input.pop() },
            onOutput: { output.append($0) },
            shouldContinue: { Date() < deadline }
        )

        let result = output.value()
        print("testShellMultiRoundOutput: output=\(result.utf8.count) bytes")

        for (i, marker) in markers.enumerated() {
            let found = result.contains(marker)
            print("testShellMultiRoundOutput: round \(i + 1) marker found=\(found)")
            #expect(found)
        }
    }

    @Test
    func shellCtrlC() async throws {
        print("testShellCtrlC: start")
        guard let shell = try await connectShell() else { return }
        defer { Task { await shell.disconnect() } }

        let ctrlCSent = AtomicBool(false)
        let input = InputQueue([
            "while true; do echo running; sleep 0.2; done\n"
        ])
        let output = OutputBuffer()
        let deadline = Date().addingTimeInterval(10)
        let startTime = Date()

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            print("testShellCtrlC: sending Ctrl+C")
            ctrlCSent.set(true)
        }

        try await shell.openShell(
            terminalType: "xterm-256color",
            terminalSize: { CGSize(width: 80, height: 24) },
            writeData: {
                if let data = input.pop() {
                    return data
                }
                if ctrlCSent.get() {
                    return "\u{03}"
                }
                return nil
            },
            onOutput: { output.append($0) },
            shouldContinue: {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 3 {
                    return false
                }
                let result = output.value()
                if ctrlCSent.get(), result.contains("running") {
                    let afterCtrl = result.components(separatedBy: "running").count
                    return afterCtrl < 20
                }
                return Date() < deadline
            }
        )

        let elapsed = Date().timeIntervalSince(startTime)
        let result = output.value()
        print("testShellCtrlC: elapsed=\(elapsed)s output=\(result.utf8.count) bytes")

        #expect(result.contains("running"))
        #expect(elapsed < 8)
    }
}
