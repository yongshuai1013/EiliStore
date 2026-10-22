Vendored source provenance

- AnisetteKit source: mahee96/AnisetteKit, commit db8b41022697b6c19be8a5f01a1ce834145a2a26. The upstream LICENSE is retained as LICENSE.
- Unicorn source used by Scripts/build-on-device-anisette.sh: mahee96/unicorn, commit a53ddc9ac6d65b24936d4a37917333fcd816cfd0 (audit checkout reports abbreviated revision a53ddc9a). Its upstream QEMU license is retained as UNICORN-LICENSE.
- The prebuilt release Unicorn.xcframework is intentionally not used. The build script compiles the pinned sources locally for iOS arm64 with TCI enabled (no native JIT), Release configuration, and logging disabled; it removes generated HAVE_PTHREAD_JIT_PROTECT and audits decoded archive instructions before replacing Artifacts/Unicorn.xcframework.

Local integration changes (not upstream claims):
- SwiftPM uses a locally built Unicorn XCFramework. The standard production project.yml supplies EILI_ON_DEVICE_ANISETTE and links this local package; remote remains the runtime default, with explicit user selection required for On-Device mode.
- Native initialization returns loader failures instead of aborting, validates setup operations, and catches C++ exceptions at Unicorn C entry points. Virtual allocator exhaustion returns a guest null allocation rather than aborting; this is not a guarantee against all malformed-library or memory-pressure failures.
- The reset API serializes VM destruction, closes guest host-file handles, and clears cached provisioning/library state after import or reset.
- Swift debug logging obeys the logging toggle. No production Anisette payload logging is enabled by this integration.

Build on macOS with Scripts/build-idevice-ios15.sh and Scripts/build-on-device-anisette.sh, then generate the standard app project with `xcodegen generate --spec project.yml`. Both project-on-device.yml and project-ios15-validation.yml are compatibility aliases for that same project. Scripts/prepare-anisette-ios15.sh is a compatibility entry point for building the canonical local dependency, not a second package override. The root local AnisetteKit dependency overrides SideSign's transitive dependency of the same identity; CI checks the actual native compile, active App Link Map symbol, and linked Unicorn archive.

Validation boundary: Linux contract tests and unsigned Apple archives do not establish successful provisioning/login or crash-free operation on iPhone 7 / iOS 15.8.5. The engine is included, but libCoreADI.so and libstoreservicescore.so are not bundled: users must import their own trusted ARM64 libraries before selecting On-Device for their next login. Existing sessions retain their original mode.
