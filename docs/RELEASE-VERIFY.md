# Verify a Developer ID release ZIP

The public 0.1.0 download is a read-only DMG. The ZIP described below is
the intermediate used to check the signed app before packaging it.

The check is for a final ZIP containing one ordinary arm64
`AgentDashboard.app`. It is separate from the ad-hoc
`Tools/check-entitlements.sh` preflight and from first launch on a clean
account. It does not sign, upload, staple, install or launch software.

## Prepare the signed artifact

Review the source commit before building. Save the full commit SHA and
the build receipt, and build the normal Release configuration from that
clean checkout. In the **scratch distribution copy**, before Developer ID
signing, add the approved commit to the bundle plist:

```sh
/usr/libexec/PlistBuddy -c "Add :AgentDashboardSourceRevision string $approved_revision" \
  "$staged_app/Contents/Info.plist"
```

Sign with the authorized Developer ID **Application** identity and hardened
runtime. Submit and staple only as a separately authorized release action.
Preserve the staple when packaging the final ZIP; record the digest
of that exact ZIP in the reviewed receipt alongside commit, version, build
and Team ID. The verifier checks that the signed revision matches the
receipt; it does not reconstruct a build or prove how the revision was set.

## Verify the exact ZIP

Use the expected digest and fields from the reviewed receipt, not values
copied from an untrusted download. The explicit `--assess` opts into macOS
trust checks that may contact Apple. The App is never executed.

```sh
Tools/check-release-package "$release_zip" \
  --sha256 "$reviewed_zip_digest" \
  --team-id "$approved_team" \
  --revision "$approved_revision" \
  --version "$approved_version" --build "$approved_build" \
  --assess
```

In order, the checker:

1. Verifies and stages the exact archive, rejecting unsafe, duplicate,
   or oversized ZIP members before extraction.
2. Verifies the extracted code signatures, then the Apple Developer ID
   Application certificate, bundle identifier and approved Team ID.
3. Requires the frozen entitlements, Hardened Runtime, expected signed
   version/build/revision, and an arm64-only executable.
4. Requires a successful `xcrun stapler validate` and the host's
   `syspolicy_check distribution`.

Only when every step passes does it print a verification record and return
success. An ad-hoc ZIP with a valid hash and entitlements still fails the
Developer ID step. No checks are skipped based on the host policy.
The host assessment does not replace clean-account installation, first
authorization, indexing, or relaunch acceptance of the exact package.
Do not distribute a ZIP until those and the other SPEC release gates
have been reviewed.

Apple references: [Code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Diagnosing Gatekeeper issues](https://developer.apple.com/forums/thread/706442).

## Verify the published disk image

Download the DMG and `SHA256SUMS` from the same GitHub Release. In the download
directory, run:

```sh
shasum -a 256 -c SHA256SUMS
hdiutil verify AgentDashboard-0.1.0-macOS-arm64.dmg
codesign --verify --strict AgentDashboard-0.1.0-macOS-arm64.dmg
xcrun stapler validate AgentDashboard-0.1.0-macOS-arm64.dmg
```

The mounted volume contains the app and an Applications shortcut. The signed
`AgentDashboardSourceRevision` in the app's `Contents/Info.plist` must equal
the commit targeted by the release tag. Check the mounted app's signature,
ticket and distribution assessment as well as the outer image's ticket.
