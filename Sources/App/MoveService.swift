import CryptoKit
import Darwin
import Foundation

struct MoveIssue {
    let sourceURL: URL
    let reason: String
    let destinationCopyRetained: Bool

    init(sourceURL: URL, reason: String, destinationCopyRetained: Bool = false) {
        self.sourceURL = sourceURL
        self.reason = reason
        self.destinationCopyRetained = destinationCopyRetained
    }
}

struct MoveBatchResult {
    let movedCount: Int
    let issues: [MoveIssue]
    let alreadyThere: [URL]

    var hasVisibleResult: Bool {
        !issues.isEmpty || !alreadyThere.isEmpty
    }
}

struct MoveServiceHooks {
    var afterCrossVolumeCopy: ((URL, URL) throws -> Void)?
    var removeSource: ((URL, FileManager) throws -> Void)?

    static let none = MoveServiceHooks()
}

enum MoveService {
    typealias ProgressHandler = (_ current: Int, _ total: Int, _ itemName: String) -> Void

    static func execute(
        sources: [URL],
        destinationDirectory: URL,
        hooks: MoveServiceHooks = .none,
        progress: ProgressHandler
    ) -> MoveBatchResult {
        let fileManager = FileManager.default
        let effectiveSources = collapseNestedSources(uniqueSources(sources), fileManager: fileManager)
        let duplicateNames = duplicateDestinationNames(for: effectiveSources, destination: destinationDirectory)
        let total = effectiveSources.count
        var movedCount = 0
        var issues: [MoveIssue] = []
        var alreadyThere: [URL] = []
        guard let destinationIdentity = fileIdentity(destinationDirectory, followsSymbolicLink: true) else {
            return MoveBatchResult(
                movedCount: 0,
                issues: effectiveSources.map { MoveIssue(sourceURL: $0, reason: "目标目录不存在或无法访问") },
                alreadyThere: []
            )
        }

        for (offset, sourceURL) in effectiveSources.enumerated() {
            progress(offset + 1, total, sourceURL.lastPathComponent)

            guard fileIdentity(destinationDirectory, followsSymbolicLink: true) == destinationIdentity else {
                issues.append(MoveIssue(sourceURL: sourceURL, reason: "目标目录在移动过程中发生了变化"))
                continue
            }

            guard let sourceIdentity = fileIdentity(sourceURL, followsSymbolicLink: false) else {
                issues.append(MoveIssue(sourceURL: sourceURL, reason: "源项目不存在"))
                continue
            }

            if sameLocation(sourceURL.deletingLastPathComponent(), destinationDirectory) {
                alreadyThere.append(sourceURL)
                continue
            }

            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if duplicateNames.contains(destinationNameKey(destinationURL.lastPathComponent, in: destinationDirectory)) {
                issues.append(MoveIssue(sourceURL: sourceURL, reason: "所选项目中存在同名项目"))
                continue
            }

            if itemExists(destinationURL, fileManager: fileManager) {
                issues.append(MoveIssue(sourceURL: sourceURL, reason: "目标目录已有同名项目"))
                continue
            }

            if isRealDirectory(sourceURL, fileManager: fileManager),
               isSameOrDescendant(destinationDirectory, of: sourceURL) {
                issues.append(MoveIssue(sourceURL: sourceURL, reason: "目标位于该文件夹内部"))
                continue
            }

            do {
                guard fileIdentity(sourceURL, followsSymbolicLink: false) == sourceIdentity else {
                    throw MoveServiceError.sourceChanged
                }
                if sameVolume(sourceURL, destinationDirectory, fileManager: fileManager) {
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                } else {
                    try moveAcrossVolumes(
                        sourceURL,
                        destinationURL: destinationURL,
                        expectedSourceIdentity: sourceIdentity,
                        expectedDestinationDirectoryIdentity: destinationIdentity,
                        hooks: hooks,
                        fileManager: fileManager
                    )
                }
                movedCount += 1
            } catch MoveServiceError.sourceCleanupFailed {
                movedCount += 1
                issues.append(MoveIssue(
                    sourceURL: sourceURL,
                    reason: "目标副本完整，但源位置清理不完整；请检查两处位置",
                    destinationCopyRetained: true
                ))
            } catch {
                issues.append(MoveIssue(sourceURL: sourceURL, reason: userFacingReason(for: error)))
            }
        }

        return MoveBatchResult(movedCount: movedCount, issues: issues, alreadyThere: alreadyThere)
    }

    private static func uniqueSources(_ sources: [URL]) -> [URL] {
        var seen: Set<String> = []
        return sources.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized
        }
    }

    private static func collapseNestedSources(_ sources: [URL], fileManager: FileManager) -> [URL] {
        let parentDirectories = sources.filter { isRealDirectory($0, fileManager: fileManager) }

        return sources.filter { candidate in
            !parentDirectories.contains { parent in
                parent.path != candidate.path && isLexicallySameOrDescendant(candidate, of: parent)
            }
        }
    }

    private static func duplicateDestinationNames(for sources: [URL], destination: URL) -> Set<String> {
        let grouped = Dictionary(grouping: sources) {
            destinationNameKey($0.lastPathComponent, in: destination)
        }
        return Set(grouped.compactMap { key, values in values.count > 1 ? key : nil })
    }

    private static func destinationNameKey(_ name: String, in destination: URL) -> String {
        let values = try? destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames ?? false
        let normalized = name.precomposedStringWithCanonicalMapping
        return caseSensitive
            ? normalized
            : normalized.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path ==
            rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSameOrDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        if parentPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }

    private static func isLexicallySameOrDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if parentPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }

    private static func itemExists(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func fileIdentity(_ url: URL, followsSymbolicLink: Bool) -> FileIdentity? {
        let identityURL = followsSymbolicLink ? url.resolvingSymlinksInPath() : url
        return try? identityURL.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { throw MoveServiceError.sourceChanged }
            var information = stat()
            guard Darwin.lstat(pathPointer, &information) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
        }
    }

    private static func isRealDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private static func sameVolume(_ source: URL, _ destinationDirectory: URL, fileManager: FileManager) -> Bool {
        guard
            let sourceAttributes = try? fileManager.attributesOfFileSystem(
                forPath: source.deletingLastPathComponent().path
            ),
            let destinationAttributes = try? fileManager.attributesOfFileSystem(
                forPath: destinationDirectory.path
            ),
            let sourceNumber = sourceAttributes[.systemNumber] as? NSNumber,
            let destinationNumber = destinationAttributes[.systemNumber] as? NSNumber
        else {
            return false
        }

        return sourceNumber == destinationNumber
    }

    private static func moveAcrossVolumes(
        _ sourceURL: URL,
        destinationURL: URL,
        expectedSourceIdentity: FileIdentity,
        expectedDestinationDirectoryIdentity: FileIdentity,
        hooks: MoveServiceHooks,
        fileManager: FileManager
    ) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".FinderRightClick-\(UUID().uuidString).moving"
        )

        do {
            let sourceBeforeCopy = try snapshots(rootURL: sourceURL, fileManager: fileManager)
            guard fileIdentity(sourceURL, followsSymbolicLink: false) == expectedSourceIdentity else {
                throw MoveServiceError.sourceChanged
            }
            try copyPreservingMetadata(sourceURL, to: temporaryURL, fileManager: fileManager)
            try restoreCreationDates(from: sourceURL, to: temporaryURL, fileManager: fileManager)
            try hooks.afterCrossVolumeCopy?(sourceURL, temporaryURL)
            let sourceAfterCopy = try snapshots(rootURL: sourceURL, fileManager: fileManager)
            let copiedAfterCopy = try snapshots(rootURL: temporaryURL, fileManager: fileManager)
            guard
                fileIdentity(sourceURL, followsSymbolicLink: false) == expectedSourceIdentity,
                fileIdentity(destinationURL.deletingLastPathComponent(), followsSymbolicLink: true) ==
                    expectedDestinationDirectoryIdentity,
                sourceAfterCopy == sourceBeforeCopy,
                copiedAfterCopy == sourceBeforeCopy
            else {
                throw MoveServiceError.copyVerificationFailed
            }

            guard !itemExists(destinationURL, fileManager: fileManager) else {
                throw MoveServiceError.destinationAppeared
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

            do {
                guard
                    fileIdentity(sourceURL, followsSymbolicLink: false) == expectedSourceIdentity,
                    fileIdentity(destinationURL.deletingLastPathComponent(), followsSymbolicLink: true) ==
                        expectedDestinationDirectoryIdentity,
                    try snapshots(rootURL: sourceURL, fileManager: fileManager) == sourceBeforeCopy,
                    try snapshots(rootURL: destinationURL, fileManager: fileManager) == sourceBeforeCopy
                else {
                    throw MoveServiceError.copyVerificationFailed
                }
            } catch {
                do {
                    try fileManager.removeItem(at: destinationURL)
                } catch {
                    throw MoveServiceError.rollbackFailed
                }
                throw error
            }

            do {
                if let removeSource = hooks.removeSource {
                    try removeSource(sourceURL, fileManager)
                } else {
                    try fileManager.removeItem(at: sourceURL)
                }
            } catch {
                throw MoveServiceError.sourceCleanupFailed
            }
        } catch {
            if itemExists(temporaryURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private static func copyPreservingMetadata(
        _ sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "--rsrc",
            "--extattr",
            "--acl",
            "--qtn",
            sourceURL.path,
            destinationURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MoveServiceError.copyFailed
        }
    }

    private static func restoreCreationDates(
        from sourceRoot: URL,
        to copiedRoot: URL,
        fileManager: FileManager
    ) throws {
        var sourceItems = [sourceRoot]
        if isRealDirectory(sourceRoot, fileManager: fileManager),
           let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) {
            sourceItems.append(contentsOf: enumerator.compactMap { $0 as? URL })
        }

        let rootComponents = sourceRoot.standardizedFileURL.pathComponents
        for sourceURL in sourceItems {
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            guard
                attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                let creationDate = attributes[.creationDate] as? Date
            else {
                continue
            }

            let sourceComponents = sourceURL.standardizedFileURL.pathComponents
            guard sourceComponents.starts(with: rootComponents) else {
                throw MoveServiceError.copyVerificationFailed
            }
            let relativeComponents = sourceComponents.dropFirst(rootComponents.count)
            let copiedURL = relativeComponents.reduce(copiedRoot) { partial, component in
                partial.appendingPathComponent(component)
            }
            try fileManager.setAttributes([.creationDate: creationDate], ofItemAtPath: copiedURL.path)
        }
    }

    private static func snapshots(rootURL: URL, fileManager: FileManager) throws -> [String: ItemSnapshot] {
        var snapshots: [String: ItemSnapshot] = [
            "": try snapshot(url: rootURL, fileManager: fileManager)
        ]

        guard isRealDirectory(rootURL, fileManager: fileManager) else {
            return snapshots
        }

        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw MoveServiceError.copyVerificationFailed
        }

        for case let itemURL as URL in enumerator {
            let rootComponents = rootURL.standardizedFileURL.pathComponents
            let itemComponents = itemURL.standardizedFileURL.pathComponents
            guard itemComponents.starts(with: rootComponents) else {
                throw MoveServiceError.copyVerificationFailed
            }
            let relativePath = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
            snapshots[relativePath] = try snapshot(url: itemURL, fileManager: fileManager)
        }

        if enumerationError != nil {
            throw MoveServiceError.copyVerificationFailed
        }

        return snapshots
    }

    private static func snapshot(url: URL, fileManager: FileManager) throws -> ItemSnapshot {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType ?? .typeUnknown
        let metadata = try statMetadata(at: url)
        let symlinkTarget = type == .typeSymbolicLink
            ? try fileManager.destinationOfSymbolicLink(atPath: url.path)
            : nil

        return ItemSnapshot(
            type: type.rawValue,
            metadata: metadata,
            symlinkTarget: symlinkTarget,
            contentDigest: type == .typeRegular ? try contentDigest(at: url) : nil,
            accessControlList: try accessControlList(at: url, isSymbolicLink: type == .typeSymbolicLink),
            extendedAttributes: try extendedAttributes(at: url)
        )
    }

    private static func statMetadata(at url: URL) throws -> StatMetadata {
        try url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { throw MoveServiceError.copyVerificationFailed }
            var information = stat()
            guard Darwin.lstat(pathPointer, &information) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return StatMetadata(
                mode: UInt32(information.st_mode),
                owner: information.st_uid,
                group: information.st_gid,
                flags: information.st_flags,
                size: information.st_size,
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                creationSeconds: Int64(information.st_birthtimespec.tv_sec)
            )
        }
    }

    private static func contentDigest(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private static func accessControlList(at url: URL, isSymbolicLink: Bool) throws -> String {
        try url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { throw MoveServiceError.copyVerificationFailed }
            let acl = isSymbolicLink
                ? acl_get_link_np(pathPointer, ACL_TYPE_EXTENDED)
                : acl_get_file(pathPointer, ACL_TYPE_EXTENDED)
            guard let acl else {
                if errno == ENOENT || errno == EOPNOTSUPP {
                    return ""
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }

            var length: ssize_t = 0
            guard let textPointer = acl_to_text(acl, &length) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { acl_free(textPointer) }
            return String(cString: textPointer)
        }
    }

    private static func extendedAttributes(at url: URL) throws -> [String: Data] {
        try url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else {
                throw MoveServiceError.copyVerificationFailed
            }

            let options = XATTR_NOFOLLOW
            let nameBufferSize = listxattr(pathPointer, nil, 0, options)
            guard nameBufferSize >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard nameBufferSize > 0 else {
                return [:]
            }

            var nameBuffer = [CChar](repeating: 0, count: nameBufferSize)
            let written = listxattr(pathPointer, &nameBuffer, nameBuffer.count, options)
            guard written >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let names = nameBuffer.split(separator: 0).map { bytes in
                String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            var attributes: [String: Data] = [:]

            for name in names {
                let data = try name.withCString { namePointer -> Data in
                    let valueSize = getxattr(pathPointer, namePointer, nil, 0, 0, options)
                    guard valueSize >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard valueSize > 0 else {
                        return Data()
                    }

                    var value = [UInt8](repeating: 0, count: valueSize)
                    let valueWritten = getxattr(pathPointer, namePointer, &value, value.count, 0, options)
                    guard valueWritten >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    return Data(value.prefix(valueWritten))
                }
                attributes[name] = data
            }

            return attributes
        }
    }

    private static func userFacingReason(for error: Error) -> String {
        if let serviceError = error as? MoveServiceError {
            return serviceError.userFacingReason
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "没有权限访问源项目或目标目录"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "源项目不存在"
            case NSFileWriteFileExistsError:
                return "目标目录已有同名项目"
            default:
                break
            }
        }
        return "移动过程中发生错误"
    }
}

private struct ItemSnapshot: Equatable {
    let type: String
    let metadata: StatMetadata
    let symlinkTarget: String?
    let contentDigest: Data?
    let accessControlList: String
    let extendedAttributes: [String: Data]
}

private struct StatMetadata: Equatable {
    let mode: UInt32
    let owner: uid_t
    let group: gid_t
    let flags: UInt32
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let creationSeconds: Int64
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

private enum MoveServiceError: Error {
    case copyFailed
    case copyVerificationFailed
    case destinationAppeared
    case sourceChanged
    case sourceCleanupFailed
    case rollbackFailed

    var userFacingReason: String {
        switch self {
        case .copyFailed:
            return "无法完整复制项目到目标目录"
        case .copyVerificationFailed:
            return "无法完整保留内容或文件元数据"
        case .destinationAppeared:
            return "目标目录在移动过程中出现了同名项目"
        case .sourceChanged:
            return "源项目在移动过程中发生了变化"
        case .sourceCleanupFailed:
            return "目标副本完整，但源位置清理不完整；请检查两处位置"
        case .rollbackFailed:
            return "目标已复制，但源项目无法删除；请手动检查两处位置"
        }
    }
}
