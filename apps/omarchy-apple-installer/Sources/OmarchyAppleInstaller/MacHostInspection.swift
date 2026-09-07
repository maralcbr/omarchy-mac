#if os(macOS)
  import Darwin
  import Foundation

  public struct AppleSiliconHostInspection: Equatable, Sendable {
    public let identity: AppleMacIdentity
    public let eligibility: AppleSiliconInstallEligibility
    public let macOSVersion: String
    public let powerSource: MacPowerSource
    public let fileVaultEnabled: Bool
    public let storage: APFSStorageInspection
  }

  public struct AppleMacIdentity: Equatable, Sendable {
    public let model: String
    public let chip: String
    public let deviceIdentifier: String
  }

  public enum AppleSiliconInstallEligibility: Equatable, Sendable {
    case requiresSignedCatalog
    case blocked(reason: String)
  }

  public enum MacPowerSource: String, Equatable, Sendable {
    case ac = "AC Power"
    case battery = "Battery Power"
  }

  public struct APFSStorageInspection: Equatable, Sendable {
    public let containerIdentifier: String
    public let physicalStoreIdentifier: String
    public let isInternal: Bool
    public let containerSizeBytes: UInt64
    public let containerFreeBytes: UInt64
    public let minimumPreferredSizeBytes: UInt64

    public var shrinkableBytes: UInt64 {
      containerSizeBytes - minimumPreferredSizeBytes
    }
  }

  public enum AppleSiliconHostInspectionError: Error, Equatable, Sendable {
    case hardwarePropertyUnavailable(String)
    case invalidHardwareProperty(String)
    case commandFailed(String, Int32)
    case invalidCommandResponse(String)
    case unsafeContainerIdentifier(String)
    case unsupportedStorage(String)
  }

  public struct AppleSiliconHostInspector: Sendable {
    private static let explicitlyUnsupportedDevices = ["apple,j614s"]

    private let hardware: any HardwarePropertyReading
    private let commands: any ReadOnlyMacCommandRunning
    private let operatingSystem: any OperatingSystemVersionReading

    public init() {
      hardware = SysctlHardwarePropertyReader()
      commands = FoundationReadOnlyMacCommandRunner()
      operatingSystem = ProcessInfoOperatingSystemVersionReader()
    }

    init(
      hardware: any HardwarePropertyReading,
      commands: any ReadOnlyMacCommandRunning,
      operatingSystem: any OperatingSystemVersionReading
    ) {
      self.hardware = hardware
      self.commands = commands
      self.operatingSystem = operatingSystem
    }

    public func inspect() throws -> AppleSiliconHostInspection {
      let identity = try inspectIdentity()
      let storage = try ReadOnlyStorageProbe(commands: commands).inspect()
      let powerSource = try readPowerSource()
      let eligibility: AppleSiliconInstallEligibility

      if Self.explicitlyUnsupportedDevices.contains(identity.deviceIdentifier) {
        eligibility = .blocked(
          reason: "This installer doesn’t support this Mac model yet."
        )
      } else if !storage.isInternal {
        eligibility = .blocked(
          reason: "Start this installer from macOS on your Mac’s internal storage."
        )
      } else {
        eligibility = .requiresSignedCatalog
      }

      return AppleSiliconHostInspection(
        identity: identity,
        eligibility: eligibility,
        macOSVersion: operatingSystem.versionString(),
        powerSource: powerSource,
        fileVaultEnabled: storage.fileVaultEnabled,
        storage: storage.inspection
      )
    }

    private func inspectIdentity() throws -> AppleMacIdentity {
      let model = try nonemptyHardwareProperty("hw.model")
      let chip = try nonemptyHardwareProperty("machdep.cpu.brand_string")
      let rawTarget = try nonemptyHardwareProperty("hw.targettype").lowercased()
      let target =
        rawTarget.hasPrefix("apple,")
        ? String(rawTarget.dropFirst(6))
        : rawTarget

      guard !target.isEmpty,
        target.utf8.allSatisfy({ byte in
          (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
        })
      else {
        throw AppleSiliconHostInspectionError.invalidHardwareProperty(
          "hw.targettype"
        )
      }

      return AppleMacIdentity(
        model: model,
        chip: chip,
        deviceIdentifier: "apple,\(target)"
      )
    }

    private func nonemptyHardwareProperty(_ name: String) throws -> String {
      let value = try hardware.string(named: name).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !value.isEmpty else {
        throw AppleSiliconHostInspectionError.invalidHardwareProperty(name)
      }
      return value
    }

    private func readPowerSource() throws -> MacPowerSource {
      let output = String(
        decoding: try commands.run(.powerSource),
        as: UTF8.self
      )
      if output.contains("'AC Power'") {
        return .ac
      }
      if output.contains("'Battery Power'") {
        return .battery
      }
      throw AppleSiliconHostInspectionError.invalidCommandResponse("pmset-power")
    }
  }

  protocol HardwarePropertyReading: Sendable {
    func string(named name: String) throws -> String
  }

  struct SysctlHardwarePropertyReader: HardwarePropertyReading {
    func string(named name: String) throws -> String {
      var byteCount = 0
      guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0,
        byteCount > 1
      else {
        throw AppleSiliconHostInspectionError.hardwarePropertyUnavailable(name)
      }

      var bytes = [CChar](repeating: 0, count: byteCount)
      guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else {
        throw AppleSiliconHostInspectionError.hardwarePropertyUnavailable(name)
      }

      return String(
        decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    }
  }

  protocol OperatingSystemVersionReading: Sendable {
    func versionString() -> String
  }

  struct ProcessInfoOperatingSystemVersionReader: OperatingSystemVersionReading {
    func versionString() -> String {
      ProcessInfo.processInfo.operatingSystemVersionString
    }
  }

  enum ReadOnlyMacCommand: Equatable, Sendable {
    case rootDiskInfo
    case apfsResizeLimits(APFSContainerIdentifier)
    case powerSource

    var executableURL: URL {
      switch self {
      case .rootDiskInfo, .apfsResizeLimits:
        URL(fileURLWithPath: "/usr/sbin/diskutil")
      case .powerSource:
        URL(fileURLWithPath: "/usr/bin/pmset")
      }
    }

    var arguments: [String] {
      switch self {
      case .rootDiskInfo:
        ["info", "-plist", "/"]
      case .apfsResizeLimits(let container):
        ["apfs", "resizeContainer", container.rawValue, "limits", "-plist"]
      case .powerSource:
        ["-g", "batt"]
      }
    }

    var auditName: String {
      switch self {
      case .rootDiskInfo:
        "diskutil-info-root"
      case .apfsResizeLimits:
        "diskutil-apfs-resize-limits"
      case .powerSource:
        "pmset-power"
      }
    }
  }

  struct APFSContainerIdentifier: Equatable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
      guard rawValue.hasPrefix("disk") else {
        return nil
      }
      let suffix = rawValue.dropFirst(4)
      guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
        return nil
      }
      self.rawValue = rawValue
    }
  }

  protocol ReadOnlyMacCommandRunning: Sendable {
    func run(_ command: ReadOnlyMacCommand) throws -> Data
  }

  struct FoundationReadOnlyMacCommandRunner: ReadOnlyMacCommandRunning {
    func run(_ command: ReadOnlyMacCommand) throws -> Data {
      let process = Process()
      let output = Pipe()
      let error = Pipe()
      process.executableURL = command.executableURL
      process.arguments = command.arguments
      process.standardOutput = output
      process.standardError = error

      try process.run()
      let outputData = output.fileHandleForReading.readDataToEndOfFile()
      _ = error.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      guard process.terminationReason == .exit,
        process.terminationStatus == 0
      else {
        throw AppleSiliconHostInspectionError.commandFailed(
          command.auditName,
          process.terminationStatus
        )
      }
      return outputData
    }
  }

  private struct ReadOnlyStorageProbe: Sendable {
    let commands: any ReadOnlyMacCommandRunning

    func inspect() throws -> (
      inspection: APFSStorageInspection,
      fileVaultEnabled: Bool,
      isInternal: Bool
    ) {
      let root = try propertyList(
        try commands.run(.rootDiskInfo),
        command: "diskutil-info-root"
      )
      let containerName = try string("APFSContainerReference", in: root)
      guard let container = APFSContainerIdentifier(containerName) else {
        throw AppleSiliconHostInspectionError.unsafeContainerIdentifier(
          containerName
        )
      }
      guard let stores = root["APFSPhysicalStores"] as? [[String: Any]],
        stores.count == 1,
        let physicalStore = stores[0]["APFSPhysicalStore"] as? String,
        isPartitionIdentifier(physicalStore)
      else {
        throw AppleSiliconHostInspectionError.invalidCommandResponse(
          "diskutil-info-root.APFSPhysicalStores"
        )
      }

      let limits = try propertyList(
        try commands.run(.apfsResizeLimits(container)),
        command: "diskutil-apfs-resize-limits"
      )
      let size = try unsignedInteger("APFSContainerSize", in: root)
      let free = try unsignedInteger("APFSContainerFree", in: root)
      let minimum = try unsignedInteger("MinimumSizePreferred", in: limits)
      let isInternal = try boolean("Internal", in: root)
      let fileVault = try boolean("FileVault", in: root)

      guard size > 0, free <= size, minimum <= size else {
        throw AppleSiliconHostInspectionError.unsupportedStorage(
          "invalid-apfs-size-relationship"
        )
      }

      return (
        inspection: APFSStorageInspection(
          containerIdentifier: container.rawValue,
          physicalStoreIdentifier: physicalStore,
          isInternal: isInternal,
          containerSizeBytes: size,
          containerFreeBytes: free,
          minimumPreferredSizeBytes: minimum
        ),
        fileVaultEnabled: fileVault,
        isInternal: isInternal
      )
    }

    private func propertyList(
      _ data: Data,
      command: String
    ) throws -> [String: Any] {
      guard
        let value = try? PropertyListSerialization.propertyList(
          from: data,
          options: [],
          format: nil
        ) as? [String: Any]
      else {
        throw AppleSiliconHostInspectionError.invalidCommandResponse(command)
      }
      return value
    }

    private func string(
      _ key: String,
      in values: [String: Any]
    ) throws -> String {
      guard let value = values[key] as? String else {
        throw AppleSiliconHostInspectionError.invalidCommandResponse(
          "diskutil.\(key)"
        )
      }
      return value
    }

    private func unsignedInteger(
      _ key: String,
      in values: [String: Any]
    ) throws -> UInt64 {
      guard let value = values[key] as? NSNumber else {
        throw AppleSiliconHostInspectionError.invalidCommandResponse(
          "diskutil.\(key)"
        )
      }
      return value.uint64Value
    }

    private func boolean(
      _ key: String,
      in values: [String: Any]
    ) throws -> Bool {
      guard let value = values[key] as? NSNumber else {
        throw AppleSiliconHostInspectionError.invalidCommandResponse(
          "diskutil.\(key)"
        )
      }
      return value.boolValue
    }

    private func isPartitionIdentifier(_ value: String) -> Bool {
      guard value.hasPrefix("disk"),
        let separator = value.lastIndex(of: "s")
      else {
        return false
      }
      let disk = value[value.index(value.startIndex, offsetBy: 4)..<separator]
      let partition = value[value.index(after: separator)...]
      return !disk.isEmpty && !partition.isEmpty
        && disk.allSatisfy(\.isNumber)
        && partition.allSatisfy(\.isNumber)
    }
  }
#endif
