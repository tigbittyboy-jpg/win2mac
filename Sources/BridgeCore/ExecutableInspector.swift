import Foundation

public enum PEFormat: String, Codable, Sendable { case pe32 = "PE32", pe32Plus = "PE32+" }
public enum WindowsMachine: String, Codable, Sendable { case x86, x64, arm64, arm64EC, unknown }
public enum ExecutableKind: String, Codable, Sendable { case application, installerCandidate }
public struct ExecutableInfo: Codable, Equatable, Sendable {
    public let format: PEFormat
    public let machine: WindowsMachine
    public let machineCode: UInt16
    public let managed: Bool
    public let requires32Bit: Bool
    public let kind: ExecutableKind
    public let imports: [String]
    public var summary: String { "\(machine.rawValue) · \(format.rawValue)\(managed ? " · .NET" : "")" }
}

/// Bounded passive PE reader. Formats and machine types are separate; no image is loaded.
public enum ExecutableInspector {
    public static func inspect(_ url: URL) throws -> ExecutableInfo {
        guard url.isFileURL, url.path.hasPrefix("/"),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BridgeError.invalidExecutable("Choose a readable Windows executable file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= 65_536, offset <= size, UInt64(count) <= size - offset else {
                throw BridgeError.invalidExecutable("The executable contains truncated or invalid PE data.")
            }
            try handle.seek(toOffset: offset)
            let bytes = [UInt8](try handle.read(upToCount: count) ?? Data())
            guard bytes.count == count else { throw BridgeError.invalidExecutable("The executable could not be read completely.") }
            return bytes
        }
        func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
        func u32(_ b: [UInt8], _ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[p + $1]) << (8 * $1) } }
        let dos = try read(0, 64)
        guard dos[0] == 0x4d, dos[1] == 0x5a else { throw BridgeError.invalidExecutable("This file is not a Windows PE executable.") }
        let peOffset = UInt64(u32(dos, 60))
        guard peOffset >= 64, peOffset <= 16 * 1024 * 1024 else { throw BridgeError.invalidExecutable("Invalid PE header location.") }
        let coff = try read(peOffset, 24)
        guard Array(coff[0..<4]) == [0x50, 0x45, 0, 0], u16(coff, 22) & 0x2000 == 0,
              u16(coff, 22) & 2 != 0 else { throw BridgeError.invalidExecutable("Select an executable image, not a DLL or invalid PE file.") }
        let machineCode = u16(coff, 4), sections = Int(u16(coff, 6)), optionalSize = Int(u16(coff, 20))
        guard sections > 0, sections <= 96, optionalSize >= 96, optionalSize <= 4096 else {
            throw BridgeError.invalidExecutable("Invalid PE section or optional header size.")
        }
        let optional = try read(peOffset + 24, optionalSize)
        let format: PEFormat
        let directoryOffset: Int
        switch u16(optional, 0) {
        case 0x10b: format = .pe32; directoryOffset = 96
        case 0x20b: format = .pe32Plus; directoryOffset = 112
        default: throw BridgeError.unsupported("This PE optional header format is unsupported.")
        }
        guard optionalSize >= directoryOffset else { throw BridgeError.invalidExecutable("Truncated PE optional header.") }
        let machine: WindowsMachine
        switch machineCode { case 0x14c: machine = .x86; case 0x8664: machine = .x64
        case 0xaa64: machine = .arm64; case 0xa641: machine = .arm64EC; default: machine = .unknown }
        guard !(machine == .x86 && format != .pe32),
              !([WindowsMachine.x64, .arm64, .arm64EC].contains(machine) && format != .pe32Plus) else {
            throw BridgeError.invalidExecutable("The CPU architecture and PE header format disagree.")
        }
        let table = try read(peOffset + 24 + UInt64(optionalSize), sections * 40)
        let headerSize = UInt64(u32(optional, 60))
        guard headerSize >= peOffset + 24 + UInt64(optionalSize + sections * 40), headerSize <= size else {
            throw BridgeError.invalidExecutable("Invalid PE header extent.")
        }
        for i in 0..<sections {
            let p = i * 40, count = UInt64(u32(table, p + 16)), offset = UInt64(u32(table, p + 20))
            guard count == 0 || (offset >= headerSize && offset <= size && count <= size - offset) else {
                throw BridgeError.invalidExecutable("A PE section extends outside the executable.")
            }
        }
        func map(_ rva: UInt32, _ count: Int) throws -> UInt64 {
            let address = UInt64(rva)
            if address < headerSize, UInt64(count) <= headerSize - address { return address }
            for i in 0..<sections {
                let p = i * 40, base = UInt64(u32(table, p + 12)), rawSize = UInt64(u32(table, p + 16))
                if address >= base, address - base <= rawSize, UInt64(count) <= rawSize - (address - base) {
                    return UInt64(u32(table, p + 20)) + address - base
                }
            }
            throw BridgeError.invalidExecutable("A PE data directory points outside the image.")
        }
        let directoryCount = Int(u32(optional, directoryOffset - 4))
        guard directoryCount <= (optionalSize - directoryOffset) / 8 else { throw BridgeError.invalidExecutable("Truncated PE data directories.") }
        func directory(_ index: Int) -> (UInt32, UInt32) {
            guard index < directoryCount else { return (0, 0) }
            return (u32(optional, directoryOffset + index * 8), u32(optional, directoryOffset + index * 8 + 4))
        }
        var imports: [String] = []
        let (importRVA, importSize) = directory(1)
        if importRVA != 0 {
            guard importSize >= 20 else { throw BridgeError.invalidExecutable("Invalid import directory.") }
            var terminated = false
            for i in 0..<min(Int(importSize / 20), 512) {
                let address = UInt64(importRVA) + UInt64(i * 20)
                guard address <= UInt64(UInt32.max) else { throw BridgeError.invalidExecutable("Import address overflow.") }
                let descriptor = try read(try map(UInt32(address), 20), 20)
                if descriptor.allSatisfy({ $0 == 0 }) { terminated = true; break }
                let nameRVA = u32(descriptor, 12)
                guard nameRVA != 0 else { throw BridgeError.invalidExecutable("Missing imported library name.") }
                var name: [UInt8] = []
                for j in 0..<256 {
                    let address = UInt64(nameRVA) + UInt64(j)
                    guard address <= UInt64(UInt32.max) else { throw BridgeError.invalidExecutable("Import name overflow.") }
                    let byte = try read(try map(UInt32(address), 1), 1)[0]
                    if byte == 0 { break }; name.append(byte)
                }
                guard !name.isEmpty, name.count < 256, let value = String(bytes: name, encoding: .ascii) else {
                    throw BridgeError.invalidExecutable("Invalid imported library name.")
                }
                imports.append(value)
            }
            guard terminated else { throw BridgeError.invalidExecutable("Unterminated or excessive import directory.") }
        }
        let (clrRVA, clrSize) = directory(14)
        var requires32Bit = false
        if clrRVA != 0 {
            guard clrSize >= 72 else { throw BridgeError.invalidExecutable("Truncated .NET header.") }
            let clr = try read(try map(clrRVA, 72), 72)
            guard u32(clr, 0) >= 72 else { throw BridgeError.invalidExecutable("Invalid .NET header.") }
            requires32Bit = u32(clr, 16) & 2 != 0
        }
        // Evidence-based hint only: MSI API imports or a known self-extracting signature.
        // Ambiguous installers remain applications until the user identifies them.
        let tail = try read(size > 65_536 ? size - 65_536 : 0, Int(min(size, 65_536)))
        let installer = imports.contains { $0.lowercased() == "msi.dll" } ||
            Data(tail).range(of: Data("Inno Setup Setup Data".utf8)) != nil ||
            Data(tail).range(of: Data("NullsoftInst".utf8)) != nil
        return ExecutableInfo(format: format, machine: machine, machineCode: machineCode,
            managed: clrRVA != 0, requires32Bit: requires32Bit,
            kind: installer ? .installerCandidate : .application, imports: imports)
    }
}
