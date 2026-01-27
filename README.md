# NSRemoteShell

Swift Concurrency-first SSH client built on libssh2 with kqueue-driven socket waits for lower power usage.

## Usage

```swift
import NSRemoteShell

let shell = NSRemoteShell(host: "example.com")
try await shell.connect()
try await shell.authenticate(username: "user", password: "secret")

let exitCode = try await shell.execute("uptime") { output in
    print(output)
}

await shell.disconnect()
```

## Shell Session

```swift
try await shell.openShell(
    terminalType: "xterm-256color",
    terminalSize: { CGSize(width: 120, height: 40) },
    writeData: { readNextInputChunk() },
    onOutput: { print($0) }
)
```

## Port Forwarding

```swift
let handle = try await shell.startLocalPortForward(
    localPort: 8080,
    targetHost: "127.0.0.1",
    targetPort: 80
)

// ...
await handle.cancel()
```

## File Transfer (SFTP/SCP)

```swift
try await shell.connectSFTP()

let files = try await shell.listFiles(at: "/var/log")
let info = try await shell.fileInfo(at: "/var/log/system.log")

try await shell.uploadFile(
    at: "/tmp/local.log",
    to: "/tmp",
    onProgress: { progress, speed in
        print(progress.fractionCompleted, speed)
    }
)

try await shell.downloadFile(
    at: "/var/log/system.log",
    to: "/tmp/system.log",
    onProgress: { progress, speed in
        print(progress.fractionCompleted, speed)
    }
)
```

## License

MIT (Lakr's Edition).
