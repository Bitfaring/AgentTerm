import Foundation

/// AgentTerm's MCP server, as an agent's session starts it.
final class MCPServerProcess {
    let process = Process()
    private let input = Pipe()
    private var output = Data()
    private let lock = NSLock()
    private var next = 0

    init(tool: URL, variable: String, state: URL) throws {
        process.executableURL = tool
        process.arguments = ["mcp"]
        var environment = MacUITestCase.withoutAgentTerms
        environment["AGENTTERM_MCP"] = variable
        environment["AGENTTERM_STATE_DIR"] = state.path
        process.environment = environment
        process.standardInput = input
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.output.append(data)
            self.lock.unlock()
        }
        try process.run()
    }

    /// Calls a tool and waits for its answer: its content, and whether it failed.
    func tool(_ name: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 60) -> (content: [[String: Any]], failed: Bool) {
        next += 1
        let id = next
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        input.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: request)) ?? Data())
        input.fileHandleForWriting.write(Data("\n".utf8))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
            lock.unlock()
            for line in lines {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], object["id"] as? Int == id else { continue }
                let result = object["result"] as? [String: Any] ?? [:]
                return (result["content"] as? [[String: Any]] ?? [], result["isError"] as? Bool ?? true)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return ([["type": "text", "text": "no answer in \(Int(timeout)) seconds"]], true)
    }

    func text(_ name: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 60) -> (text: String, failed: Bool) {
        let answer = tool(name, arguments, timeout: timeout)
        let text = answer.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, answer.failed)
    }

    func stop() { process.terminate() }
}
