# Release preparation

The current metadata is **0.7.0, build 3**, in `Resources/Version.env`.
Builds never increment it. The application identifier remains `dev.farmac.app`
so upgrades continue using the same preferences. The original two-panel icon is
created by `script/render_icon.swift` with macOS AppKit and a deterministic ICNS PNG container.

## Local artifacts

Requirements: macOS 14 or newer, Xcode/Command Line Tools with Swift 6, and the
system libarchive/libcurl development libraries provided by that toolchain.
Run `script/test.sh`, then `script/package_release.sh`. The latter builds a
release executable for the current machine architecture, creates and validates
`dist/FarForMac.app`, and writes a versioned ZIP and SHA-256 sidecar. It does
not launch or quit any application. `script/build_and_run.sh --build-only`
creates a debug bundle; normal script run/debug modes are explicit launch modes.
Do not replace an installed app while it is open; save work and close it first.

Packaging uses a clean staging bundle, fixed archive timestamps, sorted ZIP
entries, and no ZIP extra fields. This is a repeatable packaging procedure;
Swift toolchain output and timestamped Developer ID signatures are not promised
to be byte-identical across machines or builds. Verify downloaded artifacts with
`shasum -a 256 -c FarForMac-<version>-<build>-<arch>.zip.sha256`.
After extracting, run `script/verify_bundle.sh /path/to/FarForMac.app`.

The bundled example extensions require **Python 3** on PATH. This interpreter
is not included and is not guaranteed on a clean macOS installation. Before
using these examples, check `command -v python3` and `python3 --version` in the
launch environment. The core application does not require Python. A release
that promises working bundled extensions on clean macOS must first bundle a
licensed runtime or replace these examples with a native helper.

The project's own code is covered by the proprietary evaluation license in
`LICENSE`, copyright 2026 Ivan Mezentsev. It grants free evaluation of 0.7.0
without a fixed expiry; it does not promise free future versions or grant
routine production use, redistribution or resale rights. Third-party license
rights, applicable GitHub hosting rights and mandatory legal exceptions are
preserved. See `docs/LICENSING.md` for an explanatory summary.

New bundles include `LICENSE` alongside `THIRD_PARTY_NOTICES.md`; verification
checks that the license covers the bundle's application version. A future
version requires an explicit licensing decision. The original published
0.7.0 build 3 ZIP is unchanged and accompanied by a separate LICENSE asset;
for that historical archive, use `codesign --verify --deep --strict` for the
signature check instead of the new validator requiring an embedded LICENSE.
The original v0.7.0 tag remains pinned to its release commit.

## Signing and notarization

Default builds are **ad-hoc signed** for local validation. They are not Developer
ID signed or notarized. A configured distribution machine can supply
`DEVELOPER_ID_IDENTITY='Developer ID Application: …' script/package_release.sh`.
The identity must already exist in its keychain; scripts do not read credentials,
modify keychains, upload anything, or create signing identities. This enables
hardened runtime and an Apple timestamp, then verifies the bundle signature.
Inspect the resulting identity with `codesign -dv --verbose=4 dist/FarForMac.app`.

Notarization remains a separate operator action after licensing and signing
review. Using an already configured notarytool keychain profile, submit the ZIP
with `xcrun notarytool submit <zip> --keychain-profile <profile> --wait`.
Only after an accepted result, staple and validate the app using
`xcrun stapler staple <app>` and `xcrun stapler validate <app>`, then rebuild the
ZIP/checksum from that stapled app (do not rerun packaging, which rebuilds it).
Check Gatekeeper with `spctl --assess --type execute --verbose=4 <app>`.
No notarization or Gatekeeper acceptance is claimed until these checks succeed.

## Validation matrix and upgrade check

CI is configured for `macos-14` and `macos-15-intel`, labels documented in
[GitHub runner images](https://github.com/actions/runner-images). No hosted CI
run has been performed as part of local implementation. It runs core tests,
bundle validation, and a UI startup smoke on its actual
recorded macOS/architecture runners. A green workflow proves only those recorded
environments. Artifacts are separate architecture builds, not a universal app.
macOS 14 minimum support, both processor families, external disks, TCC prompts,
and clean-machine installation need actual successful runs; hosted runner names
alone are not evidence. UI smoke requires a graphical login session.

Before distribution, install the previous version in a disposable user account,
set panel paths/preferences and a sample macro, close it normally, replace its
app bundle, and launch the new version. Confirm settings and macros survive,
missing paths recover, files remain untouched, and the old build can still read
compatible settings. Record versions, OS, architecture, results and limitations
in `docs/ACCEPTANCE.md`. Automated smoke does not establish upgrade compatibility.
