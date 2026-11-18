// The key releases are signed with, so that Bee installs an update only when it comes from its publisher.
//
//   swift Scripts/update-key.swift generate         creates the key and writes Resources/update-key.txt
//   swift Scripts/update-key.swift import <file>    puts a saved copy of the key back in the Keychain
//   swift Scripts/update-key.swift public           prints the public key
//   swift Scripts/update-key.swift sign <file>      prints the signature of a file
//   swift Scripts/update-key.swift verify <file> <signature file> <public key file>
//
// The private key lives in the login Keychain ("Bee Update Signing Key") and is trusted to no application:
// macOS asks each time it is read. `--key-file <path>` uses a key kept in a file instead (tests, automation).
//
// Keep a copy of the key somewhere safe (Keychain Access shows it as the password of the item). Without it
// no update can be signed for the copies of Bee already installed, which would then have to be updated by
// hand; with it, anyone can sign one. On another Mac, `import` puts the copy back.
import CryptoKit
import Foundation

let service = "com.digivore.bee.update-signing"
let account = "ed25519"
let label = "Bee Update Signing Key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@discardableResult
func security(_ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    do { try process.run() } catch { fail("Could not run /usr/bin/security: \(error.localizedDescription)") }
    if let input {
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

var arguments = Array(CommandLine.arguments.dropFirst())
var keyFile: String?
if let index = arguments.firstIndex(of: "--key-file") {
    guard index + 1 < arguments.count else { fail("--key-file needs a path") }
    keyFile = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}

let publicKeyFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/update-key.txt")

/// The public key the installed copies of Bee trust, when one was already published.
func publishedPublicKey() -> String? {
    guard let text = try? String(contentsOf: publicKeyFile, encoding: .utf8) else { return nil }
    let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
}

func storeInKeychain(_ encoded: String) {
    // Given on standard input, the key never shows in a process list. `-T ""` trusts no application.
    let command = "add-generic-password -s \"\(service)\" -a \"\(account)\" -l \"\(label)\" -D \"signing key\" -T \"\" -w \"\(encoded)\"\n"
    guard security(["-i"], input: command).status == 0, keyExists() else {
        fail("The key could not be stored in the Keychain.")
    }
}

func keyExists() -> Bool {
    if let keyFile { return FileManager.default.fileExists(atPath: keyFile) }
    // Attributes only: this does not read the secret, so the Keychain does not ask.
    return security(["find-generic-password", "-s", service, "-a", account]).status == 0
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let encoded: String
    if let keyFile {
        guard let text = try? String(contentsOfFile: keyFile, encoding: .utf8) else { fail("No key at \(keyFile)") }
        encoded = text
    } else {
        let found = security(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard found.status == 0 else {
            fail("The release key could not be read from the Keychain (missing, or access was denied). Create it with: swift Scripts/update-key.swift generate")
        }
        encoded = found.output
    }
    guard let bytes = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    else { fail("The stored release key is not a valid key.") }
    return key
}

switch arguments.first {
case "generate":
    guard !keyExists() else {
        fail("A release key already exists. It is never replaced: copies of Bee already installed only accept updates signed with it.")
    }
    // A published public key whose private half is not here must be restored, never replaced: a new key
    // would cut every installed copy of Bee off from its updates.
    if keyFile == nil, publishedPublicKey() != nil {
        fail("Resources/update-key.txt already names a release key, but its private half is not in this Keychain. Put your saved copy back with: swift Scripts/update-key.swift import <file>")
    }
    let key = Curve25519.Signing.PrivateKey()
    let encoded = key.rawRepresentation.base64EncodedString()
    if let keyFile {
        // Created private from its first byte, and never over an existing file.
        let descriptor = open(keyFile, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { fail("Could not create \(keyFile)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle.write(Data(encoded.utf8))
        try? handle.close()
    } else {
        storeInKeychain(encoded)
    }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    if keyFile == nil {
        do { try Data((publicKey + "\n").utf8).write(to: publicKeyFile) } catch { fail("Could not write \(publicKeyFile.path)") }
        FileHandle.standardError.write(Data("Stored \"\(label)\" in the login Keychain and wrote Resources/update-key.txt. Keep a copy of the key somewhere safe.\n".utf8))
    }
    print(publicKey)

case "import":
    guard arguments.count == 2, keyFile == nil, let text = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
        fail("Usage: update-key.swift import <file holding the saved key>")
    }
    guard !keyExists() else { fail("A release key is already in this Keychain. It is never replaced.") }
    let encoded = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Data(base64Encoded: encoded), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        fail("\(arguments[1]) does not hold a release key.")
    }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    if let published = publishedPublicKey() {
        guard published == publicKey else {
            fail("This is not the key of Resources/update-key.txt: installed copies of Bee would refuse what it signs.")
        }
    } else {
        do { try Data((publicKey + "\n").utf8).write(to: publicKeyFile) } catch { fail("Could not write \(publicKeyFile.path)") }
    }
    storeInKeychain(encoded)
    FileHandle.standardError.write(Data("Stored \"\(label)\" in the login Keychain. Delete \(arguments[1]) or keep it somewhere safe.\n".utf8))
    print(publicKey)

case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
        fail("Usage: update-key.swift sign <file>")
    }
    guard let signature = try? loadKey().signature(for: data) else { fail("The file could not be signed.") }
    print(signature.base64EncodedString())

case "verify":
    guard arguments.count == 4, let data = FileManager.default.contents(atPath: arguments[1]),
          let signatureText = try? String(contentsOfFile: arguments[2], encoding: .utf8),
          let keyText = try? String(contentsOfFile: arguments[3], encoding: .utf8)
    else { fail("Usage: update-key.swift verify <file> <signature file> <public key file>") }
    guard let keyBytes = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
          let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
          key.isValidSignature(signature, for: data)
    else { fail("The signature is not valid.") }
    print("The signature is valid.")

default:
    fail("Usage: update-key.swift generate | import <file> | public | sign <file> | verify <file> <signature file> <public key file>  [--key-file <path>]")
}
