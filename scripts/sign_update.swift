import Foundation
import CryptoKit

guard CommandLine.arguments.count >= 3 else {
    print("Usage: swift sign_update.swift <archive_path> <private_key_base64>")
    exit(1)
}

let archivePath = CommandLine.arguments[1]
let privKeyBase64 = CommandLine.arguments[2]

let archiveURL = URL(fileURLWithPath: archivePath)
guard let archiveData = try? Data(contentsOf: archiveURL) else {
    print("Error: Cannot read archive at \(archivePath)")
    exit(1)
}

guard let privKeyData = Data(base64Encoded: privKeyBase64),
      let privKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privKeyData) else {
    print("Error: Invalid base64 private key")
    exit(1)
}

do {
    let signature = try privKey.signature(for: archiveData)
    let sigBase64 = signature.base64EncodedString()
    let length = archiveData.count
    print("LENGTH: \(length)")
    print("ED_SIGNATURE: \(sigBase64)")
} catch {
    print("Error during signing: \(error)")
    exit(1)
}
