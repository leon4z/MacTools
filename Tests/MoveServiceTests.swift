import Darwin
import Foundation

@main
enum MoveServiceTests {
    static func main() throws {
        try testSameVolumeMove()
        try testConflictDoesNotOverwrite()
        try testDuplicateNamesAreAllSkipped()
        try testSameDirectoryIsReported()
        try testFolderCannotMoveIntoDescendant()
        try testParentSelectionCollapsesChild()
        try testParentSelectionCollapsesInternalSymlink()
        try testSymbolicLinkMovesWithoutFollowingTarget()
        try testBrokenSymbolicLinkMovesAsLink()
        try testBrokenDestinationLinkStillConflicts()
        try testPartialFailureContinues()
        try testCaseInsensitiveDuplicateNamesAreAllSkipped()
        try testUnicodeEquivalentNamesAreAllSkipped()
        try testMoveRequestPayloadWithLargeSpecialCharacterSelection()

        if let secondVolumePath = ProcessInfo.processInfo.environment["MOVE_TEST_SECOND_VOLUME"] {
            let secondVolume = URL(fileURLWithPath: secondVolumePath, isDirectory: true)
            try testCrossVolumeMetadata(at: secondVolume)
            try testCrossVolumeContentCorruptionRetainsSource(at: secondVolume)
            try testCrossVolumeSourceChangeRetainsSource(at: secondVolume)
            try testCrossVolumePartialSourceCleanupRetainsCompleteDestination(at: secondVolume)
        }

        print("MoveServiceTests: all tests passed")
    }

    private static func testSameVolumeMove() throws {
        try withFixture("same-volume") { source, destination in
            let file = source.appendingPathComponent("hello.txt")
            try Data("hello".utf8).write(to: file)

            let result = MoveService.execute(sources: [file], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 1, "same-volume move count")
            try expect(!FileManager.default.fileExists(atPath: file.path), "same-volume source removed")
            try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("hello.txt").path), "same-volume destination exists")
        }
    }

    private static func testConflictDoesNotOverwrite() throws {
        try withFixture("conflict") { source, destination in
            let sourceFile = source.appendingPathComponent("same.txt")
            let destinationFile = destination.appendingPathComponent("same.txt")
            try Data("source".utf8).write(to: sourceFile)
            try Data("destination".utf8).write(to: destinationFile)

            let result = MoveService.execute(sources: [sourceFile], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 1, "conflict reported")
            try expect(FileManager.default.fileExists(atPath: sourceFile.path), "conflict source retained")
            let destinationContents = String(data: try Data(contentsOf: destinationFile), encoding: .utf8)
            try expect(destinationContents == "destination", "conflict destination unchanged")
        }
    }

    private static func testDuplicateNamesAreAllSkipped() throws {
        try withFixture("duplicate-selection") { source, destination in
            let firstDirectory = source.appendingPathComponent("a", isDirectory: true)
            let secondDirectory = source.appendingPathComponent("b", isDirectory: true)
            try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
            let first = firstDirectory.appendingPathComponent("same.txt")
            let second = secondDirectory.appendingPathComponent("same.txt")
            try Data("a".utf8).write(to: first)
            try Data("b".utf8).write(to: second)

            let result = MoveService.execute(sources: [first, second], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 2, "duplicate selections both skipped")
            try expect(FileManager.default.fileExists(atPath: first.path), "first duplicate retained")
            try expect(FileManager.default.fileExists(atPath: second.path), "second duplicate retained")
        }
    }

    private static func testSameDirectoryIsReported() throws {
        try withFixture("same-directory") { source, _ in
            let file = source.appendingPathComponent("here.txt")
            try Data().write(to: file)

            let result = MoveService.execute(sources: [file], destinationDirectory: source) { _, _, _ in }
            try expect(result.movedCount == 0 && result.alreadyThere.count == 1, "same directory reported")
            try expect(FileManager.default.fileExists(atPath: file.path), "same directory source retained")
        }
    }

    private static func testFolderCannotMoveIntoDescendant() throws {
        try withFixture("descendant") { source, _ in
            let folder = source.appendingPathComponent("Folder", isDirectory: true)
            let child = folder.appendingPathComponent("Child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

            let result = MoveService.execute(sources: [folder], destinationDirectory: child) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 1, "descendant move blocked")
            try expect(FileManager.default.fileExists(atPath: folder.path), "descendant source retained")
        }
    }

    private static func testParentSelectionCollapsesChild() throws {
        try withFixture("parent-child") { source, destination in
            let folder = source.appendingPathComponent("Folder", isDirectory: true)
            let child = folder.appendingPathComponent("child.txt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("child".utf8).write(to: child)

            let result = MoveService.execute(sources: [child, folder], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 1 && result.issues.isEmpty, "parent selection collapses child")
            try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Folder/child.txt").path), "collapsed child moved with parent")
        }
    }

    private static func testSymbolicLinkMovesWithoutFollowingTarget() throws {
        try withFixture("symlink") { source, destination in
            let target = source.appendingPathComponent("target.txt")
            let link = source.appendingPathComponent("link.txt")
            try Data("target".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

            let result = MoveService.execute(sources: [link], destinationDirectory: destination) { _, _, _ in }
            let movedLink = destination.appendingPathComponent("link.txt")
            try expect(result.movedCount == 1, "symlink moved")
            try expect(FileManager.default.fileExists(atPath: target.path), "symlink target retained")
            let attributes = try FileManager.default.attributesOfItem(atPath: movedLink.path)
            try expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink, "moved item remains symlink")
        }
    }

    private static func testParentSelectionCollapsesInternalSymlink() throws {
        try withFixture("parent-internal-symlink") { source, destination in
            let outsideTarget = source.appendingPathComponent("outside.txt")
            let folder = source.appendingPathComponent("Folder", isDirectory: true)
            let link = folder.appendingPathComponent("outside-link")
            try Data("outside".utf8).write(to: outsideTarget)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outsideTarget.path)

            let result = MoveService.execute(sources: [link, folder], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 1 && result.issues.isEmpty, "parent collapses internal symlink")
            try expect(FileManager.default.fileExists(atPath: outsideTarget.path), "internal symlink target remains outside")
            let movedLink = destination.appendingPathComponent("Folder/outside-link")
            let attributes = try FileManager.default.attributesOfItem(atPath: movedLink.path)
            try expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink, "internal symlink moved with parent")
        }
    }

    private static func testPartialFailureContinues() throws {
        try withFixture("partial") { source, destination in
            let movable = source.appendingPathComponent("move.txt")
            let conflict = source.appendingPathComponent("conflict.txt")
            try Data().write(to: movable)
            try Data("source".utf8).write(to: conflict)
            try Data("destination".utf8).write(to: destination.appendingPathComponent("conflict.txt"))

            let result = MoveService.execute(sources: [conflict, movable], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 1 && result.issues.count == 1, "partial failure continues")
            try expect(FileManager.default.fileExists(atPath: conflict.path), "partial conflict retained")
            try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("move.txt").path), "partial movable completed")
        }
    }

    private static func testBrokenSymbolicLinkMovesAsLink() throws {
        try withFixture("broken-symlink") { source, destination in
            let link = source.appendingPathComponent("broken-link")
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: source.appendingPathComponent("missing-target").path
            )

            let result = MoveService.execute(sources: [link], destinationDirectory: destination) { _, _, _ in }
            let movedLink = destination.appendingPathComponent("broken-link")
            let attributes = try FileManager.default.attributesOfItem(atPath: movedLink.path)
            try expect(result.movedCount == 1, "broken symlink moved")
            try expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink, "broken symlink remains a link")
        }
    }

    private static func testBrokenDestinationLinkStillConflicts() throws {
        try withFixture("broken-destination-link") { source, destination in
            let sourceFile = source.appendingPathComponent("same-name")
            let destinationLink = destination.appendingPathComponent("same-name")
            try Data("source".utf8).write(to: sourceFile)
            try FileManager.default.createSymbolicLink(
                atPath: destinationLink.path,
                withDestinationPath: destination.appendingPathComponent("missing-target").path
            )

            let result = MoveService.execute(sources: [sourceFile], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 1, "broken destination link conflicts")
            try expect(FileManager.default.fileExists(atPath: sourceFile.path), "source retained beside broken destination link")
        }
    }

    private static func testCaseInsensitiveDuplicateNamesAreAllSkipped() throws {
        try withFixture("case-duplicate") { source, destination in
            let firstDirectory = source.appendingPathComponent("a", isDirectory: true)
            let secondDirectory = source.appendingPathComponent("b", isDirectory: true)
            try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
            let upper = firstDirectory.appendingPathComponent("Report.txt")
            let lower = secondDirectory.appendingPathComponent("report.txt")
            try Data().write(to: upper)
            try Data().write(to: lower)

            let result = MoveService.execute(sources: [upper, lower], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 2, "case-insensitive duplicates all skipped")
        }
    }

    private static func testUnicodeEquivalentNamesAreAllSkipped() throws {
        try withFixture("unicode-duplicate") { source, destination in
            let firstDirectory = source.appendingPathComponent("a", isDirectory: true)
            let secondDirectory = source.appendingPathComponent("b", isDirectory: true)
            try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
            let composed = firstDirectory.appendingPathComponent("café.txt")
            let decomposed = secondDirectory.appendingPathComponent("cafe\u{301}.txt")
            try Data().write(to: composed)
            try Data().write(to: decomposed)

            let result = MoveService.execute(sources: [composed, decomposed], destinationDirectory: destination) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 2, "Unicode-equivalent duplicates all skipped")
        }
    }

    private static func testCrossVolumeMetadata(at secondVolume: URL) throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent("FinderRightClick-cross-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = fixtureRoot.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = secondVolume.appendingPathComponent("FinderRightClick-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
            try? fileManager.removeItem(at: destinationDirectory)
        }

        let sourceFile = sourceDirectory.appendingPathComponent("metadata.txt")
        try Data("cross-volume".utf8).write(to: sourceFile)
        try fileManager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sourceFile.path)
        try setExtendedAttribute(name: "local.leon.FinderRightClick.test", value: Data("tag".utf8), at: sourceFile)
        try setFlags(UInt32(UF_HIDDEN), at: sourceFile)
        try addReadACL(at: sourceFile)
        let originalStat = try statSnapshot(at: sourceFile)
        let originalACL = try aclText(at: sourceFile)

        let sourceFolder = sourceDirectory.appendingPathComponent("Folder", isDirectory: true)
        let childFile = sourceFolder.appendingPathComponent("child.txt")
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: childFile)
        try setExtendedAttribute(name: "local.leon.FinderRightClick.child", value: Data("child-tag".utf8), at: childFile)

        let brokenLink = sourceDirectory.appendingPathComponent("broken-link")
        try fileManager.createSymbolicLink(
            atPath: brokenLink.path,
            withDestinationPath: sourceDirectory.appendingPathComponent("missing-target").path
        )

        let result = MoveService.execute(
            sources: [sourceFile, sourceFolder, brokenLink],
            destinationDirectory: destinationDirectory
        ) { _, _, _ in }
        let issueSummary = result.issues.map { "\($0.sourceURL.lastPathComponent): \($0.reason)" }.joined(separator: ", ")
        try expect(
            result.movedCount == 3 && result.issues.isEmpty,
            "cross-volume move completed; moved=\(result.movedCount), issues=\(issueSummary)"
        )
        try expect(!fileManager.fileExists(atPath: sourceFile.path), "cross-volume source removed after verification")
        let movedFile = destinationDirectory.appendingPathComponent("metadata.txt")
        try expect(fileManager.fileExists(atPath: movedFile.path), "cross-volume destination exists")
        let movedContents = try Data(contentsOf: movedFile)
        try expect(movedContents == Data("cross-volume".utf8), "cross-volume content preserved independently")
        let movedAttributes = try fileManager.attributesOfItem(atPath: movedFile.path)
        try expect((movedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "cross-volume mode preserved independently")
        let movedAttribute = try extendedAttribute(name: "local.leon.FinderRightClick.test", at: movedFile)
        try expect(movedAttribute == Data("tag".utf8), "cross-volume xattr preserved independently")
        let movedStat = try statSnapshot(at: movedFile)
        try expect(movedStat.flags == originalStat.flags, "cross-volume BSD flags preserved independently")
        try expect(movedStat.modificationSeconds == originalStat.modificationSeconds, "cross-volume modification seconds preserved independently")
        try expect(movedStat.modificationNanoseconds == originalStat.modificationNanoseconds, "cross-volume modification nanoseconds preserved independently")
        try expect(movedStat.creationSeconds == originalStat.creationSeconds, "cross-volume creation time preserved independently")
        let movedACL = try aclText(at: movedFile)
        try expect(movedACL == originalACL, "cross-volume ACL preserved independently")
        try expect(fileManager.fileExists(atPath: destinationDirectory.appendingPathComponent("Folder/child.txt").path), "cross-volume directory contents exist")
        let movedLinkAttributes = try fileManager.attributesOfItem(atPath: destinationDirectory.appendingPathComponent("broken-link").path)
        try expect(movedLinkAttributes[.type] as? FileAttributeType == .typeSymbolicLink, "cross-volume broken symlink remains a link")
    }

    private static func testCrossVolumeContentCorruptionRetainsSource(at secondVolume: URL) throws {
        try withCrossVolumeFixture("corrupt-copy", secondVolume: secondVolume) { source, destination in
            let sourceFile = source.appendingPathComponent("data.bin")
            try Data("AAAA".utf8).write(to: sourceFile)
            let originalDate = (try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.modificationDate] as? Date)
            var hooks = MoveServiceHooks.none
            hooks.afterCrossVolumeCopy = { _, copiedURL in
                try Data("BBBB".utf8).write(to: copiedURL)
                if let originalDate {
                    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: copiedURL.path)
                }
            }

            let result = MoveService.execute(
                sources: [sourceFile],
                destinationDirectory: destination,
                hooks: hooks
            ) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 1, "corrupt same-size copy rejected")
            try expect(FileManager.default.fileExists(atPath: sourceFile.path), "corrupt copy leaves source")
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("data.bin").path), "corrupt copy leaves no destination")
        }
    }

    private static func testCrossVolumeSourceChangeRetainsSource(at secondVolume: URL) throws {
        try withCrossVolumeFixture("source-change", secondVolume: secondVolume) { source, destination in
            let sourceFile = source.appendingPathComponent("data.bin")
            try Data("AAAA".utf8).write(to: sourceFile)
            let originalDate = (try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.modificationDate] as? Date)
            var hooks = MoveServiceHooks.none
            hooks.afterCrossVolumeCopy = { originalURL, _ in
                try Data("CCCC".utf8).write(to: originalURL)
                if let originalDate {
                    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: originalURL.path)
                }
            }

            let result = MoveService.execute(
                sources: [sourceFile],
                destinationDirectory: destination,
                hooks: hooks
            ) { _, _, _ in }
            try expect(result.movedCount == 0 && result.issues.count == 1, "same-size source change rejected")
            try expect(FileManager.default.fileExists(atPath: sourceFile.path), "changed source retained")
            try expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("data.bin").path), "changed source leaves no destination")
        }
    }

    private static func testCrossVolumePartialSourceCleanupRetainsCompleteDestination(at secondVolume: URL) throws {
        try withCrossVolumeFixture("partial-cleanup", secondVolume: secondVolume) { source, destination in
            let folder = source.appendingPathComponent("Folder", isDirectory: true)
            let first = folder.appendingPathComponent("first.txt")
            let second = folder.appendingPathComponent("second.txt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            var hooks = MoveServiceHooks.none
            hooks.removeSource = { sourceURL, fileManager in
                try fileManager.removeItem(at: sourceURL.appendingPathComponent("first.txt"))
                throw TestFailure(message: "injected source cleanup failure")
            }

            let result = MoveService.execute(
                sources: [folder],
                destinationDirectory: destination,
                hooks: hooks
            ) { _, _, _ in }
            let retainedDestination = destination.appendingPathComponent("Folder", isDirectory: true)
            try expect(result.movedCount == 1, "partial cleanup keeps completed target count")
            try expect(result.issues.count == 1 && result.issues[0].destinationCopyRetained, "partial cleanup requires attention")
            try expect(FileManager.default.fileExists(atPath: retainedDestination.appendingPathComponent("first.txt").path), "complete target keeps first file")
            try expect(FileManager.default.fileExists(atPath: retainedDestination.appendingPathComponent("second.txt").path), "complete target keeps second file")
        }
    }

    private static func testMoveRequestPayloadWithLargeSpecialCharacterSelection() throws {
        let paths = (0..<600).map { index in
            "/tmp/第 \(index) 项 & # ?/文件 \(index).txt"
        }
        let requestID = UUID().uuidString
        let payload = MoveRequestPayload(requestID: requestID, createdAt: Date(), sourcePaths: paths)
        let decoded = try JSONDecoder().decode(MoveRequestPayload.self, from: JSONEncoder().encode(payload))
        try expect(decoded.sourcePaths == paths, "large special-character selection round trips through request payload")

        var components = URLComponents()
        components.scheme = "finderrightclick"
        components.host = "move"
        components.queryItems = [URLQueryItem(name: "requestID", value: requestID)]

        let url = try require(components.url, "compact move URL created")
        try expect(url.absoluteString.count < 128, "move URL stays compact regardless of selection size")
    }

    private static func withFixture(
        _ name: String,
        body: (URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FinderRightClick-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(source, destination)
    }

    private static func withCrossVolumeFixture(
        _ name: String,
        secondVolume: URL,
        body: (URL, URL) throws -> Void
    ) throws {
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FinderRightClick-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let destinationRoot = secondVolume.appendingPathComponent(
            "FinderRightClick-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        try body(sourceRoot, destinationRoot)
    }

    private static func setExtendedAttribute(name: String, value: Data, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { pathPointer -> Int32 in
            guard let pathPointer else { return -1 }
            return name.withCString { namePointer in
                value.withUnsafeBytes { bytes in
                    setxattr(pathPointer, namePointer, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func extendedAttribute(name: String, at url: URL) throws -> Data {
        try url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { throw POSIXError(.EIO) }
            return try name.withCString { namePointer in
                let size = getxattr(pathPointer, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var bytes = [UInt8](repeating: 0, count: size)
                let written = getxattr(pathPointer, namePointer, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
                guard written >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return Data(bytes.prefix(written))
            }
        }
    }

    private static func setFlags(_ flags: UInt32, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { pathPointer in
            pathPointer.map { chflags($0, flags) } ?? -1
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func addReadACL(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "\(NSUserName()) allow read", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure(message: "failed to add ACL")
        }
    }

    private static func aclText(at url: URL) throws -> String {
        try url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { throw POSIXError(.EIO) }
            guard let acl = acl_get_file(pathPointer, ACL_TYPE_EXTENDED) else {
                if errno == ENOENT { return "" }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var length: ssize_t = 0
            guard let text = acl_to_text(acl, &length) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { acl_free(text) }
            return String(cString: text)
        }
    }

    private static func statSnapshot(at url: URL) throws -> TestStatSnapshot {
        try url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { throw POSIXError(.EIO) }
            var information = stat()
            guard lstat(pathPointer, &information) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return TestStatSnapshot(
                flags: information.st_flags,
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                creationSeconds: Int64(information.st_birthtimespec.tv_sec)
            )
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure(message: message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw TestFailure(message: message)
        }
        return value
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "Test failed: \(message)" }
}

private struct TestStatSnapshot {
    let flags: UInt32
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let creationSeconds: Int64
}
