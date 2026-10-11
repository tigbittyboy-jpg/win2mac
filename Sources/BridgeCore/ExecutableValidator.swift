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
        let info = try ExecutableInspector.inspect(url)
        switch info.machine {
        case .x86: return .x86
        case .x64: return .x64
        default: throw BridgeError.unsupported("Windows ARM64, ARM64EC and unknown CPU architectures need a dedicated backend.")
        }
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
