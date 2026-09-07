#if os(macOS)
  import Darwin
  import Foundation

  public enum InstallerReleaseConfigurationError:
    Error, Equatable, Sendable
  {
    case invalidDescriptor
    case unsupportedSchema(Int)
    case invalidURL(String)
    case invalidTrustRoot
    case invalidHelperIdentity
    case unexpectedHTTPStatus(Int)
    case oversizedDocument(String)
    case invalidCatalogSignature
    case releaseResourcesUnavailable
    case unsafeReleaseResource(String)
    case invalidCatalogEnvelope
  }

  /// The release channels a build can read. Every build names all of them, so
  /// a channel can be opened later without shipping a new signed app.
  ///
  /// rcAurora serves the Aurora kernel payload. It is a separate channel rather
  /// than a variant inside rc because it is a different OS image, and a tester
  /// on rc must never be handed it by accident.
  public enum ReleaseChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case rc
    case rcAurora = "rc-aurora"
  }

  public struct ReleaseChannelEndpoints: Equatable, Sendable {
    private let endpoints: [ReleaseChannel: URL]

    /// Every channel must be named; a build that cannot resolve one of its own
    /// channels is not a build that should run.
    public init?(endpoints: [ReleaseChannel: URL]) {
      guard Set(endpoints.keys) == Set(ReleaseChannel.allCases) else {
        return nil
      }
      self.endpoints = endpoints
    }

    public func catalogURL(for channel: ReleaseChannel) -> URL {
      endpoints[channel]!
    }
  }

  public struct InstallerReleaseConfiguration: Sendable {
    public let channels: ReleaseChannelEndpoints
    public let defaultChannel: ReleaseChannel
    public let trustRoot: AppOwnedTrustRoot
    public let helperMachServiceName: String
    public let helperCodeSigningRequirement: String
    public let sealedCatalogDocuments: InstallerReleaseCatalogDocuments?

    public init(
      channels: ReleaseChannelEndpoints,
      defaultChannel: ReleaseChannel,
      trustRoot: AppOwnedTrustRoot,
      helperMachServiceName: String,
      helperCodeSigningRequirement: String,
      sealedCatalogDocuments: InstallerReleaseCatalogDocuments? = nil
    ) {
      self.channels = channels
      self.defaultChannel = defaultChannel
      self.trustRoot = trustRoot
      self.helperMachServiceName = helperMachServiceName
      self.helperCodeSigningRequirement = helperCodeSigningRequirement
      self.sealedCatalogDocuments = sealedCatalogDocuments
    }

    public func catalogURL(for channel: ReleaseChannel) -> URL {
      channels.catalogURL(for: channel)
    }
  }

  public struct InstallerReleaseConfigurationLoader: Sendable {
    public static let maximumDescriptorBytes = 65_536

    public init() {}

    public func load(
      descriptor: Data,
      trustRootPublicKey: Data
    ) throws -> InstallerReleaseConfiguration {
      guard !descriptor.isEmpty,
        descriptor.count <= Self.maximumDescriptorBytes,
        trustRootPublicKey.count == 32,
        let object = try? JSONSerialization.jsonObject(with: descriptor),
        let dictionary = object as? [String: Any],
        Set(dictionary.keys) == Set(ReleaseDescriptor.CodingKeys.allCases.map(\.rawValue))
      else {
        throw InstallerReleaseConfigurationError.invalidDescriptor
      }

      let decoded: ReleaseDescriptor
      do {
        decoded = try JSONDecoder().decode(
          ReleaseDescriptor.self,
          from: descriptor
        )
      } catch {
        throw InstallerReleaseConfigurationError.invalidDescriptor
      }
      guard decoded.schemaVersion == 3 else {
        throw InstallerReleaseConfigurationError.unsupportedSchema(
          decoded.schemaVersion
        )
      }
      try validateChannelObjects(in: dictionary)
      guard let defaultChannel = ReleaseChannel(rawValue: decoded.defaultChannel)
      else {
        throw InstallerReleaseConfigurationError.invalidDescriptor
      }
      var endpoints = [ReleaseChannel: URL]()
      for channel in ReleaseChannel.allCases {
        guard let descriptor = decoded.channels[channel.rawValue] else {
          throw InstallerReleaseConfigurationError.invalidDescriptor
        }
        try validateURL(
          descriptor.catalogURL,
          field: "channels.\(channel.rawValue).catalog_url"
        )
        endpoints[channel] = descriptor.catalogURL
      }
      // Two channels pointing at one object would silently defeat the
      // separation between what testers see and what users get.
      guard Set(endpoints.values).count == ReleaseChannel.allCases.count,
        let channels = ReleaseChannelEndpoints(endpoints: endpoints)
      else {
        throw InstallerReleaseConfigurationError.invalidURL("channels")
      }

      let trustRoot: AppOwnedTrustRoot
      do {
        trustRoot = try AppOwnedTrustRoot(
          rawRepresentation: trustRootPublicKey,
          expectedFingerprint: decoded.trustRootFingerprint
        )
      } catch {
        throw InstallerReleaseConfigurationError.invalidTrustRoot
      }
      guard
        AuthenticatedEngineXPCSubmitter.isMachServiceName(
          decoded.helperMachServiceName
        ),
        decoded.helperMachServiceName
          == InstallerProductIdentity.helperMachServiceName,
        EngineCodeSigningRequirement.isValid(
          decoded.helperCodeSigningRequirement
        )
      else {
        throw InstallerReleaseConfigurationError.invalidHelperIdentity
      }

      return InstallerReleaseConfiguration(
        channels: channels,
        defaultChannel: defaultChannel,
        trustRoot: trustRoot,
        helperMachServiceName: decoded.helperMachServiceName,
        helperCodeSigningRequirement: decoded.helperCodeSigningRequirement,
        sealedCatalogDocuments: nil
      )
    }

    /// The decoder tolerates extra keys, so the channel objects are key-set
    /// checked here the same way the top level is.
    private func validateChannelObjects(in dictionary: [String: Any]) throws {
      guard let channels = dictionary["channels"] as? [String: Any],
        Set(channels.keys) == Set(ReleaseChannel.allCases.map(\.rawValue))
      else {
        throw InstallerReleaseConfigurationError.invalidDescriptor
      }
      for value in channels.values {
        guard let entry = value as? [String: Any],
          Set(entry.keys)
            == Set(ChannelDescriptor.CodingKeys.allCases.map(\.rawValue))
        else {
          throw InstallerReleaseConfigurationError.invalidDescriptor
        }
      }
    }

    private func validateURL(_ url: URL, field: String) throws {
      guard url.scheme == "https",
        url.host?.isEmpty == false,
        url.user == nil,
        url.password == nil,
        url.fragment == nil
      else {
        throw InstallerReleaseConfigurationError.invalidURL(field)
      }
    }
  }

  public struct InstallerReleaseConfigurationLocator: Sendable {
    public static let descriptorFileName = "release.json"
    public static let trustRootFileName = "trust-root.ed25519.pub"
    public static let sealedCatalogFileName = "catalog.json"
    public static let sealedCatalogSignatureFileName = "catalog.json.sig"

    public init() {}

    public func loadFromMainBundle() throws
      -> InstallerReleaseConfiguration
    {
      guard let resources = Bundle.main.resourceURL else {
        throw InstallerReleaseConfigurationError.releaseResourcesUnavailable
      }
      return try load(
        from: resources.appendingPathComponent(
          "Release",
          isDirectory: true
        )
      )
    }

    func load(from releaseDirectory: URL) throws
      -> InstallerReleaseConfiguration
    {
      try validateDirectory(releaseDirectory)
      let descriptor = try readRegularFile(
        releaseDirectory.appendingPathComponent(Self.descriptorFileName),
        maximumBytes: InstallerReleaseConfigurationLoader.maximumDescriptorBytes,
        role: "release-descriptor"
      )
      let trustRoot = try readRegularFile(
        releaseDirectory.appendingPathComponent(Self.trustRootFileName),
        maximumBytes: 32,
        role: "trust-root"
      )
      let configuration = try InstallerReleaseConfigurationLoader().load(
        descriptor: descriptor,
        trustRootPublicKey: trustRoot
      )
      let sealedCatalogDocuments = try loadSealedCatalogDocuments(
        from: releaseDirectory
      )
      return InstallerReleaseConfiguration(
        channels: configuration.channels,
        defaultChannel: configuration.defaultChannel,
        trustRoot: configuration.trustRoot,
        helperMachServiceName: configuration.helperMachServiceName,
        helperCodeSigningRequirement:
          configuration.helperCodeSigningRequirement,
        sealedCatalogDocuments: sealedCatalogDocuments
      )
    }

    private func loadSealedCatalogDocuments(
      from releaseDirectory: URL
    ) throws -> InstallerReleaseCatalogDocuments? {
      let payloadURL = releaseDirectory.appendingPathComponent(
        Self.sealedCatalogFileName
      )
      let signatureURL = releaseDirectory.appendingPathComponent(
        Self.sealedCatalogSignatureFileName
      )
      let hasPayload = try resourceExists(
        payloadURL,
        role: "sealed-catalog"
      )
      let hasSignature = try resourceExists(
        signatureURL,
        role: "sealed-catalog-signature"
      )
      guard hasPayload || hasSignature else {
        return nil
      }
      guard hasPayload && hasSignature else {
        throw InstallerReleaseConfigurationError.unsafeReleaseResource(
          "sealed-catalog-pair"
        )
      }

      let payload = try readRegularFile(
        payloadURL,
        maximumBytes:
          InstallerReleaseCatalogFetcher.maximumCatalogBytes,
        role: "sealed-catalog"
      )
      let signature = try readRegularFile(
        signatureURL,
        maximumBytes: InstallerReleaseCatalogFetcher.signatureBytes,
        role: "sealed-catalog-signature"
      )
      guard signature.count == InstallerReleaseCatalogFetcher.signatureBytes
      else {
        throw InstallerReleaseConfigurationError.invalidCatalogSignature
      }
      return InstallerReleaseCatalogDocuments(
        payload: payload,
        signature: signature
      )
    }

    private func resourceExists(
      _ url: URL,
      role: String
    ) throws -> Bool {
      var status = stat()
      if lstat(url.path, &status) == 0 {
        return true
      }
      guard errno == ENOENT else {
        throw InstallerReleaseConfigurationError.unsafeReleaseResource(role)
      }
      return false
    }

    private func validateDirectory(_ directory: URL) throws {
      var status = stat()
      guard lstat(directory.path, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_mode & 0o022 == 0
      else {
        throw InstallerReleaseConfigurationError.releaseResourcesUnavailable
      }
    }

    private func readRegularFile(
      _ url: URL,
      maximumBytes: Int,
      role: String
    ) throws -> Data {
      let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw InstallerReleaseConfigurationError.unsafeReleaseResource(role)
      }
      defer { Darwin.close(descriptor) }

      var status = stat()
      guard fstat(descriptor, &status) == 0,
        (status.st_mode & S_IFMT) == S_IFREG,
        status.st_mode & 0o022 == 0,
        status.st_size > 0,
        status.st_size <= maximumBytes
      else {
        throw InstallerReleaseConfigurationError.unsafeReleaseResource(role)
      }
      let handle = FileHandle(
        fileDescriptor: descriptor,
        closeOnDealloc: false
      )
      guard let data = try handle.readToEnd(),
        data.count == Int(status.st_size)
      else {
        throw InstallerReleaseConfigurationError.unsafeReleaseResource(role)
      }
      return data
    }
  }

  public struct InstallerReleaseCatalogDocuments: Sendable {
    public let payload: Data
    public let signature: Data
  }

  public struct InstallerReleaseCatalogFetcher: Sendable {
    public static let maximumCatalogBytes = 1_048_576
    public static let signatureBytes = 64
    /// Base64 of a 1 MiB catalog plus the envelope's own framing.
    public static let maximumEnvelopeBytes = 1_572_864

    private let downloader: any ReleaseDocumentDownloading

    public init() {
      downloader = URLSessionReleaseDocumentDownloader()
    }

    init(downloader: any ReleaseDocumentDownloading) {
      self.downloader = downloader
    }

    public func fetch(
      configuration: InstallerReleaseConfiguration,
      channel: ReleaseChannel
    ) async throws -> InstallerReleaseCatalogDocuments {
      if let sealed = configuration.sealedCatalogDocuments {
        guard !sealed.payload.isEmpty,
          sealed.payload.count <= Self.maximumCatalogBytes
        else {
          throw InstallerReleaseConfigurationError.oversizedDocument(
            "catalog"
          )
        }
        guard sealed.signature.count == Self.signatureBytes else {
          throw InstallerReleaseConfigurationError.invalidCatalogSignature
        }
        return sealed
      }

      let envelope = try await downloader.download(
        from: configuration.catalogURL(for: channel),
        maximumBytes: Self.maximumEnvelopeBytes,
        role: "catalog-envelope"
      )
      return try SignedCatalogEnvelope.decode(envelope)
    }
  }

  /// The catalog and its signature travel as one object so a channel update is
  /// a single atomic write: a reader can never see a new catalog beside the
  /// signature of the previous one.
  enum SignedCatalogEnvelope {
    static let schemaVersion = 1

    static func decode(
      _ data: Data
    ) throws -> InstallerReleaseCatalogDocuments {
      guard let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any],
        Set(dictionary.keys) == ["schema_version", "catalog", "signature"],
        let version = dictionary["schema_version"] as? Int,
        version == schemaVersion,
        let encodedCatalog = dictionary["catalog"] as? String,
        let encodedSignature = dictionary["signature"] as? String,
        let payload = Data(base64Encoded: encodedCatalog),
        let signature = Data(base64Encoded: encodedSignature)
      else {
        throw InstallerReleaseConfigurationError.invalidCatalogEnvelope
      }
      guard !payload.isEmpty,
        payload.count <= InstallerReleaseCatalogFetcher.maximumCatalogBytes
      else {
        throw InstallerReleaseConfigurationError.oversizedDocument("catalog")
      }
      guard signature.count == InstallerReleaseCatalogFetcher.signatureBytes
      else {
        throw InstallerReleaseConfigurationError.invalidCatalogSignature
      }
      return InstallerReleaseCatalogDocuments(
        payload: payload,
        signature: signature
      )
    }
  }

  protocol ReleaseDocumentDownloading: Sendable {
    func download(
      from url: URL,
      maximumBytes: Int,
      role: String
    ) async throws -> Data
  }

  struct URLSessionReleaseDocumentDownloader:
    ReleaseDocumentDownloading, Sendable
  {
    func download(
      from url: URL,
      maximumBytes: Int,
      role: String
    ) async throws -> Data {
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      request.timeoutInterval = 30
      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      guard let response = response as? HTTPURLResponse,
        (200...299).contains(response.statusCode)
      else {
        throw InstallerReleaseConfigurationError.unexpectedHTTPStatus(
          (response as? HTTPURLResponse)?.statusCode ?? 0
        )
      }
      guard let finalURL = response.url,
        finalURL.scheme == "https",
        finalURL.host?.isEmpty == false,
        finalURL.user == nil,
        finalURL.password == nil,
        finalURL.fragment == nil
      else {
        throw InstallerReleaseConfigurationError.invalidURL(role)
      }
      let expectedLength = response.expectedContentLength
      guard expectedLength <= Int64(maximumBytes) else {
        throw InstallerReleaseConfigurationError.oversizedDocument(role)
      }

      var data = Data()
      if expectedLength > 0 {
        data.reserveCapacity(Int(expectedLength))
      }
      for try await byte in bytes {
        guard data.count < maximumBytes else {
          throw InstallerReleaseConfigurationError.oversizedDocument(role)
        }
        data.append(byte)
      }
      guard !data.isEmpty else {
        throw InstallerReleaseConfigurationError.oversizedDocument(role)
      }
      return data
    }
  }

  private struct ReleaseDescriptor: Decodable {
    let schemaVersion: Int
    let defaultChannel: String
    let channels: [String: ChannelDescriptor]
    let trustRootFingerprint: String
    let helperMachServiceName: String
    let helperCodeSigningRequirement: String

    enum CodingKeys: String, CodingKey, CaseIterable {
      case schemaVersion = "schema_version"
      case defaultChannel = "default_channel"
      case channels
      case trustRootFingerprint = "trust_root_fingerprint"
      case helperMachServiceName = "helper_mach_service_name"
      case helperCodeSigningRequirement = "helper_code_signing_requirement"
    }
  }

  private struct ChannelDescriptor: Decodable {
    let catalogURL: URL

    enum CodingKeys: String, CodingKey, CaseIterable {
      case catalogURL = "catalog_url"
    }
  }
#endif
