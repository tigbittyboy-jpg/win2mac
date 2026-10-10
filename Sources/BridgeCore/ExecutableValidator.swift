import Foundation

public enum WindowsExecutableArchitecture: String, Sendable {
    case x86, x64
}

public enum ExecutableValidator {
    // Parse the DOS header, PE signature, machine, and optional-header magic.
    // No binary execution and no full-file allocation for large installers.
    public static func validateX64(_ url: URL) throws {
        guard try architecture(of: url) == .x64 else {
            throw BridgeError.unsupported("This operation requires a Windows x64 executable.")
        }
    }

    public static func architecture(of url: URL) throws -> WindowsExecutableArchitecture {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "exe",
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw BridgeError.invalidExecutable("Select a readable local .exe file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let dos = [UInt8](try file.read(upToCount: 64) ?? Data())
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else {
            throw BridgeError.invalidExecutable("File is not a Windows PE executable (missing DOS header).")
        }
        let offset = (0..<4).reduce(UInt32(0)) { $0 | UInt32(dos[60 + $1]) << (8 * $1) }
        guard offset >= 64, offset <= 16 * 1024 * 1024 else {
            throw BridgeError.invalidExecutable("Invalid PE header offset.")
        }
        try file.seek(toOffset: UInt64(offset))
        let pe = [UInt8](try file.read(upToCount: 26) ?? Data())
        guard pe.count == 26, Array(pe[0..<4]) == [0x50, 0x45, 0, 0] else {
            throw BridgeError.invalidExecutable("File has an invalid PE signature.")
        }
        guard pe[23] & 0x20 == 0 else {
            throw BridgeError.invalidExecutable("Select an EXE, not a DLL renamed as an EXE.")
        }
        if pe[4] == 0x64, pe[5] == 0x86, pe[24] == 0x0b, pe[25] == 0x02 { return .x64 }
        if pe[4] == 0x4c, pe[5] == 0x01, pe[24] == 0x0b, pe[25] == 0x01 { return .x86 }
        throw BridgeError.unsupported("Select a Windows x86 PE32 or x64 PE32+ EXE. ARM and mismatched PE headers are unsupported.")
    }

    public static func validateX64DLL(_ bytes: Data) throws {
        let data = [UInt8](bytes.prefix(16 * 1024 * 1024 + 26))
        guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a else {
            throw BridgeError.invalidExecutable("Graphics library is not a Windows PE DLL.")
        }
        let offset = Int((0..<4).reduce(UInt32(0)) { $0 | UInt32(data[60 + $1]) << (8 * $1) })
        guard offset >= 64, offset <= 16 * 1024 * 1024, offset + 26 <= data.count,
              Array(data[offset..<offset + 4]) == [0x50, 0x45, 0, 0],
              data[offset + 4] == 0x64, data[offset + 5] == 0x86,
              data[offset + 24] == 0x0b, data[offset + 25] == 0x02,
              data[offset + 23] & 0x20 != 0 else {
            throw BridgeError.invalidExecutable("Graphics libraries must be x64 PE32+ DLLs; architecture/type inspection does not verify their publisher.")
        }
    }
}
