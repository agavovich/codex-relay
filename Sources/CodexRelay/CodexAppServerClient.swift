import Foundation

enum CodexClientError: LocalizedError {
    case executableNotFound
    case profileHomeMissing(String)
    case launchFailed(String)
    case timedOut
    case loginRequiresIsolatedProfile
    case invalidLoginURL
    case loginFailed(String)
    case malformedResponse
    case server(String)
    case exited(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex executable not found. Install or launch ChatGPT/Codex."
        case .profileHomeMissing(let path):
            return "Codex profile directory not found: \(path)"
        case .launchFailed(let message):
            return "Could not launch Codex: \(message)"
        case .timedOut:
            return "Codex did not respond in time."
        case .loginRequiresIsolatedProfile:
            return "Additional accounts require an isolated Codex profile."
        case .invalidLoginURL:
            return "Codex returned an invalid sign-in URL."
        case .loginFailed(let message):
            return message.isEmpty ? "ChatGPT sign-in failed." : "ChatGPT sign-in failed: \(message)"
        case .malformedResponse:
            return "Codex returned an unknown response format."
        case .server(let message):
            return "Codex: \(message)"
        case .exited(let message):
            return message.isEmpty ? "Codex exited before returning rate limits." : message
        }
    }
}

final class CodexAppServerClient {
    private let fileManager = FileManager.default

    func fetchAccountUsage(
        for profile: AccountProfile = .current,
        timeout: TimeInterval = 15
    ) throws -> AccountUsageResult {
        let process = Process()
        process.executableURL = try locateCodexExecutable()
        process.arguments = ["app-server", "--stdio"]

        process.environment = try environment(for: profile)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stateQueue = DispatchQueue(label: "app.codex-relay.rpc-state")
        let completion = DispatchSemaphore(value: 0)
        var outputBuffer = Data()
        var errorBuffer = Data()
        var accountResult: AccountReadResult?
        var rateLimitsResult: RateLimitsResult?
        var finalResult: Swift.Result<AccountUsageResult, Error>?

        func finishLocked(_ result: Swift.Result<AccountUsageResult, Error>) {
            guard finalResult == nil else { return }
            finalResult = result
            completion.signal()
        }

        func finishIfCompleteLocked() {
            guard let accountResult, let rateLimitsResult else { return }
            finishLocked(.success(AccountUsageResult(
                account: accountResult.account,
                requiresOpenaiAuth: accountResult.requiresOpenaiAuth,
                rateLimits: rateLimitsResult
            )))
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else { return }

            stateQueue.async {
                outputBuffer.append(incoming)

                while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
                    let line = outputBuffer.subdata(in: outputBuffer.startIndex..<newline.lowerBound)
                    outputBuffer.removeSubrange(outputBuffer.startIndex..<newline.upperBound)

                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let responseId = object["id"] as? NSNumber else {
                        continue
                    }

                    do {
                        switch responseId.intValue {
                        case 1:
                            let response = try JSONDecoder().decode(
                                RPCResponse<AccountReadResult>.self,
                                from: line
                            )
                            if let error = response.error {
                                finishLocked(.failure(CodexClientError.server(error.message)))
                            } else if let result = response.result {
                                accountResult = result
                                finishIfCompleteLocked()
                            } else {
                                finishLocked(.failure(CodexClientError.malformedResponse))
                            }
                        case 2:
                            let response = try JSONDecoder().decode(
                                RPCResponse<RateLimitsResult>.self,
                                from: line
                            )
                            if let error = response.error {
                                finishLocked(.failure(CodexClientError.server(error.message)))
                            } else if let result = response.result {
                                rateLimitsResult = result
                                finishIfCompleteLocked()
                            } else {
                                finishLocked(.failure(CodexClientError.malformedResponse))
                            }
                        default:
                            continue
                        }
                    } catch {
                        finishLocked(.failure(error))
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else { return }
            stateQueue.async {
                errorBuffer.append(incoming)
            }
        }

        process.terminationHandler = { _ in
            stateQueue.async {
                guard finalResult == nil else { return }
                let details = String(data: errorBuffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                finishLocked(.failure(CodexClientError.exited(details)))
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexClientError.launchFailed(error.localizedDescription)
        }

        let clientVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.6.2"
        let initializeMessage = [
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "codex_relay",
                    "title": "Codex Relay",
                    "version": clientVersion
                ]
            ]
        ] as [String: Any]
        let initializeData = try JSONSerialization.data(withJSONObject: initializeMessage)
        guard let initializeLine = String(data: initializeData, encoding: .utf8) else {
            cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw CodexClientError.malformedResponse
        }

        let messages = [
            initializeLine,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/read","id":1,"params":{"refreshToken":false}}"#,
            #"{"method":"account/rateLimits/read","id":2}"#
        ].joined(separator: "\n") + "\n"

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
        } catch {
            cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw CodexClientError.launchFailed(error.localizedDescription)
        }

        let waitResult = completion.wait(timeout: .now() + timeout)
        let result = stateQueue.sync { finalResult }
        cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)

        guard waitResult == .success else {
            throw CodexClientError.timedOut
        }
        guard let result else {
            throw CodexClientError.malformedResponse
        }
        return try result.get()
    }

    func fetchRateLimits(
        for profile: AccountProfile = .current,
        timeout: TimeInterval = 15
    ) throws -> RateLimitsResult {
        try fetchAccountUsage(for: profile, timeout: timeout).rateLimits
    }

    func loginWithChatGPT(
        for profile: AccountProfile,
        timeout: TimeInterval = 300,
        openURL: @escaping @Sendable (URL) -> Void
    ) throws {
        guard !profile.usesCurrentCodexHome else {
            throw CodexClientError.loginRequiresIsolatedProfile
        }

        let process = Process()
        process.executableURL = try locateCodexExecutable()
        process.arguments = ["app-server", "--stdio"]
        process.environment = try environment(for: profile)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stateQueue = DispatchQueue(label: "app.codex-relay.login-state")
        let authReady = DispatchSemaphore(value: 0)
        let completion = DispatchSemaphore(value: 0)
        var outputBuffer = Data()
        var errorBuffer = Data()
        var authURL: URL?
        var expectedLoginID: String?
        var startupError: Error?
        var finalResult: Swift.Result<Void, Error>?
        var authWasSignaled = false

        func signalAuthLocked() {
            guard !authWasSignaled else { return }
            authWasSignaled = true
            authReady.signal()
        }

        func finishLocked(_ result: Swift.Result<Void, Error>) {
            guard finalResult == nil else { return }
            finalResult = result
            completion.signal()
        }

        func failLocked(_ error: Error) {
            if authURL == nil, startupError == nil {
                startupError = error
                signalAuthLocked()
            }
            finishLocked(.failure(error))
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else { return }

            stateQueue.async {
                outputBuffer.append(incoming)

                while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
                    let line = outputBuffer.subdata(in: outputBuffer.startIndex..<newline.lowerBound)
                    outputBuffer.removeSubrange(outputBuffer.startIndex..<newline.upperBound)

                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        continue
                    }

                    if let responseID = object["id"] as? NSNumber,
                       responseID.intValue == 1 {
                        if let error = object["error"] as? [String: Any] {
                            let message = error["message"] as? String ?? "Unknown server error"
                            failLocked(CodexClientError.server(message))
                            continue
                        }

                        guard let result = object["result"] as? [String: Any],
                              let urlString = result["authUrl"] as? String,
                              let url = URL(string: urlString) else {
                            failLocked(CodexClientError.invalidLoginURL)
                            continue
                        }

                        authURL = url
                        expectedLoginID = result["loginId"] as? String
                        signalAuthLocked()
                        continue
                    }

                    guard object["method"] as? String == "account/login/completed",
                          let params = object["params"] as? [String: Any] else {
                        continue
                    }

                    let completedLoginID = params["loginId"] as? String
                    if let expectedLoginID,
                       let completedLoginID,
                       completedLoginID != expectedLoginID {
                        continue
                    }

                    if params["success"] as? Bool == true {
                        finishLocked(.success(()))
                    } else {
                        let message = params["error"] as? String ?? ""
                        failLocked(CodexClientError.loginFailed(message))
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else { return }
            stateQueue.async {
                errorBuffer.append(incoming)
            }
        }

        process.terminationHandler = { _ in
            stateQueue.async {
                guard finalResult == nil else { return }
                let details = String(data: errorBuffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                failLocked(CodexClientError.exited(details))
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexClientError.launchFailed(error.localizedDescription)
        }

        let messages = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codex_relay","title":"Codex Relay","version":"0.3.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/login/start","id":1,"params":{"type":"chatgpt","useHostedLoginSuccessPage":true,"appBrand":"codex"}}"#
        ].joined(separator: "\n") + "\n"

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
        } catch {
            cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw CodexClientError.launchFailed(error.localizedDescription)
        }

        let startupWait = authReady.wait(timeout: .now() + min(15, timeout))
        let startup = stateQueue.sync { (authURL, startupError) }

        guard startupWait == .success else {
            cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw CodexClientError.timedOut
        }
        if let startupError = startup.1 {
            cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw startupError
        }
        guard let loginURL = startup.0 else {
            cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw CodexClientError.invalidLoginURL
        }

        openURL(loginURL)

        let completionWait = completion.wait(timeout: .now() + timeout)
        let result = stateQueue.sync { finalResult }
        cleanup(process: process, input: inputPipe, output: outputPipe, error: errorPipe)

        guard completionWait == .success else {
            throw CodexClientError.timedOut
        }
        guard let result else {
            throw CodexClientError.malformedResponse
        }
        try result.get()
        secureCredentialFile(for: profile)
    }

    private func environment(for profile: AccountProfile) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let currentPath = environment["PATH"], !currentPath.isEmpty {
            environment["PATH"] = currentPath + ":" + fallbackPath
        } else {
            environment["PATH"] = fallbackPath
        }

        if let configuredHome = profile.codexHomePath {
            let expandedHome = (configuredHome as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: expandedHome, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CodexClientError.profileHomeMissing(expandedHome)
            }
            environment["CODEX_HOME"] = expandedHome
        }

        return environment
    }

    private func secureCredentialFile(for profile: AccountProfile) {
        guard let codexHomePath = profile.codexHomePath else { return }
        let authPath = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("auth.json")
            .path
        guard fileManager.fileExists(atPath: authPath) else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
    }

    private func locateCodexExecutable() throws -> URL {
        var candidates: [String] = []

        if let configured = ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"],
           !configured.isEmpty {
            candidates.append(configured)
        }

        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        throw CodexClientError.executableNotFound
    }

    private func cleanup(process: Process, input: Pipe, output: Pipe, error: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()

        if process.isRunning {
            process.terminate()
        }
    }
}
