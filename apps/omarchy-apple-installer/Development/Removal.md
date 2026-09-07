# Removing an existing Omarchy installation

Use **Installation → Remove Omarchy…** while no installation or download is
running. The app displays the capacity returned to macOS and requires the exact
phrase `delete omarchy installation and data`, plus a macOS administrator account
and password. There is no Return-key shortcut for the destructive button.

Removal uses the signed privileged helper directly. It does not download an OS,
engine, IPSW or catalog. The helper owns a five-minute, single-use plan; the client
sends an opaque ticket, never disk identifiers or commands. Cancellation performs
no disk mutation. Credentials are not written to the removal journal.

## Supported layout

The booted internal macOS physical store must precede one complete Omarchy group:
Apple APFS startup container (at most 4 GiB, exactly Omarchy System/Data and
Preboot/Recovery volumes), Omarchy EFI, Linux boot, Linux root. The four removal
partitions must be contiguous. Apple ISC must precede macOS and Apple Recovery
must follow Omarchy. Gaps immediately before and after Omarchy are reclaimed too.

Unknown partitions, multiple or partial installations, external boot, multiple
APFS physical stores, mismatched names/types/UUIDs and explicitly unsupported
`apple,j614s` are refused. This deliberately does not attempt general disk repair.

The helper validates disk/partition/container/volume identities before the first
write and after each operation. It deletes the startup container without a
replacement name (modern diskutil also deletes its physical-store partition),
then erases EFI/boot/root by GPT partition UUID. It grows the bound macOS store
with `diskutil apfs resizeContainer <macOS-store-UUID> 0`. Success requires the
expected size increase and unchanged Apple ISC, macOS identities and Recovery.

Apple's local `diskutil(8)` documentation was checked for deleteContainer,
resizeContainer and UUID device addressing. No force-delete fallback is used.

## Interrupted removal

The root-owned helper directory contains `removal-<ticket UUID>.json`. The plan
and next phase are written atomically, and the file and containing directory are
synchronized before each mutation. A journal not marked `complete` prevents new
installation/removal requests, including after a helper restart. Never delete or
mark that journal complete merely to bypass the block: reconcile its approved
UUIDs with the actual disk layout first. A failed resize can leave all Omarchy
partitions removed with the space still unallocated. Do not replay deletion.

Connection loss locks the app's further disk actions; it does not claim that the
helper stopped or that no writes occurred. A successful removal refreshes the
installer's inspection so an old installation plan cannot be reused.

## Verification and simulator

In a debug `--simulate` run, choose the same menu action and use **Removal test**
inside the popup. Cases: complete removal, no installation, unfamiliar/partial
layout, helper unavailable, incorrect password, changed disk, deletion
interrupted, macOS resize failed and connection lost. The exact phrase is still
required. Simulation uses no helper, disks, passwords or downloads. A simulation
blocked by an uncertain outcome has a separate **Reset simulation** action.

`OmarchyRemovalTests` exercises the real planner/executor with in-memory disk
operations, native plist parsing, every failed command position, journal failure,
protected identity drift, no-op growth, administrator rejection, exact phrase,
foreign/replayed tickets, interrupted-helper restart and concurrent install/removal
rejection. The running UI was checked for disabled near-match confirmation,
enabled exact confirmation, success and light/dark appearance.

Physical removal has not been executed for this feature. The M1 Thunderbolt route
was unavailable during development. Before a physical test, deploy both the new
app and helper, check the current disk layout and obtain explicit authorization
for that removal run. Keep the app closed when preparing the M1 for manual use.
