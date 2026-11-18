import Foundation
import CryptoKit

@main struct UpdateKeyTool {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "generate" {
            let key = Curve25519.Signing.PrivateKey()
            let path = URL(fileURLWithPath: CommandLine.arguments[2])
            let bytes = Data((key.rawRepresentation.base64EncodedString()+"\n").utf8)
            guard !FileManager.default.fileExists(atPath:path.path),FileManager.default.createFile(atPath:path.path,contents:bytes,attributes:[.posixPermissions:0o600]) else{exit(1)}
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "public" else{exit(2)}
        let input=FileHandle.standardInput.readDataToEndOfFile()
        guard input.count<1024,let value=String(data:input,encoding:.utf8),let bytes=Data(base64Encoded:value.trimmingCharacters(in:.whitespacesAndNewlines)),[32,64].contains(bytes.count) else{exit(1)}
        let key=try Curve25519.Signing.PrivateKey(rawRepresentation:bytes.prefix(32))
        if bytes.count==64,bytes.suffix(32) != key.publicKey.rawRepresentation{exit(1)}
        print(key.publicKey.rawRepresentation.base64EncodedString())
    }
}
