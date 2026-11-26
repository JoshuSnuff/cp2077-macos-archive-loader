import Foundation

public struct CompatibilityPackageValidationResult: Sendable {
    public let validatedFiles: [CompatibilityManagedFile]

    public init(validatedFiles: [CompatibilityManagedFile]) {
        self.validatedFiles = validatedFiles
    }
}

public enum CompatibilityPackageValidator {
    public typealias CommandRunner = CompatibilityPreflight.CommandRunner
    public typealias QuarantineChecker = CompatibilityPreflight.QuarantineChecker

    public static func validate(
        manifest: CompatibilityManifest,
        packageRoot: URL,
        fileManager: FileManager = .default,
        commandRunner: CommandRunner? = nil,
        quarantineChecker: QuarantineChecker? = nil
    ) throws -> CompatibilityPackageValidationResult {
        try manifest.validate()
        let root = packageRoot.standardizedFileURL
        let run = commandRunner ?? CompatibilityPreflight.run
        let isQuarantined = quarantineChecker ?? CompatibilityPreflight.hasQuarantine
        for entry in manifest.managedFiles {
            let source = try safeURL(for: entry.packagePath, under: root)
            guard fileManager.isReadableFile(atPath: source.path) else {
                throw CompatibilityManifestError.sourceMissing(entry.packagePath)
            }
            try validateRegularNonSymlinkFile(
                source,
                relativePath: entry.packagePath,
                root: root,
                fileManager: fileManager
            )
            let actual: String
            if entry.packagePath == "archive-loader/compatibility/manifest.json",
               entry.gamePath == "archive-loader/compatibility/manifest.json" {
                let document = try CompatibilityManifestDocument(bytes: Data(contentsOf: source))
                actual = document.maskedSelfHash
            } else {
                actual = try Hashes.sha256Hex(ofFileAt: source)
            }
            guard actual == entry.sha256 else {
                throw CompatibilityManifestError.sourceHashMismatch(
                    path: entry.packagePath,
                    expected: entry.sha256,
                    actual: actual
                )
            }

            if let role = FrameworkRuntimeRole.required.first(where: { $0.nativeGamePath == entry.gamePath }),
               manifest.frameworkRuntime != nil {
                try validateRuntimeBinary(
                    source,
                    role: role,
                    run: run,
                    isQuarantined: isQuarantined,
                    fileManager: fileManager
                )
            }
        }
        return CompatibilityPackageValidationResult(validatedFiles: manifest.managedFiles)
    }

    private static func validateRegularNonSymlinkFile(
        _ source: URL,
        relativePath: String,
        root: URL,
        fileManager: FileManager
    ) throws {
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CompatibilityManifestError.sourceIsSymlink(relativePath)
            }
        }

        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CompatibilityManifestError.sourceNotRegularFile(relativePath)
        }
    }

    private static func validateRuntimeBinary(
        _ source: URL,
        role: FrameworkRuntimeRole,
        run: @escaping CommandRunner,
        isQuarantined: @escaping QuarantineChecker,
        fileManager: FileManager
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o111 != 0 else {
            throw CompatibilityManifestError.sourceNotExecutable(source.path)
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
        } catch {
            throw CompatibilityManifestError.invalidMachO(source.path)
        }
        guard isArm64MachO(bytes) else {
            throw CompatibilityManifestError.invalidMachO(source.path)
        }

        do {
            _ = try run("codesign", ["--verify", "--deep", "--strict", source.path])
        } catch {
            throw CompatibilityManifestError.codeSigningFailed(source.path)
        }
        do {
            if try isQuarantined(source) {
                throw CompatibilityManifestError.quarantinedSource(source.path)
            }
        } catch let error as CompatibilityManifestError {
            throw error
        } catch {
            throw CompatibilityManifestError.quarantineCheckFailed(source.path)
        }

        _ = role
    }
}

private func safeURL(for relativePath: String, under root: URL) throws -> URL {
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
        throw CompatibilityManifestError.unsafeSourcePath(relativePath)
    }
    return candidate
}

private enum MachOByteOrder {
    case little
    case big
}

private struct MachOReader {
    let data: Data
    let baseOffset: Int
    let length: Int
    let byteOrder: MachOByteOrder

    func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= length - 4 else { return nil }
        return readUInt32(data, at: baseOffset + offset, order: byteOrder)
    }

    func u64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= length - 8 else { return nil }
        let bytes = Array(data[(baseOffset + offset)..<(baseOffset + offset + 8)])
        switch byteOrder {
        case .big:
            return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        case .little:
            return bytes.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }

    func contains(offset: UInt64, size: UInt64) -> Bool {
        let limit = UInt64(length)
        return offset <= limit && size <= limit - offset
    }
}

private func isArm64MachO(_ data: Data) -> Bool {
    let mhMagic64: UInt32 = 0xfeedfacf
    let fatMagic: UInt32 = 0xcafebabe
    let fatMagic64: UInt32 = 0xcafebabf

    guard let littleMagic = readUInt32(data, at: 0, order: .little),
          let bigMagic = readUInt32(data, at: 0, order: .big)
    else { return false }

    if littleMagic == mhMagic64 {
        return isArm64Dylib(
            MachOReader(data: data, baseOffset: 0, length: data.count, byteOrder: .little)
        )
    }

    if bigMagic == fatMagic {
        return isArm64FatDylib(data, byteOrder: .big, fat64: false)
    }
    if littleMagic == fatMagic {
        return isArm64FatDylib(data, byteOrder: .little, fat64: false)
    }
    if bigMagic == fatMagic64 {
        return isArm64FatDylib(data, byteOrder: .big, fat64: true)
    }
    if littleMagic == fatMagic64 {
        return isArm64FatDylib(data, byteOrder: .little, fat64: true)
    }
    return false
}

private func isArm64FatDylib(_ data: Data, byteOrder: MachOByteOrder, fat64: Bool) -> Bool {
    let arm64: UInt32 = 0x0100000c
    let reader = MachOReader(data: data, baseOffset: 0, length: data.count, byteOrder: byteOrder)
    guard let count = reader.u32(at: 4), count > 0, count <= 128 else { return false }

    let entrySize = fat64 ? 32 : 20
    let tableSize = Int(count) * entrySize
    guard tableSize <= data.count - 8 else { return false }

    var selectedSlice: (offset: UInt64, size: UInt64)?
    for index in 0..<Int(count) {
        let entry = 8 + index * entrySize
        guard let cpuType = reader.u32(at: entry),
              let offset: UInt64 = fat64
                ? reader.u64(at: entry + 8)
                : reader.u32(at: entry + 8).map(UInt64.init),
              let size: UInt64 = fat64
                ? reader.u64(at: entry + 16)
                : reader.u32(at: entry + 12).map(UInt64.init)
        else { return false }
        guard offset <= UInt64(data.count), size > 0, size <= UInt64(data.count) - offset else {
            return false
        }

        if cpuType == arm64 {
            guard selectedSlice == nil else { return false }
            selectedSlice = (offset, size)
        }
    }

    guard let selectedSlice,
          selectedSlice.offset <= UInt64(Int.max),
          selectedSlice.size <= UInt64(Int.max)
    else { return false }
    return isArm64Dylib(
        MachOReader(
            data: data,
            baseOffset: Int(selectedSlice.offset),
            length: Int(selectedSlice.size),
            byteOrder: .little
        )
    )
}

private func isArm64Dylib(_ reader: MachOReader) -> Bool {
    let mhMagic64: UInt32 = 0xfeedfacf
    let arm64: UInt32 = 0x0100000c
    let mhDylib: UInt32 = 6
    let lcSegment64: UInt32 = 0x19
    let lcIDDylib: UInt32 = 0x0d
    let lcSymtab: UInt32 = 0x02
    let lcDyldInfo: UInt32 = 0x22
    let lcDyldInfoOnly: UInt32 = 0x80000022
    let lcCodeSignature: UInt32 = 0x1d
    let lcSegmentData: Set<UInt32> = [0x26, 0x29, 0x33, 0x80000034]

    guard reader.length >= 32 else { return false }
    guard reader.u32(at: 0) == mhMagic64,
          reader.u32(at: 4) == arm64,
          reader.u32(at: 12) == mhDylib,
          let commandCount = reader.u32(at: 16),
          let commandBytes = reader.u32(at: 20),
          commandCount > 0,
          commandBytes >= 8,
          UInt64(commandBytes) <= UInt64(reader.length - 32),
          commandCount <= commandBytes / 8
    else { return false }

    let commandEnd = 32 + Int(commandBytes)
    var commandOffset = 32
    var hasSegment = false
    var hasID = false

    for _ in 0..<Int(commandCount) {
        guard commandOffset <= commandEnd - 8,
              let command = reader.u32(at: commandOffset),
              let commandSize = reader.u32(at: commandOffset + 4),
              commandSize >= 8,
              commandSize <= UInt32(commandEnd - commandOffset)
        else { return false }

        let size = Int(commandSize)
        let baseCommand = command & 0x7fff_ffff
        switch baseCommand {
        case lcSegment64:
            guard size >= 72,
                  let fileOffset = reader.u64(at: commandOffset + 40),
                  let fileSize = reader.u64(at: commandOffset + 48),
                  reader.contains(offset: fileOffset, size: fileSize)
            else { return false }
            hasSegment = true
        case lcIDDylib, 0x0c, 0x18, 0x1f, 0x20, 0x23:
            guard size >= 24,
                  let nameOffset = reader.u32(at: commandOffset + 8),
                  nameOffset >= 24,
                  nameOffset < commandSize,
                  containsNullByte(
                      reader.data,
                      start: reader.baseOffset + commandOffset + Int(nameOffset),
                      end: reader.baseOffset + commandOffset + size
                  )
            else { return false }
            if baseCommand == lcIDDylib { hasID = true }
        case lcSymtab:
            guard size >= 24,
                  let symbolOffset = reader.u32(at: commandOffset + 8),
                  let symbolCount = reader.u32(at: commandOffset + 12),
                  let stringOffset = reader.u32(at: commandOffset + 16),
                  let stringSize = reader.u32(at: commandOffset + 20),
                  reader.contains(offset: UInt64(symbolOffset), size: UInt64(symbolCount) * 16),
                  reader.contains(offset: UInt64(stringOffset), size: UInt64(stringSize))
            else { return false }
        case lcDyldInfo, lcDyldInfoOnly:
            guard size >= 48 else { return false }
            for index in stride(from: 8, through: 40, by: 8) {
                guard let offset = reader.u32(at: commandOffset + index),
                      let byteCount = reader.u32(at: commandOffset + index + 4),
                      reader.contains(offset: UInt64(offset), size: UInt64(byteCount))
                else { return false }
            }
        case lcCodeSignature:
            guard size >= 16,
                  let offset = reader.u32(at: commandOffset + 8),
                  let byteCount = reader.u32(at: commandOffset + 12),
                  reader.contains(offset: UInt64(offset), size: UInt64(byteCount))
            else { return false }
        default:
            if lcSegmentData.contains(command) {
                guard size >= 16,
                      let offset = reader.u32(at: commandOffset + 8),
                      let byteCount = reader.u32(at: commandOffset + 12),
                      reader.contains(offset: UInt64(offset), size: UInt64(byteCount))
                else { return false }
            }
        }

        commandOffset += size
    }

    return commandOffset == commandEnd && hasSegment && hasID
}

private func readUInt32(_ data: Data, at offset: Int, order: MachOByteOrder) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    let bytes = Array(data[offset..<(offset + 4)])
    switch order {
    case .big:
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    case .little:
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}

private func containsNullByte(_ data: Data, start: Int, end: Int) -> Bool {
    guard start >= 0, start < end, end <= data.count else { return false }
    return data[start..<end].contains(0)
}
