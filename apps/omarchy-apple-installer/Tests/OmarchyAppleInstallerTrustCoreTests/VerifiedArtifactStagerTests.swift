import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import OmarchyAppleInstallerTrustCore

final class VerifiedArtifactStagerTests: XCTestCase {
  func testDescriptorRejectsUntrustedInputs() {
    XCTAssertThrowsError(
      try descriptor(source: "http://example.com/installer.tar.gz")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidSourceURL)
    }
    XCTAssertThrowsError(try descriptor(fileName: "../installer.tar.gz")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(try descriptor(fileName: "installer\0ignored.tar.gz")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(try descriptor(digest: "sha256:ABC")) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidDigest)
    }
  }

  func testValidDownloadIsVerifiedAndAcceptedAtomically() async throws {
    let data = Data("pinned installer payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)

    let result = try await VerifiedArtifactStager(
      downloader: downloader
    ).stage(artifact, in: directory)

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertFalse(result.reusedExistingFile)
    XCTAssertEqual(result.materialization, .atomicRename)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [artifact.fileName]
    )
  }

  func testBundledEngineIsVerifiedWithoutDownloadAndRemainsInBundle() async throws {
    let data = Data("bundled engine".utf8)
    let artifact = try descriptor(data: data)
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let source = bundle.appendingPathComponent(artifact.fileName)
    try data.write(to: source)
    let downloader = FixtureArtifactDownloader(data: Data("must not download".utf8))
    let result = try await VerifiedArtifactStager(
      downloader: downloader, bundledEngineDirectory: bundle
    ).stage(artifact, in: root.appendingPathComponent("staging"))
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertEqual(try Data(contentsOf: source), data)
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 0)
    try Data("tampered bytes".utf8).write(to: source)
    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader, bundledEngineDirectory: bundle)
        .stage(artifact, in: root.appendingPathComponent("other-staging"))
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digest mismatch, got \(error)")
      }
    }
  }

  func testPayloadStillDownloadsWhenSameNamedFileIsBundled() async throws {
    let data = Data("OS payload".utf8)
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = try PinnedInstallerArtifact(
      role: "payload", sourceURL: URL(string: "https://example.com/os.zip")!,
      fileName: "os.zip", expectedDigest: digest(data), expectedSizeBytes: UInt64(data.count)
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try data.write(to: root.appendingPathComponent("os.zip"))
    let downloader = FixtureArtifactDownloader(data: data)
    let result = try await VerifiedArtifactStager(
      downloader: downloader, bundledEngineDirectory: root
    ).stage(artifact, in: root.appendingPathComponent("staging"))
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    let count = await downloader.downloadCount
    XCTAssertEqual(count, 1)
  }

  func testExactExistingArtifactIsReusedWithoutDownload() async throws {
    let data = Data("pinned installer payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)
    let stager = VerifiedArtifactStager(downloader: downloader)

    _ = try await stager.stage(artifact, in: directory)
    let replay = try await stager.stage(artifact, in: directory)

    XCTAssertTrue(replay.reusedExistingFile)
    XCTAssertEqual(replay.materialization, .reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
  }

  func testDigestMismatchLeavesNoAcceptedOrPendingFile() async throws {
    let expected = Data("expected".utf8)
    let delivered = Data("tampered".utf8)
    let downloader = FixtureArtifactDownloader(data: delivered)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: expected)

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      []
    )
  }

  func testWrongExistingDestinationFailsClosed() async throws {
    let data = Data("expected".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let artifact = try descriptor(data: data)
    try Data("wrong".utf8).write(
      to: directory.appendingPathComponent(artifact.fileName)
    )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .destinationConflict(artifact.fileName)
      )
    }
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 0)
  }

  func testSizeMismatchIsRejectedBeforeAcceptance() async throws {
    let data = Data("payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try PinnedInstallerArtifact(
      role: "engine",
      sourceURL: URL(string: "https://example.com/installer.tar.gz")!,
      fileName: "installer.tar.gz",
      expectedDigest: digest(data),
      expectedSizeBytes: UInt64(data.count + 1)
    )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .sizeMismatch(
          expected: UInt64(data.count + 1),
          actual: UInt64(data.count)
        )
      )
    }
  }

  func testCrossDeviceRenameUsesVerifiedCopyFallback() async throws {
    let data = Data("cross-device payload".utf8)
    let downloader = FixtureArtifactDownloader(data: data)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try descriptor(data: data)
    let promoter = AtomicArtifactFilePromoter { _, _ in .failure(EXDEV) }

    let result = try await VerifiedArtifactStager(
      downloader: downloader,
      promoter: promoter
    ).stage(artifact, in: directory)

    XCTAssertEqual(result.materialization, .verifiedCopyFallback)
    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
  }

  func testRenameFailureOtherThanCrossDeviceDoesNotCopy() async throws {
    let data = Data("do not copy".utf8)
    let source = temporaryDirectory()
    let destination = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: destination)
    }
    try data.write(to: source, options: .withoutOverwriting)
    let promoter = AtomicArtifactFilePromoter { _, _ in .failure(EACCES) }

    XCTAssertThrowsError(try promoter.promote(source: source, pending: destination))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testMultiPartDescriptorRejectsUnusableManifests() throws {
    let data = Data("multi-part installer payload".utf8)
    let chunks = partition(data, into: 2)

    XCTAssertThrowsError(
      try descriptor(data: data, parts: [try part(chunks[0], index: 0)])
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidPartCount(1))
    }
    XCTAssertThrowsError(
      try descriptor(
        data: Data(repeating: 0x61, count: 17),
        parts: try (0..<17).map { index in
          try part(Data([0x61]), index: index)
        }
      )
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidPartCount(17))
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], index: 0),
          try part(chunks[1], index: 0),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .invalidPartFileName("installer.tar.gz.part00")
      )
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], fileName: "installer.tar.gz"),
          try part(chunks[1], index: 1),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .invalidPartFileName("installer.tar.gz")
      )
    }
    XCTAssertThrowsError(
      try part(chunks[0], fileName: "../installer.tar.gz.part00")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidFileName)
    }
    XCTAssertThrowsError(
      try part(chunks[0], source: "http://example.com/part00")
    ) {
      XCTAssertEqual($0 as? ArtifactStageError, .invalidSourceURL)
    }
    XCTAssertThrowsError(
      try descriptor(
        data: data,
        parts: [
          try part(chunks[0], index: 0),
          try part(chunks[1].dropLast(), index: 1),
        ]
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .partSizeSumMismatch(
          expected: UInt64(data.count),
          actual: UInt64(data.count - 1)
        )
      )
    }
  }

  func testMultiPartDescriptorAcceptsBoundaryPartCounts() throws {
    let data = Data("multi-part installer payload".utf8)
    let pair = partition(data, into: 2)
    let twoParts = try descriptor(
      data: data,
      parts: [try part(pair[0], index: 0), try part(pair[1], index: 1)]
    )
    XCTAssertEqual(twoParts.parts.count, 2)

    let wide = Data(repeating: 0x62, count: 16)
    let chunks = partition(wide, into: 16)
    let sixteenParts = try descriptor(
      data: wide,
      parts: try chunks.enumerated().map { index, chunk in
        try part(chunk, index: index)
      }
    )
    XCTAssertEqual(sixteenParts.parts.count, 16)
  }

  func testMultiPartPayloadIsAssembledFromVerifiedParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact,
      in: directory,
      progress: recorder.handler
    )

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    XCTAssertEqual(result.materialization, .assembledFromParts)
    XCTAssertFalse(result.reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 2)
    let requestedURLs = await downloader.requestedURLs
    XCTAssertEqual(requestedURLs, fixture.artifact.parts.map(\.sourceURL))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.fileName]
    )

    let events = recorder.events
    XCTAssertEqual(
      events.map(\.bytesCompleted),
      events.map(\.bytesCompleted).sorted()
    )
    XCTAssertTrue(events.contains { $0.phase == .assembling })
    XCTAssertTrue(
      events.allSatisfy { $0.role == "engine" && $0.totalBytes == UInt64(data.count) }
    )
    XCTAssertEqual(events.last?.phase, .verified)
    XCTAssertEqual(events.last?.bytesCompleted, UInt64(data.count))
    XCTAssertEqual(
      events.compactMap(\.partCount).allSatisfy { $0 == 2 },
      true
    )
  }

  func testPartDigestMismatchKeepsEarlierVerifiedPart() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    var responses = fixture.responses
    let tampered = fixture.artifact.parts[1]
    responses[tampered.sourceURL] = Data(
      repeating: 0x21,
      count: Int(tampered.expectedSizeBytes)
    )
    let downloader = RoutedFixtureDownloader(responses: responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.parts[0].fileName]
    )
  }

  func testWholeDigestMismatchKeepsVerifiedParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let decoy = Data(repeating: 0x7a, count: data.count)
    let fixture = try partsFixture(data: data, wholeDigest: digest(decoy))
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) { error in
      guard case .digestMismatch = error as? ArtifactStageError else {
        return XCTFail("Expected digestMismatch, got \(error)")
      }
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
      fixture.artifact.parts.map(\.fileName).sorted()
    )
  }

  func testAssembledPayloadIsReusedWithoutRedownloadingParts() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stager = VerifiedArtifactStager(downloader: downloader)

    _ = try await stager.stage(fixture.artifact, in: directory)
    try Data("stale part".utf8).write(
      to: directory.appendingPathComponent(
        fixture.artifact.parts[0].fileName
      )
    )
    let replay = try await stager.stage(fixture.artifact, in: directory)

    XCTAssertTrue(replay.reusedExistingFile)
    XCTAssertEqual(replay.materialization, .reusedExistingFile)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 2)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      [fixture.artifact.fileName]
    )
  }

  func testExistingVerifiedPartIsNotDownloadedAgain() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try fixture.chunks[0].write(
      to: directory.appendingPathComponent(
        fixture.artifact.parts[0].fileName
      )
    )

    let result = try await VerifiedArtifactStager(downloader: downloader).stage(
      fixture.artifact,
      in: directory
    )

    XCTAssertEqual(try Data(contentsOf: result.fileURL), data)
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 1)
    let requestedURLs = await downloader.requestedURLs
    XCTAssertEqual(requestedURLs, [fixture.artifact.parts[1].sourceURL])
  }

  func testConflictingExistingPartFailsClosedBeforeDownload() async throws {
    let data = Data("multi-part installer payload bytes".utf8)
    let fixture = try partsFixture(data: data)
    let downloader = RoutedFixtureDownloader(responses: fixture.responses)
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x33, count: Int(fixture.artifact.parts[0].expectedSizeBytes))
      .write(
        to: directory.appendingPathComponent(
          fixture.artifact.parts[0].fileName
        )
      )

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        fixture.artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .destinationConflict(fixture.artifact.parts[0].fileName)
      )
    }
    let downloadCount = await downloader.downloadCount
    XCTAssertEqual(downloadCount, 0)
  }

  func testOversizedDeliveryIsRejectedAndStagesNothing() async throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let downloader = RoutedFixtureDownloader(responses: [
      artifact.sourceURL: data + Data("overfeed".utf8)
    ])
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    await assertThrows(
      try await VerifiedArtifactStager(downloader: downloader).stage(
        artifact,
        in: directory
      )
    ) {
      XCTAssertEqual(
        $0 as? ArtifactStageError,
        .sizeMismatch(
          expected: UInt64(data.count),
          actual: UInt64(data.count + 8)
        )
      )
    }

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      []
    )
  }

  func testSingleFileStagingReportsDownloadThenVerifiedProgress() async throws {
    let data = Data("pinned installer payload".utf8)
    let artifact = try descriptor(data: data)
    let downloader = RoutedFixtureDownloader(responses: [
      artifact.sourceURL: data
    ])
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = ProgressRecorder()

    _ = try await VerifiedArtifactStager(downloader: downloader).stage(
      artifact,
      in: directory,
      progress: recorder.handler
    )

    let events = recorder.events
    XCTAssertEqual(events.first?.phase, .downloading)
    XCTAssertEqual(events.last?.phase, .verified)
    XCTAssertEqual(events.last?.bytesCompleted, UInt64(data.count))
    XCTAssertEqual(events.last?.totalBytes, UInt64(data.count))
    XCTAssertTrue(events.allSatisfy { $0.partIndex == nil && $0.partCount == nil })
    XCTAssertEqual(
      events.map(\.bytesCompleted),
      events.map(\.bytesCompleted).sorted()
    )
  }

  private func descriptor(
    source: String = "https://example.com/installer.tar.gz",
    fileName: String = "installer.tar.gz",
    digest: String? = nil,
    data: Data = Data("pinned installer payload".utf8),
    parts: [PinnedArtifactPart] = []
  ) throws -> PinnedInstallerArtifact {
    try PinnedInstallerArtifact(
      role: "engine",
      sourceURL: URL(string: source)!,
      fileName: fileName,
      expectedDigest: digest ?? self.digest(data),
      expectedSizeBytes: UInt64(data.count),
      parts: parts
    )
  }

  private func part(
    _ data: Data,
    index: Int = 0,
    fileName: String? = nil,
    source: String? = nil,
    digest: String? = nil
  ) throws -> PinnedArtifactPart {
    let name = fileName ?? String(format: "installer.tar.gz.part%02d", index)
    return try PinnedArtifactPart(
      sourceURL: URL(string: source ?? "https://example.com/\(name)")!,
      fileName: name,
      expectedDigest: digest ?? self.digest(data),
      expectedSizeBytes: UInt64(data.count)
    )
  }

  private func partsFixture(
    data: Data,
    count: Int = 2,
    fileName: String = "installer.tar.gz",
    wholeDigest: String? = nil
  ) throws -> (
    artifact: PinnedInstallerArtifact, chunks: [Data], responses: [URL: Data]
  ) {
    let chunks = partition(data, into: count)
    var parts = [PinnedArtifactPart]()
    var responses = [URL: Data]()
    for (index, chunk) in chunks.enumerated() {
      let part = try self.part(chunk, index: index)
      parts.append(part)
      responses[part.sourceURL] = chunk
    }
    let artifact = try descriptor(
      fileName: fileName,
      digest: wholeDigest ?? digest(data),
      data: data,
      parts: parts
    )
    return (artifact, chunks, responses)
  }

  private func partition(_ data: Data, into count: Int) -> [Data] {
    let chunkSize = data.count / count
    var chunks = [Data]()
    var offset = 0
    for index in 0..<count {
      let length = index == count - 1 ? data.count - offset : chunkSize
      chunks.append(data.subdata(in: offset..<(offset + length)))
      offset += length
    }
    return chunks
  }

  private func digest(_ data: Data) -> String {
    "sha256:"
      + SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-artifact-stager-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
  }
}

private actor FixtureArtifactDownloader: ArtifactDownloading {
  private let data: Data
  private(set) var downloadCount = 0

  init(data: Data) {
    self.data = data
  }

  func download(from sourceURL: URL) async throws -> URL {
    downloadCount += 1
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-downloader-\(UUID().uuidString.lowercased())"
    )
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

private actor RoutedFixtureDownloader: ArtifactDownloading {
  private let responses: [URL: Data]
  private(set) var downloadCount = 0
  private(set) var requestedURLs = [URL]()

  init(responses: [URL: Data]) {
    self.responses = responses
  }

  func download(from sourceURL: URL) async throws -> URL {
    try await download(
      from: sourceURL,
      expectedSizeBytes: UInt64.max,
      onBytes: nil
    )
  }

  func download(
    from sourceURL: URL,
    expectedSizeBytes: UInt64,
    onBytes: ArtifactByteProgressHandler?
  ) async throws -> URL {
    guard let data = responses[sourceURL] else {
      throw URLError(.fileDoesNotExist)
    }
    downloadCount += 1
    requestedURLs.append(sourceURL)
    if let onBytes {
      onBytes(UInt64(data.count / 2))
      onBytes(UInt64(data.count))
    }
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "omarchy-routed-download-\(UUID().uuidString.lowercased())"
    )
    try data.write(to: fileURL, options: .withoutOverwriting)
    return fileURL
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = [ArtifactStagingProgress]()

  var events: [ArtifactStagingProgress] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  var handler: ArtifactStagingProgressHandler {
    { [self] event in
      lock.lock()
      storage.append(event)
      lock.unlock()
    }
  }
}

private func assertThrows<T>(
  _ expression: @autoclosure () async throws -> T,
  handler: (any Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    handler(error)
  }
}
