import Foundation
import CryptoKit
// Public-key-only verification; no Keychain or private-key access.
guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let rawKey = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update <archive> <base64-signature> <base64-public-key>\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fputs("Update signature INVALID\n", stderr); exit(1)
    }
    print("Update signature verified.")
} catch { fputs("Verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
