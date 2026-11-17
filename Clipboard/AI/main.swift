import Foundation

guard FileManager.default.fileExists(atPath: ClipboardPaths.mcpEnableFlag) else { exit(0) }

let handler = MCPHandler()

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    autoreleasepool {
        guard let response = handler.handle(line: line) else { return }
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
