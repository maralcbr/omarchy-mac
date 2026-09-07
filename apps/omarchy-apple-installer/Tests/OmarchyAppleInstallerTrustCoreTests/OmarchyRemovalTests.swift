#if os(macOS)
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class OmarchyRemovalTests: XCTestCase {
    func testPlanReturnsOmarchyAndBothAdjacentFreeGapsToMacOS() throws {
      let plan = try OmarchyRemovalPlan(snapshot: fixture())
      XCTAssertEqual(plan.members.map(\.uuid), ["stub", "efi", "boot", "linux"])
      XCTAssertEqual(plan.reclaimBytes, 275_000_000_000)
      XCTAssertEqual(plan.targetMacOSBytes, 994_000_000_000)
    }

    func testUnknownExtraPartitionAndIncompleteInstallationAreRefused() {
      for index in 0..<7 {
        var snapshot = fixture()
        snapshot.partitions.remove(at: index)
        XCTAssertThrowsError(try OmarchyRemovalPlan(snapshot: snapshot))
      }
      var snapshot = fixture()
      snapshot.partitions.append(snapshot.partitions[3])
      XCTAssertThrowsError(try OmarchyRemovalPlan(snapshot: snapshot))
    }

    func testWrongTypesLabelsAndGapsAreRefused() {
      let mutations: [(Int, String?, String?, UInt64?)] = [
        (2, "Apple_APFS_Recovery", nil, nil), (3, "Apple_APFS", nil, nil),
        (3, nil, "EFI", nil), (4, "Microsoft Basic Data", nil, nil),
        (5, nil, nil, 735_000_000_001),
      ]
      for (index, type, name, offset) in mutations {
        var snapshot = fixture()
        let old = snapshot.partitions[index]
        snapshot.partitions[index] = RemovalPartition(
          identifier: old.identifier, uuid: old.uuid, type: type ?? old.type,
          offset: offset ?? old.offset, size: old.size, name: name ?? old.name)
        XCTAssertThrowsError(try OmarchyRemovalPlan(snapshot: snapshot))
      }
    }

    func testAdditionalOrRenamedStubVolumesAreRefused() {
      var snapshot = fixture()
      let original = snapshot.containers[1]
      snapshot.containers[1] = RemovalContainer(
        uuid: original.uuid, storeUUID: original.storeUUID,
        volumes: original.volumes + [
          RemovalVolume(uuid: "extra", name: "Other macOS", roles: ["System"])
        ])
      XCTAssertThrowsError(try OmarchyRemovalPlan(snapshot: snapshot))
      snapshot.containers[1] = RemovalContainer(
        uuid: original.uuid, storeUUID: original.storeUUID,
        volumes: original.volumes.dropLast() + [
          RemovalVolume(uuid: "changed", name: "Other", roles: ["System"])
        ])
      XCTAssertThrowsError(try OmarchyRemovalPlan(snapshot: snapshot))
    }

    func testBootedMacOSCannotBeRemovalTarget() {
      let original = fixture()
      let snapshot = RemovalSnapshot(
        disk: original.disk, devicePath: original.devicePath, diskSize: original.diskSize,
        macOSStoreUUID: "stub", macOSContainerUUID: "stub-container",
        partitions: original.partitions, containers: original.containers)
      XCTAssertThrowsError(try OmarchyRemovalPlan(snapshot: snapshot))
    }

    func testExecutionPreservesApplePartitionsAndGrowsMacOSByUUID() throws {
      let disk = FakeRemovalDisk()
      let original = try disk.snapshot()
      let plan = try OmarchyRemovalPlan(snapshot: original)
      var journal = [String]()
      try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) }
      XCTAssertEqual(
        disk.operations, ["container:stub", "erase:efi", "erase:boot", "erase:linux", "grow:mac"])
      let result = try disk.snapshot()
      XCTAssertEqual(result.partitions.first, original.partitions.first)
      XCTAssertEqual(result.partitions.last, original.partitions.last)
      XCTAssertEqual(result.partitions.count, 3)
      XCTAssertEqual(result.partitions[1].size, plan.targetMacOSBytes)
      XCTAssertEqual(journal.last, "complete")
    }

    func testEveryCommandFailureStopsWithoutReplayingOrGrowing() throws {
      for failure in 1...5 {
        let disk = FakeRemovalDisk(failAt: failure)
        let plan = try OmarchyRemovalPlan(snapshot: disk.snapshot())
        XCTAssertThrowsError(try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in })
        XCTAssertEqual(disk.operations.count, failure)
        XCTAssertEqual(disk.state.partitions[0].uuid, "isc")
        XCTAssertEqual(disk.state.partitions.last?.uuid, "recovery")
        XCTAssertEqual(disk.state.partitions[1].size, plan.macOS.size)
      }
    }

    func testJournalFailurePreventsFirstMutation() throws {
      let disk = FakeRemovalDisk()
      let plan = try OmarchyRemovalPlan(snapshot: disk.snapshot())
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in
          throw RemovalFailure(message: "journal full")
        })
      XCTAssertTrue(disk.operations.isEmpty)
    }

    func testChangedMacOSOrRecoveryIdentityStopsBeforeDeletion() throws {
      for index in [0, 1, 6] {
        let disk = FakeRemovalDisk()
        let plan = try OmarchyRemovalPlan(snapshot: disk.snapshot())
        disk.state.partitions[index].size += 4096
        XCTAssertThrowsError(try OmarchyRemovalExecutor(disks: disk).execute(plan) { _ in })
        XCTAssertTrue(disk.operations.isEmpty)
      }
    }

    func testSuccessfulCommandWithoutActualGrowthIsNotSuccess() throws {
      let disk = FakeRemovalDisk(skipGrowth: true)
      let plan = try OmarchyRemovalPlan(snapshot: disk.snapshot())
      var journal = [String]()
      XCTAssertThrowsError(
        try OmarchyRemovalExecutor(disks: disk).execute(plan) { journal.append($0) })
      XCTAssertFalse(journal.contains("complete"))
    }

    func testRenumberedBSDIdentifiersStillMatchUUIDBoundPlan() throws {
      let plan = try OmarchyRemovalPlan(snapshot: fixture())
      var changed = fixture()
      changed.partitions = changed.partitions.enumerated().map { index, part in
        RemovalPartition(
          identifier: "disk0s\(index + 20)", uuid: part.uuid, type: part.type, offset: part.offset,
          size: part.size, name: part.name)
      }
      XCTAssertNoThrow(try plan.validate(changed, removed: []))
    }

    func testM4RejectedBeforeDiskCommands() {
      let disk = MacRemovalDiskOperator(
        commands: { _ in
          XCTFail("No disk command expected")
          return Data()
        }, targetType: { "j614s" })
      XCTAssertThrowsError(try disk.snapshot())
    }

    func testServerEnforcesExactPhraseAndSingleUseTicket() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk()
      let server = server(root: root, disk: disk)
      let inspection = try await server.removal(ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      for phrase in [
        "", "delete omarchy", "Delete omarchy installation and data",
        OmarchyRemovalTicket.confirmation + " ",
      ] {
        do {
          _ = try await server.removal(
            ticketID: ticket.id, confirmation: phrase, authorization: authorization())
          XCTFail("Incorrect phrase accepted")
        } catch {}
        XCTAssertTrue(disk.operations.isEmpty)
      }
      let result = try await server.removal(
        ticketID: ticket.id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertTrue(result.completed, result.message)
      do {
        _ = try await server.removal(
          ticketID: ticket.id, confirmation: OmarchyRemovalTicket.confirmation,
          authorization: authorization())
        XCTFail("Replayed ticket accepted")
      } catch {}
      XCTAssertEqual(disk.operations.count, 5)
    }

    func testCredentialAndAdministratorRejectionPrecedeDeletion() async throws {
      for rejectAdmin in [false, true] {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = FakeRemovalDisk()
        let service = ClosedEngineHelperServer(
          workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
          credentialValidator: RemovalCredentials(reject: !rejectAdmin), removalDisks: disk,
          removalAdminValidator: { _ in
            if rejectAdmin { throw RemovalFailure(message: "not administrator") }
          })
        let inspection = try await service.removal(
          ticketID: nil, confirmation: "", authorization: nil)
        let result = try await service.removal(
          ticketID: XCTUnwrap(inspection.ticket).id,
          confirmation: OmarchyRemovalTicket.confirmation, authorization: authorization())
        XCTAssertFalse(result.completed)
        XCTAssertTrue(disk.operations.isEmpty)
      }
    }

    func testInterruptedJournalBlocksNewRequestsAfterHelperRestart() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk(failAt: 3)
      let first = server(root: root, disk: disk)
      let inspection = try await first.removal(ticketID: nil, confirmation: "", authorization: nil)
      let result = try await first.removal(
        ticketID: XCTUnwrap(inspection.ticket).id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertTrue(result.message.contains("some Omarchy data may already be deleted"))
      let restarted = server(root: root, disk: disk)
      do {
        _ = try await restarted.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("Interrupted removal was ignored")
      } catch { XCTAssertTrue(error.localizedDescription.contains("earlier removal")) }
    }

    func testResizeFailureReportsDataRemovedWithoutSuccess() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk(failAt: 5)
      let service = server(root: root, disk: disk)
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let result = try await service.removal(
        ticketID: XCTUnwrap(inspection.ticket).id, confirmation: OmarchyRemovalTicket.confirmation,
        authorization: authorization())
      XCTAssertFalse(result.completed)
      XCTAssertTrue(result.message.contains("Omarchy was removed"))
      XCTAssertFalse(result.message.contains("No disk changes"))
      let files = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      let data = try Data(contentsOf: XCTUnwrap(files.first))
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-password"))
    }

    func testNativePlistParserMatchesApprovedShapeAndUsesFixedCommands() throws {
      let replies = try diskPlists()
      let disk = MacRemovalDiskOperator(
        commands: { arguments in
          guard let reply = replies[arguments.joined(separator: " ")] else {
            XCTFail("Unexpected command: \(arguments)")
            throw RemovalFailure(message: "unexpected command")
          }
          return reply
        }, targetType: { "j314s" })
      let snapshot = try disk.snapshot()
      let plan = try OmarchyRemovalPlan(snapshot: snapshot)
      XCTAssertEqual(plan.reclaimBytes, 275_000_000_000)
      XCTAssertEqual(plan.members.count, 4)
      XCTAssertEqual(snapshot.containers.count, 2)
    }

    func testNativeParserAcceptsAppleSSDReportedAsUnknownWhenListedPhysical() throws {
      var responses = try diskPlists()
      var whole = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: responses["info -plist disk0"]!, format: nil)
          as? [String: Any])
      whole["VirtualOrPhysical"] = "Unknown"
      responses["info -plist disk0"] = try PropertyListSerialization.data(
        fromPropertyList: whole, format: .xml, options: 0)
      responses["list -plist internal physical"] = responses["list -plist disk0"]
      let replies = responses
      let disk = MacRemovalDiskOperator(
        commands: { arguments in
          guard let reply = replies[arguments.joined(separator: " ")] else {
            throw RemovalFailure(message: "unexpected command")
          }
          return reply
        }, targetType: { "j314s" })
      let plan = try OmarchyRemovalPlan(snapshot: disk.snapshot())
      XCTAssertEqual(plan.reclaimBytes, 275_000_000_000)
    }

    func testUnknownDiskMustBeListedAsInternalPhysical() throws {
      var responses = try diskPlists()
      var whole = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: responses["info -plist disk0"]!, format: nil)
          as? [String: Any])
      whole["VirtualOrPhysical"] = "Unknown"
      responses["info -plist disk0"] = try PropertyListSerialization.data(
        fromPropertyList: whole, format: .xml, options: 0)
      responses["list -plist internal physical"] = try PropertyListSerialization.data(
        fromPropertyList: ["AllDisksAndPartitions": []], format: .xml, options: 0)
      let replies = responses
      let disk = MacRemovalDiskOperator(
        commands: { replies[$0.joined(separator: " ")]! }, targetType: { "j314s" })
      XCTAssertThrowsError(try disk.snapshot())
    }

    func testExplicitlyVirtualDiskIsRejectedDespiteConflictingListing() throws {
      var responses = try diskPlists()
      var whole = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: responses["info -plist disk0"]!, format: nil)
          as? [String: Any])
      whole["VirtualOrPhysical"] = "Virtual"
      responses["info -plist disk0"] = try PropertyListSerialization.data(
        fromPropertyList: whole, format: .xml, options: 0)
      let replies = responses
      let disk = MacRemovalDiskOperator(
        commands: { replies[$0.joined(separator: " ")]! }, targetType: { "j314s" })
      XCTAssertThrowsError(try disk.snapshot())
    }

    func testNativeParserRejectsExternalAndMultiplePhysicalStores() throws {
      for changedRoot: [String: Any] in [
        [
          "Internal": false, "APFSContainerReference": "disk4",
          "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
        ],
        [
          "Internal": true, "APFSContainerReference": "disk4",
          "APFSPhysicalStores": [
            ["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk9s2"],
          ],
        ],
      ] {
        var responses = try diskPlists()
        responses["info -plist /"] = try PropertyListSerialization.data(
          fromPropertyList: changedRoot, format: .xml, options: 0)
        let replies = responses
        let disk = MacRemovalDiskOperator(
          commands: { replies[$0.joined(separator: " ")]! }, targetType: { "j314s" })
        XCTAssertThrowsError(try disk.snapshot())
      }
    }

    func testHelperRejectsForeignTicketBeforeAuthenticationOrDeletion() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = FakeRemovalDisk()
      let service = server(root: root, disk: disk)
      _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
      do {
        _ = try await service.removal(
          ticketID: UUID(), confirmation: OmarchyRemovalTicket.confirmation,
          authorization: authorization())
        XCTFail("Foreign ticket accepted")
      } catch {}
      XCTAssertTrue(disk.operations.isEmpty)
    }

    func testInstallAndAnotherRemovalAreBlockedWhileRemoving() async throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let disk = BlockingRemovalDisk()
      let service = ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: disk,
        removalAdminValidator: { _ in })
      let inspection = try await service.removal(
        ticketID: nil, confirmation: "", authorization: nil)
      let ticket = try XCTUnwrap(inspection.ticket)
      let auth = try authorization()
      let task = Task {
        try await service.removal(
          ticketID: ticket.id, confirmation: OmarchyRemovalTicket.confirmation, authorization: auth)
      }
      let entered = await Task.detached { disk.waitUntilEntered() }.value
      defer { disk.resume.signal() }
      XCTAssertTrue(entered)
      do {
        _ = try await service.removal(ticketID: nil, confirmation: "", authorization: nil)
        XCTFail("Concurrent removal accepted")
      } catch { XCTAssertEqual(error as? ClosedEngineHelperError, .busy) }
      do {
        _ = try await service.submit(packageDirectory: .standardInput, authorization: auth)
        XCTFail("Concurrent install accepted")
      } catch { XCTAssertEqual(error as? ClosedEngineHelperError, .busy) }
      disk.resume.signal()
      let result = try await task.value
      XCTAssertTrue(result.completed)
    }

    func testSystemAccountIsNotAcceptedAsAdministrator() throws {
      XCTAssertThrowsError(
        try requireRemovalAdministrator(
          MachineOwnerAuthorization(username: "nobody", password: Data("unused".utf8))))
    }

    private func server(root: URL, disk: FakeRemovalDisk) -> ClosedEngineHelperServer {
      ClosedEngineHelperServer(
        workingDirectory: root, executor: UnusedRemovalHandoffExecutor(),
        credentialValidator: RemovalCredentials(reject: false), removalDisks: disk,
        removalAdminValidator: { _ in })
    }
    private func authorization() throws -> MachineOwnerAuthorization {
      try MachineOwnerAuthorization(username: "test-admin", password: Data("test-password".utf8))
    }
    private func temporaryDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "removal-tests-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root
    }
  }

  private struct RemovalCredentials: MachineOwnerCredentialValidating {
    let reject: Bool
    func validate(_ authorization: MachineOwnerAuthorization) throws {
      if reject { throw RemovalFailure(message: "password rejected") }
    }
  }
  private struct UnusedRemovalHandoffExecutor: ImportedEngineHandoffExecuting {
    func execute(
      _ package: ImportedEngineHandoffPackage, authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data {
      XCTFail("Removal must not use the install engine")
      throw RemovalFailure(message: "unexpected install")
    }
  }

  /// These commands mutate only an in-memory partition map, exercising the real executor.
  private final class FakeRemovalDisk: RemovalDiskOperating, @unchecked Sendable {
    var state = fixture()
    var operations = [String]()
    let failAt: Int?
    let skipGrowth: Bool
    init(failAt: Int? = nil, skipGrowth: Bool = false) {
      self.failAt = failAt
      self.skipGrowth = skipGrowth
    }
    func snapshot() throws -> RemovalSnapshot { state }
    func deleteContainer(storeUUID: String) throws {
      try record("container:\(storeUUID)")
      state.partitions.removeAll { $0.uuid == storeUUID }
      state.containers.removeAll { $0.storeUUID == storeUUID }
    }
    func erasePartition(uuid: String) throws {
      try record("erase:\(uuid)")
      state.partitions.removeAll { $0.uuid == uuid }
    }
    func growContainer(storeUUID: String) throws {
      try record("grow:\(storeUUID)")
      if !skipGrowth, let index = state.partitions.firstIndex(where: { $0.uuid == storeUUID }) {
        state.partitions[index].size = 994_000_000_000
      }
    }
    private func record(_ operation: String) throws {
      operations.append(operation)
      if operations.count == failAt { throw RemovalFailure(message: "injected command failure") }
    }
  }

  private final class BlockingRemovalDisk: RemovalDiskOperating, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let disk = FakeRemovalDisk()
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func snapshot() throws -> RemovalSnapshot { try disk.snapshot() }
    func deleteContainer(storeUUID: String) throws {
      entered.signal()
      guard resume.wait(timeout: .now() + 10) == .success else {
        throw RemovalFailure(message: "test timeout")
      }
      try disk.deleteContainer(storeUUID: storeUUID)
    }
    func erasePartition(uuid: String) throws { try disk.erasePartition(uuid: uuid) }
    func growContainer(storeUUID: String) throws { try disk.growContainer(storeUUID: storeUUID) }
  }

  private func diskPlists() throws -> [String: Data] {
    let model = fixture()
    var objects = [String: [String: Any]]()
    func uuid(_ index: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", index) }
    let root: [String: Any] = [
      "Internal": true, "APFSContainerReference": "disk4",
      "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
    ]
    objects["info -plist /"] = root
    objects["info -plist disk0"] = [
      "Internal": true, "WholeDisk": true, "VirtualOrPhysical": "Physical",
      "Content": "GUID_partition_scheme", "DeviceTreePath": model.devicePath,
      "Size": model.diskSize,
    ]
    objects["list -plist disk0"] = [
      "AllDisksAndPartitions": [
        [
          "DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme",
          "Partitions": model.partitions.map { ["DeviceIdentifier": $0.identifier] },
        ]
      ]
    ]
    for (index, part) in model.partitions.enumerated() {
      objects["info -plist \(part.identifier)"] = [
        "DeviceIdentifier": part.identifier, "ParentWholeDisk": "disk0",
        "DiskUUID": uuid(index + 1), "Content": part.type,
        "PartitionMapPartitionOffset": part.offset, "Size": part.size, "VolumeName": part.name,
      ]
    }
    let containers: [[String: Any]] = model.containers.enumerated().map { index, container in
      let partition = model.partitions.first { $0.uuid == container.storeUUID }!
      let volumes: [[String: Any]] = container.volumes.enumerated().map { volumeIndex, volume in
        [
          "APFSVolumeUUID": uuid(100 + index * 10 + volumeIndex), "Name": volume.name,
          "Roles": volume.roles,
        ]
      }
      return [
        "ContainerReference": index == 0 ? "disk4" : "disk2", "APFSContainerUUID": uuid(50 + index),
        "PhysicalStores": [["DeviceIdentifier": partition.identifier]], "Volumes": volumes,
      ]
    }
    objects["list -plist internal physical"] = objects["list -plist disk0"]
    objects["apfs list -plist"] = ["Containers": containers]
    return try objects.mapValues {
      try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0)
    }
  }

  private func fixture() -> RemovalSnapshot {
    let rows: [(String, String, UInt64, UInt64, String)] = [
      ("isc", "Apple_APFS_ISC", 24_576, 524_288_000, ""),
      ("mac", "Apple_APFS", 1_000_000_000, 719_000_000_000, ""),
      ("stub", "Apple_APFS", 730_000_000_000, 2_500_000_000, ""),
      ("efi", "EFI", 732_500_000_000, 500_000_000, "EFI - OMARC"),
      ("boot", "Linux Filesystem", 733_000_000_000, 2_000_000_000, ""),
      ("linux", "Linux Filesystem", 735_000_000_000, 185_000_000_000, ""),
      ("recovery", "Apple_APFS_Recovery", 995_000_000_000, 5_000_000_000, ""),
    ]
    let parts = rows.enumerated().map { index, row in
      RemovalPartition(
        identifier: "disk0s\(index + 1)", uuid: row.0, type: row.1, offset: row.2, size: row.3,
        name: row.4)
    }
    let roles = ["System", "Data", "Preboot", "Recovery"]
    let names = ["Omarchy", "Omarchy - Data", "Preboot", "Recovery"]
    let stub = RemovalContainer(
      uuid: "stub-container", storeUUID: "stub",
      volumes: zip(roles, names).map { RemovalVolume(uuid: $0, name: $1, roles: [$0]) })
    let mac = RemovalContainer(
      uuid: "mac-container", storeUUID: "mac",
      volumes: [RemovalVolume(uuid: "mac-system", name: "Macintosh HD", roles: ["System"])])
    return RemovalSnapshot(
      disk: "disk0", devicePath: "IODeviceTree:/arm-io/ans", diskSize: 1_000_000_000_000,
      macOSStoreUUID: "mac", macOSContainerUUID: "mac-container", partitions: parts,
      containers: [mac, stub])
  }
#endif
