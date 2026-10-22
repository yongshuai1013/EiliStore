Vendored source provenance

- AnisetteKit source: mahee96/AnisetteKit, commit db8b41022697b6c19be8a5f01a1ce834145a2a26. The upstream LICENSE is retained as LICENSE.
- Unicorn source used by Scripts/build-on-device-anisette.sh: mahee96/unicorn, commit a53ddc9ac6d65b24936d4a37917333fcd816cfd0 (audit checkout reports abbreviated revision a53ddc9a). Its upstream QEMU license is retained as UNICORN-LICENSE.
- The prebuilt release Unicorn.xcframework is intentionally not used. The build script compiles the pinned sources locally for iOS arm64 with TCI enabled (no native JIT), Release configuration, and logging disabled; it removes generated HAVE_PTHREAD_JIT_PROTECT and audits decoded archive instructions before replacing Artifacts/Unicorn.xcframework.

Local integration changes (not upstream claims):
- SwiftPM uses a locally built Unicorn XCFramework; the optional app specification supplies EILI_ON_DEVICE_ANISETTE.
- Native initialization returns loader failures instead of aborting, validates setup operations, and catches C++ exceptions at Unicorn C entry points. Virtual allocator exhaustion returns a guest null allocation rather than aborting; this is not a guarantee against all malformed-library or memory-pressure failures.
- The reset API serializes VM destruction, closes guest host-file handles, and clears cached provisioning/library state after import or reset.
- Swift debug logging obeys the logging toggle. No production Anisette payload logging is enabled by this integration.

Validation boundary: local Linux syntax/contract tests do not establish an Apple link, successful provisioning/login, or crash-free operation on iPhone 7 / iOS 15.8.5. Build on macOS with Scripts/build-on-device-anisette.sh, then generate the optional app project with `xcodegen generate --spec project-on-device.yml`. The unchanged project.yml remains the remote-default build path. The optional spec's root local AnisetteKit dependency is intended to override SideSign's transitive dependency of the same identity; verify resolved package references and the final link in Xcode before device distribution.
