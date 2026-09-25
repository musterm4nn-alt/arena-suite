import ArchiveMCP
import Foundation

// Read-only MCP server for the local Arena Suite archive (plan v3 §14). stdout carries only
// JSON-RPC; diagnostics go to stderr and never include archive content.

let version = "1.0.0"

func archiveRoot() -> URL {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--archive-root"), arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Arena Suite/Archive", isDirectory: true)
}

if CommandLine.arguments.contains("--version") {
    print("arena-suite-mcp \(version)")
    exit(0)
}

let root = archiveRoot()
let tools: ArchiveTools?
let unavailable: String?
do {
    tools = try ArchiveTools.readOnly(archiveRoot: root)
    unavailable = nil
} catch {
    tools = nil
    unavailable = "The Arena Suite archive index at \(root.path) could not be opened read-only (\(error)). Open the Arena Suite app and sync once to create it."
    FileHandle.standardError.write(Data("arena-suite-mcp: \(unavailable!)\n".utf8))
}

await MCPServer(tools: tools, unavailable: unavailable, version: version)
    .serve(input: .standardInput, output: .standardOutput)
