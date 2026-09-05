import CryptoKit
import Foundation
import Security

enum SigningToolError: Error {
    case usage
    case invalidKey
    case invalidSignature
    case keychainItemExists
    case keychainItemMissing
    case keychainFailure(OSStatus)
}

// The signing key lives in the login keychain as a generic password whose data
// is the 32 raw Ed25519 bytes. Every channel catalog is signed by this one
// long-lived key, so a shipped app can accept catalogs published after it.
let keychainAccount = "omarchy"

func keychainQuery(service: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keychainAccount,
    ]
}

func loadKeychainKey(service: String) throws -> Curve25519.Signing.PrivateKey {
    var query = keychainQuery(service: service)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status != errSecItemNotFound else {
        throw SigningToolError.keychainItemMissing
    }
    guard status == errSecSuccess else {
        throw SigningToolError.keychainFailure(status)
    }
    guard let raw = item as? Data,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else {
        throw SigningToolError.invalidKey
    }
    return key
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    throw SigningToolError.usage
}

switch arguments[1] {
case "generate":
    guard arguments.count == 4 else {
        throw SigningToolError.usage
    }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: arguments[2]
    )
    try key.publicKey.rawRepresentation.write(
        to: URL(fileURLWithPath: arguments[3]),
        options: .atomic
    )

case "sign":
    guard arguments.count == 5 else {
        throw SigningToolError.usage
    }
    let rawKey = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
        throw SigningToolError.invalidKey
    }
    let message = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
    let signature = try key.signature(for: message)
    try signature.write(to: URL(fileURLWithPath: arguments[4]), options: .atomic)

case "verify":
    guard arguments.count == 5 else {
        throw SigningToolError.usage
    }
    let rawPublicKey = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey) else {
        throw SigningToolError.invalidKey
    }
    let message = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
    let signature = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
    guard publicKey.isValidSignature(signature, for: message) else {
        throw SigningToolError.invalidSignature
    }
    print("catalog_signature=passed")

case "import-keychain":
    guard arguments.count == 4 else {
        throw SigningToolError.usage
    }
    let rawKey = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) else {
        throw SigningToolError.invalidKey
    }
    let service = arguments[3]
    var attributes = keychainQuery(service: service)
    attributes[kSecValueData as String] = key.rawRepresentation
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    // Never silently replace an existing signing key: overwriting it would
    // strand every app already built against the old public key.
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status != errSecDuplicateItem else {
        throw SigningToolError.keychainItemExists
    }
    guard status == errSecSuccess else {
        throw SigningToolError.keychainFailure(status)
    }
    let fingerprint = SHA256.hash(data: key.publicKey.rawRepresentation)
        .map { String(format: "%02x", $0) }
        .joined()
    print("keychain_service=\(service)")
    print("trust_root_fingerprint=sha256:\(fingerprint)")

case "sign-keychain":
    guard arguments.count == 5 else {
        throw SigningToolError.usage
    }
    let key = try loadKeychainKey(service: arguments[2])
    let message = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
    let signature = try key.signature(for: message)
    try signature.write(to: URL(fileURLWithPath: arguments[4]), options: .atomic)

case "public-key-keychain":
    guard arguments.count == 4 else {
        throw SigningToolError.usage
    }
    let key = try loadKeychainKey(service: arguments[2])
    let publicKey = key.publicKey.rawRepresentation
    try publicKey.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
    let fingerprint = SHA256.hash(data: publicKey)
        .map { String(format: "%02x", $0) }
        .joined()
    print("trust_root_fingerprint=sha256:\(fingerprint)")

default:
    throw SigningToolError.usage
}
