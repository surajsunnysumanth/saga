import Foundation
import SagaCore

// saga-mcp --index <vault_index.db> [--config mcp.json]
// Speaks MCP over stdio (one JSON message per line). Read-only. Logs go to stderr only.
let args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let defaultIndex = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Saga/vault_index.db").path
let indexPath = opt("--index") ?? defaultIndex
guard FileManager.default.fileExists(atPath: indexPath) else {
    FileHandle.standardError.write(Data("saga-mcp: index not found at \(indexPath). Open Saga once to build your library.\n".utf8)); exit(1)
}
let server: MCPServer
do { server = try MCPServer(indexPath: indexPath, config: .load(opt("--config"))) }
catch { FileHandle.standardError.write(Data("saga-mcp: \(error)\n".utf8)); exit(1) }
while let line = readLine() {
    if let out = server.handle(line: line) { print(out); fflush(stdout) }
}
