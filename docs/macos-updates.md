# macOS signing and updates

The macOS app uses Sparkle 2.10.0. Automatic checks run daily by default; users can change this and enable automatic downloading/installing from **Summary Chip → Software Update Settings…**. **Check for Updates…** starts a manual check. Update offers, failures, downloads, and installation status use a dedicated native sheet, with progress in an overlay. iOS does not link Sparkle.

The production feed is `https://update.summary.rxlab.app/appcast.xml`. GitHub Pages hosts the feed and release notes; GitHub Release assets host `SummaryChip.dmg`. `summary-chip-macOS/Info.plist` embeds the feed URL and the same public EdDSA key as RxCode, matching the organization's shared `SPARKLE_KEY` secret. The release script cryptographically verifies each archive against that embedded public key before publishing. A mismatched organization key fails the release.

The sandboxed app enables `SUEnableInstallerLauncherService` and the `-spks`/`-spki` Mach lookup exceptions. It already has outgoing network access, so it does not enable Sparkle's downloader service. These settings are macOS-only.

## Release workflow

`.github/workflows/macos-release.yaml` extends the existing macOS signing pipeline. Pushes build and notarize a DMG for testing. Published stable releases also generate a signed appcast, attach the DMG to the release, and deploy the update site. Prereleases are excluded. Releases are serialized so a later update cannot be overwritten by an earlier concurrent deployment.

The pipeline runs on a self-hosted **macOS** runner with Xcode 27 and macOS 26 or later. It installs `create-dmg`, `xcpretty`, and Python's `cryptography`. Sparkle's CLI tools come from the same resolved package artifact as the app framework, rather than a separately downloaded version.

Signing proceeds inside out through Sparkle's helpers, framework, and containing app. App entitlements from the archive are preserved. Notarization and stapling finish before Sparkle signs the final DMG. The feed validator checks the signature, download URL, archive size, build number, marketing version, release notes URL, and macOS 26 minimum requirement. `github.run_number` provides increasing build numbers; do not reset this workflow's counter when replacing it.

## Credentials

Repository or inherited organization secrets:

| Secret | Purpose |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate and private key as base64 P12 |
| `P12_PASSWORD` | P12 password |
| `SIGNING_CERTIFICATE_NAME` | Developer ID Application signing identity |
| `APPLE_ID`, `APPLE_ID_PWD`, `APPLE_TEAM_ID` | Notarization credentials and matching team |
| `SPARKLE_KEY` | Private EdDSA key matching the embedded public key |
| `MACOS_PROVISIONING_PROFILE_BASE64` | Developer ID profile for `com.rxlab.summary-chip` |
| `MACOS_SHARE_EXTENSION_PROVISIONING_PROFILE_BASE64` | Developer ID profile for `com.rxlab.summary-chip.MacSmartShare` |

Summary Chip's profiles must include its app/keychain groups and the app's associated domains, and belong to the Developer ID signing certificate's team. RxCode's app-specific profile cannot be reused. Profiles are pinned per target on the CI working copy; they are not passed globally to Swift package targets. Local and iOS signing settings remain automatic.

Use `gh secret set NAME --body-file /path/to/base64-file` to install a secret without printing its contents. Keep P12s, raw profiles, keys, and credential files outside version control. The existing `create-release.yaml` uses `RELEASE_TOKEN` so the resulting release event can start the macOS workflow.

## GitHub Pages and Cloudflare

Enable **Settings → Pages → Source → GitHub Actions** and set custom domain `update.summary.rxlab.app`. An Actions deployment's `CNAME` file alone does not configure the repository's domain; the Pages setting must also be set.

In Cloudflare's `rxlab.app` zone, create a DNS-only CNAME:

| Name | Target | Proxy | TTL |
| --- | --- | --- | --- |
| `update.summary` | `rxtech-lab.github.io` | DNS only | Auto |

`scripts/setup-update-hosting.py` can configure both services using authenticated `gh` and `CLOUDFLARE_API_TOKEN`. The token needs Zone Read and DNS Edit on `rxlab.app`. By default the script reads `server/.env` without printing credentials. Inspect first, then apply:

```sh
python3 scripts/setup-update-hosting.py --env-file /path/to/credentials.env
python3 scripts/setup-update-hosting.py --env-file /path/to/credentials.env --apply
```

The script claims the hostname on GitHub before creating DNS, refuses conflicting domains or DNS records, and enables HTTPS enforcement once GitHub has issued the certificate. Rerun after certificate issuance if it is initially pending. The first published signed release provides the feed; a successful end-to-end installation test requires an older and newer signed release.

## Verification

Run `actionlint .github/workflows/macos-release.yaml`, `shellcheck scripts/ci/*.sh`, and `python3 scripts/ci/test_validate_appcast.py` (with `cryptography` installed). The signature tests reject modified archives, mismatched keys, and incorrect download URLs.

The `SoftwareUpdateUITests` suite exercises the actual menu command, native sheet dismissal/reopening, and Sparkle network failure/retry callbacks using an unreachable loopback feed. The Debug-only `--test-update-feed=http://127.0.0.1:PORT/appcast.xml` argument can exercise local fixtures without changing the production feed or persisted settings. Ordinary preview/UI-test launches skip scheduled updater startup.

To also test an update offer, the actual download overlay, and rejection of an unsigned archive, start `python3 scripts/tests/update-fixture-server.py` before running `SoftwareUpdateUITests`. The fixture listens only on `127.0.0.1:18765` and serves deliberately invalid bytes; it cannot install an update. This integration test skips when the fixture is absent. Stop the fixture with Control-C when testing finishes.
