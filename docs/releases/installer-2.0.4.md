# Installer 2.0.4 — published 2026-09-07

App source: 33081e05d57e739365505814e1ba58263a4e02ee on main.
Bundle version: 2026090714. This combines the approved smaller Osaka Jade icon,
installer layout, removal and app performance improvements, and RC (Aurora)
selection. Main was pushed before production packaging.

- Package: Omarchy-MX-Mac-Installer-2.0.4.pkg
- Size: 19,754,357 bytes
- SHA-256: 60751a333df7726537c3efa4181bd0bbad79475bb1d89fa08d1ce01d45a0e9d9
- App signing: Developer ID Application, team T2C384FJBD
- Package signing: Developer ID Installer, team T2C384FJBD
- App notarization: 06e66ee8-40ce-4ffb-889b-8a9626c8f8a3, accepted and stapled
- Package notarization: 37bebba8-4c6f-4344-81d8-31cea43eed65, accepted and stapled
- Gatekeeper accepted both the app and package as Notarized Developer ID.

Published to the existing RC application lane:

- [Current RC installer](https://downloads.aicodelabs.com.au/installer/rc/Omarchy-MX-Mac-Installer.pkg)
- [Immutable 2.0.4 package](https://downloads.aicodelabs.com.au/installer/2.0.4/Omarchy-MX-Mac-Installer-2.0.4.pkg)
- [Immutable checksum](https://downloads.aicodelabs.com.au/installer/2.0.4/Omarchy-MX-Mac-Installer-2.0.4.pkg.sha256)

The RC package, RC metadata, immutable package, and checksum were downloaded
and verified against the final stapled bytes. The application extracted from
the published package retained its signature, stapled ticket, approved icon,
and expected version. No OS catalog or payload channel was promoted.

The merged implementation passed 329 debug and 323 release Swift tests,
strict Swift formatting, and eight affected shell checks. RC (Aurora) was
visually verified in the simulator before this version-only release bump.

The public package was copied over verified Thunderbolt transport to the
M1 Pro Desktop as `Omarchy MX Mac Installer 2.0.4.pkg`; its size and digest were
verified there. It was left unopened for manual installation. The installed
M1 application and helper were not replaced by this release task.
