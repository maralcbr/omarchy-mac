#if os(macOS)
  import Darwin
  import Foundation

  public enum AcceptedCatalogIdentityStoreError:
    Error, Equatable, Sendable
  {
    case unsafeDirectory
    case unsafeState
    case writeFailed
  }

  public struct AcceptedCatalogIdentityStore: Sendable {
    /// The pre-channel state file. It always described the stable channel, so
    /// stable still reads it once and then supersedes it.
    public static let legacyFileName = "accepted-catalog.json"
    private static let maximumBytes: Int64 = 4_096

    private let directory: URL
    private let channel: ReleaseChannel

    public init(directory: URL, channel: ReleaseChannel) {
      self.directory = directory
      self.channel = channel
    }

    /// Each channel keeps its own accepted sequence. Without this, a tester who
    /// accepted a rc catalog could never go back to stable: the older stable
    /// sequence would look like a rollback.
    public static func fileName(for channel: ReleaseChannel) -> String {
      "accepted-catalog-\(channel.rawValue).json"
    }

    private var fileName: String {
      Self.fileName(for: channel)
    }

    public func load() throws -> AcceptedCatalogIdentity? {
      try validateDirectory()
      if let identity = try read(fileName: fileName) {
        return identity
      }
      guard channel == .stable else {
        return nil
      }
      return try read(fileName: Self.legacyFileName)
    }

    private func read(fileName: String) throws -> AcceptedCatalogIdentity? {
      let stateURL = directory.appendingPathComponent(fileName)
      let descriptor = Darwin.open(
        stateURL.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      if descriptor < 0, errno == ENOENT {
        return nil
      }
      guard descriptor >= 0 else {
        throw AcceptedCatalogIdentityStoreError.unsafeState
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o077 == 0,
        status.st_size > 0,
        status.st_size <= Self.maximumBytes
      else {
        throw AcceptedCatalogIdentityStoreError.unsafeState
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any],
        Set(dictionary.keys) == [
          "schema_version",
          "sequence",
          "payload_digest",
        ],
        let record = try? JSONDecoder().decode(
          StoredCatalogIdentity.self,
          from: data
        ),
        record.schemaVersion == 1,
        let identity = try? AcceptedCatalogIdentity(
          sequence: record.sequence,
          payloadDigest: record.payloadDigest
        )
      else {
        throw AcceptedCatalogIdentityStoreError.unsafeState
      }
      return identity
    }

    public func store(_ identity: AcceptedCatalogIdentity) throws {
      if let existing = try load() {
        guard identity.sequence >= existing.sequence else {
          throw SupportCatalogSequenceError.rollback(
            stored: existing.sequence,
            candidate: identity.sequence
          )
        }
        guard
          identity.sequence != existing.sequence
            || identity.payloadDigest == existing.payloadDigest
        else {
          throw SupportCatalogSequenceError.sequenceReuse(identity.sequence)
        }
        if identity == existing {
          return
        }
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(StoredCatalogIdentity(identity))
      guard data.count <= Self.maximumBytes else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }

      let pending = directory.appendingPathComponent(
        ".accepted-catalog-\(channel.rawValue)-\(UUID().uuidString.lowercased()).tmp"
      )
      let descriptor = Darwin.open(
        pending.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
      var isOpen = true
      defer {
        if isOpen {
          Darwin.close(descriptor)
        }
        try? FileManager.default.removeItem(at: pending)
      }

      do {
        let handle = FileHandle(
          fileDescriptor: descriptor,
          closeOnDealloc: false
        )
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        isOpen = false
      } catch {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }

      let destination = directory.appendingPathComponent(fileName)
      guard Darwin.rename(pending.path, destination.path) == 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
      try synchronizeDirectory()
      if channel == .stable {
        // The channel file now carries what the legacy file said, so retire it
        // rather than leave two records that can disagree.
        try? FileManager.default.removeItem(
          at: directory.appendingPathComponent(Self.legacyFileName)
        )
      }
    }

    private func validateDirectory() throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o077 == 0
      else {
        throw AcceptedCatalogIdentityStoreError.unsafeDirectory
      }
    }

    private func synchronizeDirectory() throws {
      let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
      defer { Darwin.close(descriptor) }
      guard fsync(descriptor) == 0 else {
        throw AcceptedCatalogIdentityStoreError.writeFailed
      }
    }
  }

  private struct StoredCatalogIdentity: Codable {
    let schemaVersion: Int
    let sequence: UInt64
    let payloadDigest: String

    init(_ identity: AcceptedCatalogIdentity) {
      schemaVersion = 1
      sequence = identity.sequence
      payloadDigest = identity.payloadDigest
    }

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case sequence
      case payloadDigest = "payload_digest"
    }
  }
#endif
