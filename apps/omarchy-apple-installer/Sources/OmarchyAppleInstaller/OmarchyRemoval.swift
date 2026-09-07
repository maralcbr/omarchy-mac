#if os(macOS)
  import Foundation
  import OpenDirectory

  /// The helper owns the disk plan. The client can only return this expiring ticket.
  public struct OmarchyRemovalTicket: Codable, Equatable, Sendable {
    public let id: UUID
    public let reclaimBytes: UInt64
    public let macOSBytesAfter: UInt64
    public init(id: UUID, reclaimBytes: UInt64, macOSBytesAfter: UInt64) {
      self.id = id
      self.reclaimBytes = reclaimBytes
      self.macOSBytesAfter = macOSBytesAfter
    }
    public static let confirmation = "delete omarchy installation and data"
  }

  public struct OmarchyRemovalReply: Codable, Sendable {
    public let ticket: OmarchyRemovalTicket?
    public let completed: Bool
    public let requiresReview: Bool
    public let message: String
    public init(
      ticket: OmarchyRemovalTicket? = nil, completed: Bool = false, requiresReview: Bool = false,
      message: String
    ) {
      self.ticket = ticket
      self.completed = completed
      self.requiresReview = requiresReview
      self.message = message
    }
  }

  struct RemovalFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  struct RemovalPartition: Codable, Equatable, Sendable {
    let identifier: String
    let uuid: String
    let type: String
    let offset: UInt64
    var size: UInt64
    let name: String
    var end: UInt64 { offset + size }
    // BSD identifiers can change after deleting another partition. Identity cannot.
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.uuid == rhs.uuid && lhs.type == rhs.type && lhs.offset == rhs.offset
        && lhs.size == rhs.size && lhs.name == rhs.name
    }
  }

  struct RemovalVolume: Codable, Equatable, Sendable {
    let uuid: String
    let name: String
    let roles: [String]
  }

  struct RemovalContainer: Codable, Equatable, Sendable {
    let uuid: String
    let storeUUID: String
    let volumes: [RemovalVolume]
  }

  struct RemovalSnapshot: Codable, Equatable, Sendable {
    let disk: String
    let devicePath: String
    let diskSize: UInt64
    let macOSStoreUUID: String
    let macOSContainerUUID: String
    var partitions: [RemovalPartition]
    var containers: [RemovalContainer]
  }

  struct OmarchyRemovalPlan: Codable, Equatable, Sendable {
    let snapshot: RemovalSnapshot
    let members: [RemovalPartition]
    let macOS: RemovalPartition
    let targetMacOSBytes: UInt64

    init(snapshot: RemovalSnapshot) throws {
      let parts = snapshot.partitions.sorted { $0.offset < $1.offset }
      // A deliberately narrow layout: Apple ISC, booted macOS, exactly one complete
      // Omarchy installation, Apple Recovery. Unknown and partial layouts are refused.
      guard parts.count == 7,
        parts[0].type == "Apple_APFS_ISC", parts[6].type == "Apple_APFS_Recovery",
        parts[1].type == "Apple_APFS", parts[1].uuid == snapshot.macOSStoreUUID,
        parts[2].type == "Apple_APFS", parts[2].size <= 4 * 1_024 * 1_024 * 1_024,
        parts[3].type == "EFI", parts[3].name == "EFI - OMARC",
        parts[4].type == "Linux Filesystem", parts[5].type == "Linux Filesystem",
        Set(parts.map(\.uuid)).count == parts.count,
        zip(parts, parts.dropFirst()).allSatisfy({ $0.end <= $1.offset }),
        (2...4).allSatisfy({ parts[$0].end == parts[$0 + 1].offset }),
        parts.last!.end <= snapshot.diskSize
      else {
        throw RemovalFailure(
          message:
            "No complete Omarchy installation with space that can be returned to this macOS partition was found. Partial installations and unfamiliar disk layouts need a separate review. Nothing was changed."
        )
      }
      guard let stub = snapshot.containers.first(where: { $0.storeUUID == parts[2].uuid }),
        stub.volumes.count == 4,
        Set(stub.volumes.map(\.uuid)).count == 4,
        stub.volumes.filter({ $0.roles == ["System"] && $0.name == "Omarchy" }).count == 1,
        stub.volumes.filter({
          $0.roles == ["Data"] && ["Omarchy - Data", "Omarchy-Data"].contains($0.name)
        }).count == 1,
        stub.volumes.filter({ $0.roles == ["Preboot"] && $0.name == "Preboot" }).count == 1,
        stub.volumes.filter({ $0.roles == ["Recovery"] && $0.name == "Recovery" }).count == 1,
        snapshot.containers.filter({
          $0.storeUUID == parts[1].uuid && $0.uuid == snapshot.macOSContainerUUID
        }).count == 1
      else {
        throw RemovalFailure(
          message:
            "The Omarchy startup container could not be identified unambiguously. Nothing was changed."
        )
      }
      self.snapshot = snapshot
      members = Array(parts[2...5])
      macOS = parts[1]
      targetMacOSBytes = parts[6].offset - parts[1].offset
    }

    var reclaimBytes: UInt64 { targetMacOSBytes - macOS.size }

    /// Every intermediate state must be exactly the approved layout minus the
    /// partitions already removed. This also proves the gap is adjacent to macOS.
    func validate(_ current: RemovalSnapshot, removed: Set<String>, expanded: Bool = false) throws {
      guard current.disk == snapshot.disk, current.devicePath == snapshot.devicePath,
        current.diskSize == snapshot.diskSize, current.macOSStoreUUID == snapshot.macOSStoreUUID,
        current.macOSContainerUUID == snapshot.macOSContainerUUID
      else { throw RemovalFailure(message: "The disk identity changed. Removal stopped.") }
      var expected = snapshot.partitions.filter { !removed.contains($0.uuid) }
      if expanded {
        guard let actual = current.partitions.first(where: { $0.uuid == macOS.uuid }),
          actual.size > macOS.size, actual.size <= targetMacOSBytes,
          targetMacOSBytes - actual.size <= 1_048_576,
          let index = expected.firstIndex(where: { $0.uuid == macOS.uuid })
        else { throw RemovalFailure(message: "macOS did not reclaim the expected space.") }
        expected[index].size = actual.size
      }
      guard
        expected.sorted(by: { $0.offset < $1.offset })
          == current.partitions.sorted(by: { $0.offset < $1.offset }),
        snapshot.containers.filter({ !removed.contains($0.storeUUID) }).sorted(by: {
          $0.uuid < $1.uuid
        })
          == current.containers.sorted(by: { $0.uuid < $1.uuid })
      else {
        throw RemovalFailure(message: "The disk layout changed unexpectedly. Removal stopped.")
      }
    }
  }

  protocol RemovalDiskOperating: Sendable {
    func snapshot() throws -> RemovalSnapshot
    func deleteContainer(storeUUID: String) throws
    func erasePartition(uuid: String) throws
    func growContainer(storeUUID: String) throws
  }

  struct OmarchyRemovalExecutor: Sendable {
    let disks: any RemovalDiskOperating

    func execute(_ plan: OmarchyRemovalPlan, record: (String) throws -> Void) throws {
      try plan.validate(disks.snapshot(), removed: [])
      var removed = Set<String>()
      // Delete the startup container first: if a volume is busy, diskutil refuses
      // before the Linux partitions are touched. No force-unmount or -force fallback.
      for (index, member) in plan.members.enumerated() {
        try plan.validate(disks.snapshot(), removed: removed)
        try record("removing-\(member.uuid)")
        if index == 0 {
          // Without a new name, current macOS deletes the physical store too.
          try disks.deleteContainer(storeUUID: member.uuid)
        } else {
          try disks.erasePartition(uuid: member.uuid)
        }
        removed.insert(member.uuid)
        try plan.validate(disks.snapshot(), removed: removed)
      }
      try record("returning-space-to-macos")
      try plan.validate(disks.snapshot(), removed: removed)
      try disks.growContainer(storeUUID: plan.macOS.uuid)
      try plan.validate(disks.snapshot(), removed: removed, expanded: true)
      try record("complete")
    }
  }

  /// All executable paths and verbs are fixed here, never supplied by the XPC peer.
  struct MacRemovalDiskOperator: RemovalDiskOperating {
    var commands: @Sendable ([String]) throws -> Data = Self.systemRun
    var targetType: @Sendable () throws -> String = {
      try SysctlHardwarePropertyReader().string(named: "hw.targettype")
    }

    func snapshot() throws -> RemovalSnapshot {
      let target = try targetType().lowercased()
      guard target != "j614s", target != "apple,j614s" else {
        throw RemovalFailure(message: "Removal is not supported on this Mac model.")
      }
      let root = try plist(["info", "-plist", "/"])
      guard root["Internal"] as? Bool == true,
        let stores = root["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
        let store = stores.first?["APFSPhysicalStore"] as? String,
        let rootReference = root["APFSContainerReference"] as? String
      else { throw invalid() }
      let physical = try plist(["info", "-plist", store])
      let disk = try string(physical, "ParentWholeDisk")
      let diskInfo = try plist(["info", "-plist", disk])
      guard diskInfo["Internal"] as? Bool == true,
        diskInfo["WholeDisk"] as? Bool == true,
        ["Physical", "Unknown"].contains(diskInfo["VirtualOrPhysical"] as? String ?? ""),
        diskInfo["Content"] as? String == "GUID_partition_scheme"
      else { throw invalid() }
      // Apple NVMe disks can report VirtualOrPhysical=Unknown in `info`.
      // Require membership in diskutil's independent internal/physical listing;
      // never infer that Unknown alone means a physical disk.
      let list = try plist(["list", "-plist", "internal", "physical"])
      guard let whole = list["AllDisksAndPartitions"] as? [[String: Any]],
        whole.filter({ $0["DeviceIdentifier"] as? String == disk }).count == 1,
        let entry = whole.first(where: { $0["DeviceIdentifier"] as? String == disk }),
        entry["Content"] as? String == "GUID_partition_scheme",
        let records = entry["Partitions"] as? [[String: Any]], records.count <= 32
      else { throw invalid() }
      let parts = try records.map { item -> RemovalPartition in
        let info = try plist(["info", "-plist", try string(item, "DeviceIdentifier")])
        guard try string(info, "ParentWholeDisk") == disk else { throw invalid() }
        let offset = try number(info, "PartitionMapPartitionOffset")
        let size = try number(info, "Size")
        guard size > 0, !offset.addingReportingOverflow(size).overflow else { throw invalid() }
        return RemovalPartition(
          identifier: try string(info, "DeviceIdentifier"), uuid: try uuid(info, "DiskUUID"),
          type: try string(info, "Content"), offset: offset, size: size,
          name: info["VolumeName"] as? String ?? "")
      }.sorted { $0.offset < $1.offset }
      let apfs = try plist(["apfs", "list", "-plist"])
      guard let rawContainers = apfs["Containers"] as? [[String: Any]] else { throw invalid() }
      var containers = [RemovalContainer]()
      var rootUUID: String?
      for raw in rawContainers {
        guard let physicalStores = raw["PhysicalStores"] as? [[String: Any]] else {
          throw invalid()
        }
        let matching = physicalStores.compactMap { item in
          parts.first { $0.identifier == item["DeviceIdentifier"] as? String }
        }
        if matching.isEmpty { continue }
        guard matching.count == 1, physicalStores.count == 1,
          let volumes = raw["Volumes"] as? [[String: Any]]
        else { throw invalid() }
        let parsed = try volumes.map { item -> RemovalVolume in
          guard let roles = item["Roles"] as? [String] else { throw invalid() }
          return RemovalVolume(
            uuid: try uuid(item, "APFSVolumeUUID"), name: try string(item, "Name"),
            roles: roles.sorted())
        }.sorted { $0.uuid < $1.uuid }
        let containerUUID = try uuid(raw, "APFSContainerUUID")
        if raw["ContainerReference"] as? String == rootReference { rootUUID = containerUUID }
        containers.append(
          RemovalContainer(uuid: containerUUID, storeUUID: matching[0].uuid, volumes: parsed))
      }
      guard let rootUUID else { throw invalid() }
      return RemovalSnapshot(
        disk: disk, devicePath: try string(diskInfo, "DeviceTreePath"),
        diskSize: try number(diskInfo, "Size"), macOSStoreUUID: try uuid(physical, "DiskUUID"),
        macOSContainerUUID: rootUUID, partitions: parts,
        containers: containers.sorted { $0.uuid < $1.uuid })
    }

    func deleteContainer(storeUUID: String) throws {
      try mutate(["apfs", "deleteContainer", storeUUID])
    }
    func erasePartition(uuid: String) throws { try mutate(["eraseVolume", "free", "none", uuid]) }
    func growContainer(storeUUID: String) throws {
      try mutate(["apfs", "resizeContainer", storeUUID, "0"])
    }

    private func mutate(_ arguments: [String]) throws { _ = try run(arguments) }
    private func plist(_ arguments: [String]) throws -> [String: Any] {
      guard
        let value = try PropertyListSerialization.propertyList(from: run(arguments), format: nil)
          as? [String: Any]
      else { throw invalid() }
      return value
    }
    private func run(_ arguments: [String]) throws -> Data { try commands(arguments) }

    private static func systemRun(_ arguments: [String]) throws -> Data {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
      process.arguments = arguments
      process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      try process.run()
      let result = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw RemovalFailure(
          message:
            "macOS could not complete the disk operation (code \(process.terminationStatus)).")
      }
      guard result.count <= 8 * 1_024 * 1_024 else {
        throw RemovalFailure(message: "The disk response was too large.")
      }
      return result
    }
    private func string(_ value: [String: Any], _ key: String) throws -> String {
      guard let result = value[key] as? String, !result.isEmpty else { throw invalid() }
      return result
    }
    private func uuid(_ value: [String: Any], _ key: String) throws -> String {
      guard let result = UUID(uuidString: try string(value, key)) else { throw invalid() }
      return result.uuidString
    }
    private func number(_ value: [String: Any], _ key: String) throws -> UInt64 {
      guard let result = value[key] as? NSNumber, result.int64Value >= 0 else { throw invalid() }
      return result.uint64Value
    }
    private func invalid() -> RemovalFailure {
      RemovalFailure(
        message: "The internal macOS disk layout could not be verified.")
    }
  }

  func requireRemovalAdministrator(_ authorization: MachineOwnerAuthorization) throws {
    let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
    let user = try node.record(
      withRecordType: kODRecordTypeUsers, name: authorization.username, attributes: nil)
    let admin = try node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: nil)
    do { try admin.isMemberRecord(user) } catch {
      throw RemovalFailure(message: "Use a macOS administrator account to remove Omarchy.")
    }
  }
#endif
