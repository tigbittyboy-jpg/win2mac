import Foundation

public enum ExecutableValidator {
    // Parse the DOS header, PE signature, machine, and optional-header magic.
    // No binary execution and no full-file allocation for large installers.
    public static func validateX64(_ url: URL) throws {
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
        guard pe[4] == 0x64, pe[5] == 0x86, pe[24] == 0x0b, pe[25] == 0x02 else {
            throw BridgeError.unsupported("Phase 1 supports x64 PE32+ EXEs only; 32-bit and ARM Windows programs are unsupported.")
        }
    }
}
