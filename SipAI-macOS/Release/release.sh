#!/usr/bin/env bash
#
# SipAI release pipeline: build, sign, notarize, staple, package, appcast.
#
# Everything a release needs, in the order the dependencies demand:
#
#   archive → export (Developer ID) → notarize → staple
#     ├─ DMG   for people downloading SipAI the first time
#     └─ ZIP   for Sparkle, plus the appcast entry that points at it
#
# Credentials never live in this file. The signing identity comes from the
# login keychain and the notarization credentials from a notarytool
# keychain profile, so this script is safe to publish.
#
# Usage:
#   ./release.sh --preflight     check everything, build nothing
#   ./release.sh                 the full run
#
# Environment:
#   SIPAI_NOTARY_PROFILE   notarytool keychain profile (default SipAI-Notary)
#   SIPAI_IDENTITY         override the signing identity match string
#   SIPAI_RECUT=1          release a version that is NOT CHANGELOG.md's
#                          newest section — a recut of one already out
#
set -euo pipefail

REPO_SLUG="YZCODE01/SipAI"
NOTARY_PROFILE="${SIPAI_NOTARY_PROFILE:-SipAI-Notary}"
IDENTITY_MATCH="${SIPAI_IDENTITY:-Developer ID Application}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$HERE/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
PROJECT="$MACOS_DIR/SipAI.xcodeproj"
OUT="$HERE/build"

PREFLIGHT_ONLY=0
[[ "${1:-}" == "--preflight" ]] && PREFLIGHT_ONLY=1

# ── output helpers ───────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
info() { printf '  ...   %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

# ── 1. preflight ─────────────────────────────────────────────────────────
bold "SipAI release"
step "Preflight"

# The signing identity, and the team id that has to be inside it. A
# self-signed certificate has no team, and UpdaterAvailability disables
# the updater on a build signed by one — so an accidental local-cert
# release would ship an app that can never update itself.
IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(${IDENTITY_MATCH}[^\"]*\)\".*/\1/p" | head -1)"
[[ -n "$IDENTITY" ]] || die "no '$IDENTITY_MATCH' certificate in the keychain.
        Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸
        Developer ID Application. Nothing else can ship: an ad-hoc or
        self-signed build carries no team, and the updater disables
        itself on one."
ok "identity: $IDENTITY"

TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY")"
[[ -n "$TEAM_ID" ]] || die "could not read a team id out of '$IDENTITY'"
ok "team id: $TEAM_ID"

# Notarization credentials. --wait means a bad profile costs a whole
# build before it is discovered, so it is checked up front.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' is missing or invalid. Create it with:
        xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
            --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>"
ok "notarytool profile '$NOTARY_PROFILE' authenticates"

# Sparkle's tools ship inside the resolved package artifact, so they only
# exist once the project has been built at least once. A glob, not a
# `find … | head -1` pipeline: with no DerivedData to match, the
# unexpanded pattern made `find` fail, and under `set -euo pipefail` the
# assignment failed with it — the script exited 1 before its own `die`
# could say what was missing.
SPARKLE_BIN=""
for candidate in ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    if [[ -x "$candidate/generate_appcast" ]]; then SPARKLE_BIN="$candidate"; break; fi
done
[[ -n "$SPARKLE_BIN" ]] || die "Sparkle's tools not found. Build the project once first."
ok "Sparkle tools: $SPARKLE_BIN"

# The EdDSA private key. Losing it strands every installed copy, so this
# is also the reminder to keep a backup somewhere off this machine.
security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1 \
    || die "Sparkle's EdDSA private key is not in the login keychain.
        Without it no update can be signed, and the public half already
        shipped in Info.plist cannot be changed for installed copies."
ok "EdDSA private key present"

# Version. Both numbers matter and for different reasons: Sparkle
# compares CFBundleVersion to decide whether an update exists, and
# CFBundleShortVersionString is what the user sees.
VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)"
BUILD_NUM="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)"
[[ -n "$VERSION" && -n "$BUILD_NUM" ]] || die "could not read version from project.pbxproj"

# Both build configurations must agree, or a Release ships a number the
# Debug build was tested against. The build number too: it is read from
# the first configuration above, but the archive takes Release's.
if [[ "$(grep -c "MARKETING_VERSION = $VERSION;" "$PROJECT/project.pbxproj")" != "2" ]]; then
    die "MARKETING_VERSION differs between Debug and Release"
fi
if [[ "$(grep -c "CURRENT_PROJECT_VERSION = $BUILD_NUM;" "$PROJECT/project.pbxproj")" != "2" ]]; then
    die "CURRENT_PROJECT_VERSION differs between Debug and Release"
fi
ok "version $VERSION (build $BUILD_NUM)"

# The version has to be the one CHANGELOG.md is newest about. A
# MARKETING_VERSION nobody bumped passes every other check here: it
# equals the published version, which reads as a recut (so the build
# number need not rise), and the previous release's dated section is
# still in the changelog — so the run builds the OLD version, names the
# zip after it, and signs an appcast pointing at the release that already
# exists. Measured on copies of the project before this guard: 1.0.3 left
# in place under a finished 1.0.4 section passed as "1.0.3 (build 4)",
# and with only the build number bumped as "1.0.3 (build 5)". A recut of
# a version already out is the one legitimate exception, asked for by
# name.
NEWEST_SECTION="$(awk '/^## \[/ { sub(/^## \[/, ""); sub(/\].*$/, ""); print; exit }' "$REPO_DIR/CHANGELOG.md")"
if [[ "$NEWEST_SECTION" == "$VERSION" ]]; then
    ok "$VERSION is CHANGELOG.md's newest section"
elif [[ "${SIPAI_RECUT:-0}" == "1" ]]; then
    info "recutting $VERSION — CHANGELOG.md's newest section is $NEWEST_SECTION (SIPAI_RECUT=1)"
else
    die "the project says $VERSION but CHANGELOG.md's newest section is $NEWEST_SECTION.
        Raise MARKETING_VERSION and CURRENT_PROJECT_VERSION in both
        configurations — or, to recut $VERSION as already released, run
        with SIPAI_RECUT=1."
fi

# Sparkle offers an update only when CFBundleVersion RISES, so a new
# version on an unbumped build number is an update nobody is ever
# offered — and nothing fails to say so. What is published is what
# docs/appcast.xml says (the feed serves that file). A recut of the SAME
# version may keep its build number, deliberately; only a new version
# must rise.
# No pipeline here: under `set -euo pipefail` a `sed … | head -1` whose
# reader closes early fails the assignment and the script with it, and a
# missing appcast (a first release from a fresh clone) must read as
# "nothing published", not as an error. awk stops at the first match.
APPCAST="$REPO_DIR/docs/appcast.xml"
PUBLISHED_VERSION=""
PUBLISHED_BUILD=""
if [[ -f "$APPCAST" ]]; then
    PUBLISHED_VERSION="$(awk -F'[<>]' '/<sparkle:shortVersionString>/ { print $3; exit }' "$APPCAST")"
    PUBLISHED_BUILD="$(awk -F'[<>]' '/<sparkle:version>/ { print $3; exit }' "$APPCAST")"
fi
if [[ -n "$PUBLISHED_BUILD" && "$VERSION" != "$PUBLISHED_VERSION" ]]; then
    [[ "$BUILD_NUM" =~ ^[0-9]+$ && "$PUBLISHED_BUILD" =~ ^[0-9]+$ && "$BUILD_NUM" -gt "$PUBLISHED_BUILD" ]] \
        || die "build $BUILD_NUM is not above the published build $PUBLISHED_BUILD ($PUBLISHED_VERSION, docs/appcast.xml).
        Raise CURRENT_PROJECT_VERSION in both configurations — Sparkle
        compares build numbers, and an unbumped one is never offered."
    ok "build $BUILD_NUM is above the published $PUBLISHED_VERSION (build $PUBLISHED_BUILD)"
fi

# Release notes have to exist before the build, because the appcast
# entry is generated from them and a missing section produces a silently
# empty update dialog.
grep -q "^## \[$VERSION\]" "$REPO_DIR/CHANGELOG.md" \
    || die "CHANGELOG.md has no '## [$VERSION]' section"
# A positive check, on purpose: the section must carry a date. A search
# for the word "unreleased" misses the file's own spelling
# ("Unreleased") and lets an undated heading go out as the update's
# release notes.
grep -qE "^## \[$VERSION\] — [0-9]{4}-[0-9]{2}-[0-9]{2}" "$REPO_DIR/CHANGELOG.md" \
    || die "CHANGELOG.md's $VERSION section is not dated — it reads
        '$(grep -m1 "^## \[$VERSION\]" "$REPO_DIR/CHANGELOG.md")'
        Write it as '## [$VERSION] — YYYY-MM-DD' first."
ok "CHANGELOG.md has a dated section for $VERSION"

# Release keeps the hardened runtime: notarization requires it.
grep -q "ENABLE_HARDENED_RUNTIME = YES" "$PROJECT/project.pbxproj" \
    || die "Release must keep ENABLE_HARDENED_RUNTIME = YES for notarization"
ok "hardened runtime enabled in Release"

if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    info "working tree is dirty — releasing anyway, but the tag will not match"
fi

# Files the app is built from that git does not know yet. Xcode reads
# the working tree, so the build cannot notice — but a tag on a tree
# missing them does not build from a clone. Listed so the release commit
# can include them; the summary at the end lists them again.
untracked_release_files() {
    git -C "$REPO_DIR" ls-files --others --exclude-standard \
        -- SipAI-macOS/SipAI SipAI-macOS/SipAI.xcodeproj docs
}
UNTRACKED="$(untracked_release_files)"
if [[ -n "$UNTRACKED" ]]; then
    info "untracked files the release commit must include:"
    sed 's/^/          /' <<<"$UNTRACKED"
fi

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
    printf '\n  \033[32mPreflight passed.\033[0m Run without --preflight to build %s.\n\n' "$VERSION"
    exit 0
fi

# ── 2. build and export ──────────────────────────────────────────────────
rm -rf "$OUT"; mkdir -p "$OUT"
ARCHIVE="$OUT/SipAI.xcarchive"
APP="$OUT/export/SipAI.app"

step "Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme SipAI -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive > "$OUT/archive.log" 2>&1 \
    || { tail -30 "$OUT/archive.log"; die "archive failed (full log: $OUT/archive.log)"; }
ok "archived"

# exportArchive is what signs the nested code — Sparkle's XPC services,
# Autoupdate and Updater.app — inside-out and with a secure timestamp.
# Hand-rolling that with codesign is how a nested signature gets missed.
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" > "$OUT/export.log" 2>&1 \
    || { tail -30 "$OUT/export.log"; die "export failed (full log: $OUT/export.log)"; }
[[ -d "$APP" ]] || die "export produced no SipAI.app"
ok "exported $APP"

step "Verifying the signature before notarizing"
# The export lands inside the repo tree, and the repo lives where a
# cloud file provider may be syncing: such a provider re-stamps
# com.apple.FinderInfo onto files there within about a minute, and a
# strict verify refuses an app carrying it ("detritus not allowed") —
# on a signature that is otherwise perfectly valid. The stamp is not
# part of the signature, so stripping it here changes nothing that was
# signed; everything that SHIPS is packaged from a stripped copy in
# /tmp further down, for the same reason.
xattr -cr "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/        /'
ok "signature valid"

# codesign --verify checks the signature, not whether the pieces may load
# together. These three are what notarization actually rejects on.
#
# The description is captured ONCE into a variable rather than grepped
# through a pipe. `codesign -dvv | grep -q` looks equivalent and is not:
# grep -q exits at the first match, SIGPIPEs codesign into exit 141, and
# under `set -o pipefail` the pipeline then reports failure BECAUSE the
# match succeeded. A correctly signed app fails the check.
SIGINFO="$(codesign -dvv "$APP" 2>&1)"

grep -q "TeamIdentifier=$TEAM_ID" <<<"$SIGINFO" \
    || die "the app carries no team identifier — wrong certificate?
$SIGINFO"
ok "TeamIdentifier=$TEAM_ID"

grep -q "flags=.*runtime" <<<"$SIGINFO" \
    || die "hardened runtime flag missing from the signature"
ok "hardened runtime flag set"

grep -qi "Timestamp=" <<<"$SIGINFO" \
    || die "no secure timestamp — notarization will reject this"
ok "secure timestamp present"

# Entitlements. Signing.xcconfig includes Local.xcconfig last, and it is
# Release's base configuration too, so one line there could carry an
# entitlements file into a distribution build. Notarization refuses
# get-task-allow but not disable-library-validation — and library
# validation is what stops a swapped framework loading into an app that
# updates itself. Captured once, like the signature above.
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
if grep -qE 'get-task-allow|disable-library-validation|allow-dyld-environment-variables|allow-unsigned-executable-memory' <<<"$ENTITLEMENTS"; then
    die "the exported app carries a debugging or code-loading entitlement:
$ENTITLEMENTS"
fi
ok "no debugging or code-loading entitlement"

# Sparkle is useless without its helpers: the framework alone cannot
# install anything, and the failure only shows on the first real update.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
[[ -x "$SPK/Autoupdate" && -d "$SPK/Updater.app" ]] \
    || die "Sparkle.framework is missing Autoupdate / Updater.app"
ok "Sparkle.framework embedded with its helpers"

# The launch is the real test. A signature can verify on an app that
# cannot load: the hardened runtime implies library validation, and LV
# refuses an embedded framework whose team id differs from the app's.
# Signing with a real Developer ID is what makes those match — this is
# the step that proves it did.
#
# Four seconds on the REAL data folder: Foundation ignores $HOME for
# Application Support, so nothing here can point the copy elsewhere.
# What makes that safe is the scheduler — its first due check waits
# `ScheduledTaskScheduler.firstTickDelay` (15 s) after launch, so a task
# whose slot fell due while SipAI was quit for this release cannot fire,
# be recorded as run, and be killed with the copy inside this window;
# Verification/SparkleUpdate holds the two numbers apart. Run this with
# SipAI quit all the same: two copies write one config.json.
step "Launch check"
"$APP/Contents/MacOS/SipAI" > "$OUT/launch.log" 2>&1 &
LPID=$!
/usr/bin/perl -e 'select(undef,undef,undef,4)'
if kill -0 $LPID 2>/dev/null; then
    ok "app loads (Sparkle.framework maps cleanly)"
    # `wait` absorbs the shell's own "Killed: 9" job notice, which
    # otherwise prints on a passing run and reads like a failure.
    kill -9 $LPID 2>/dev/null
    wait $LPID 2>/dev/null || true
else
    die "the app did not stay up:
$(head -5 "$OUT/launch.log")"
fi

# ── 3. notarize the app ──────────────────────────────────────────────────
step "Notarizing the app"
NOTARY_ZIP="$OUT/SipAI-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
info "submitting (this waits for Apple; usually a few minutes)"
xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$OUT/notarize-app.log"
grep -q "status: Accepted" "$OUT/notarize-app.log" || {
    SUB="$(sed -n 's/.*id: \([0-9a-f-]\{36\}\).*/\1/p' "$OUT/notarize-app.log" | head -1)"
    [[ -n "$SUB" ]] && xcrun notarytool log "$SUB" --keychain-profile "$NOTARY_PROFILE"
    die "notarization was not accepted"
}
ok "accepted"

xcrun stapler staple "$APP" || die "stapling failed"
ok "stapled"

# spctl is the question a user's Mac asks on first open. Before stapling
# it needs the network; after, it does not — which is the whole point.
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/        /'
ok "Gatekeeper accepts the app"

# Everything that SHIPS is packaged from a copy in /tmp, never from the
# repo tree. The repo lives under ~/Desktop, and iCloud's file provider
# keeps re-stamping com.apple.FinderInfo / com.apple.fileprovider xattrs
# onto files there — measured: a stripped app was re-stamped within a
# minute, mid-release. ditto --sequesterRsrc then carries the stamps into
# the zip and DMG, and `codesign --verify --strict` on what users
# download fails with "resource fork, Finder information, or similar
# detritus not allowed". Stripping in place is a losing race; /tmp is
# outside the sync scope, so a stripped copy there stays clean.
PKG="$(mktemp -d /tmp/sipai-pkg.XXXXXX)"
SHIP="$PKG/SipAI.app"
ditto "$APP" "$SHIP"
xattr -cr "$SHIP"
[[ "$(xattr -lr "$SHIP" 2>/dev/null | grep -cE 'FinderInfo|fileprovider')" -eq 0 ]] \
    || die "xattr strip failed — packaging copy is not clean"
codesign --verify --deep --strict "$SHIP" || die "stripped copy fails strict verification"
ok "clean packaging copy in $PKG"

# ── 4. the DMG people download ───────────────────────────────────────────
step "Building the DMG"
DMG="$OUT/SipAI-$VERSION.dmg"
STAGE="$PKG/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$SHIP" "$STAGE/SipAI.app"
ln -s /Applications "$STAGE/Applications"
# The drag-to-install window: dmg/DS_Store carries the icon positions,
# window size and background reference; dmg/background.tiff is the arrow.
# The volume name must stay exactly "SipAI" — the background alias inside
# DS_Store names the volume, so a versioned volume name silently loses the
# background and the window reverts to a plain Finder browser.
cp "$HERE/dmg/DS_Store" "$STAGE/.DS_Store"
cp "$HERE/dmg/background.tiff" "$STAGE/.background.tiff"
hdiutil create -volname "SipAI" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"
ok "$(basename "$DMG") ($(du -h "$DMG" | cut -f1))"

# A DMG is signed and notarized in its own right. Without it the download
# is quarantined and the first open shows a Gatekeeper warning even
# though the app inside is notarized.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
ok "DMG signed"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$OUT/notarize-dmg.log"
grep -q "status: Accepted" "$OUT/notarize-dmg.log" || die "DMG notarization was not accepted"
xcrun stapler staple "$DMG" || die "stapling the DMG failed"
ok "DMG notarized and stapled"

# ── 5. the Sparkle update archive and appcast ────────────────────────────
step "Building the Sparkle update archive"
FEED_DIR="$OUT/feed"
mkdir -p "$FEED_DIR"
# --keepParent so the archive holds SipAI.app rather than its contents.
# Sourced from the CLEAN /tmp copy — see the packaging-copy comment above;
# zipping "$APP" out of the synced tree ships iCloud's xattr stamps.
ditto -c -k --sequesterRsrc --keepParent "$SHIP" "$FEED_DIR/SipAI-$VERSION.zip"
ok "SipAI-$VERSION.zip ($(du -h "$FEED_DIR/SipAI-$VERSION.zip" | cut -f1))"

# Release notes: generate_appcast picks up <archive-basename>.html sitting
# beside the archive and embeds it as the update's description.
python3 "$HERE/changelog_to_html.py" "$REPO_DIR/CHANGELOG.md" "$VERSION" \
    > "$FEED_DIR/SipAI-$VERSION.html" || die "could not render release notes"
ok "release notes rendered ($(wc -c < "$FEED_DIR/SipAI-$VERSION.html") bytes)"

# The same section as Markdown, for the GitHub release's body — one
# source for the update dialog, the release page and the changelog.
# Written OUTSIDE the feed folder: generate_appcast takes a .html, .md
# or .txt named like an archive as that archive's release notes, and
# with two beside the zip which one it picks is not ours to say.
RELEASE_BODY="$OUT/SipAI-$VERSION.md"
awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print }' "$REPO_DIR/CHANGELOG.md" > "$RELEASE_BODY"
[[ -s "$RELEASE_BODY" ]] || die "could not extract the $VERSION section for the release body"
ok "release body extracted (SipAI-$VERSION.md)"

step "Generating the appcast"
# The enclosure URL has to point at where the zip will actually live.
# generate_appcast signs each archive with the EdDSA key from the keychain.
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO_SLUG" \
    --full-release-notes-url "https://github.com/$REPO_SLUG/blob/main/CHANGELOG.md" \
    "$FEED_DIR" || die "generate_appcast failed"
[[ -f "$FEED_DIR/appcast.xml" ]] || die "no appcast.xml produced"
ok "appcast.xml generated and signed"

grep -q "edSignature" "$FEED_DIR/appcast.xml" || die "appcast carries no EdDSA signature"
ok "EdDSA signature present in the appcast"

cp "$FEED_DIR/appcast.xml" "$REPO_DIR/docs/appcast.xml"
ok "copied to docs/appcast.xml"

# The release notes go with it. generate_appcast writes a
# <sparkle:releaseNotesLink> resolved against the FEED's own host, so the
# .html has to be served from the same place as the appcast — leave it
# behind in build/ and every update dialog renders an empty description,
# with nothing failing loudly to say why.
cp "$FEED_DIR/SipAI-$VERSION.html" "$REPO_DIR/docs/SipAI-$VERSION.html"
ok "copied to docs/SipAI-$VERSION.html"

NOTES_URL="$(sed -n 's/.*<sparkle:releaseNotesLink>\(.*\)<\/sparkle:releaseNotesLink>.*/\1/p' "$FEED_DIR/appcast.xml")"
[[ "$(basename "$NOTES_URL")" == "SipAI-$VERSION.html" ]] \
    || die "the appcast points its release notes at '$NOTES_URL', which is
        not the file just copied into docs/. Serving the appcast without
        the notes it names renders an empty update dialog."
ok "release-notes link matches the file in docs/"

# ── 6. what to do with it ────────────────────────────────────────────────
step "Done"
# The order below is load-bearing. Pushing main publishes docs/ through
# GitHub Pages, i.e. the feed goes live — and a feed that names a zip
# nobody has uploaded yet hands every copy that checks in the meantime a
# download error. So the tag goes up alone (a tag push moves no branch),
# the release hangs off it with both assets, and main is pushed LAST.
# `gh release create` on a tag GitHub does not have yet would make one —
# pointing at the OLD main, since that is what the remote holds.
cat <<SUMMARY

  Artefacts in $OUT:

    $(basename "$DMG")                 → the release asset people click
    feed/SipAI-$VERSION.zip            → the release asset the appcast names
    SipAI-$VERSION.md                  → the same notes as Markdown, for the release body
    feed/appcast.xml                → already copied to docs/appcast.xml,
                                      with docs/SipAI-$VERSION.html beside it

  Remaining, in order — the feed goes live LAST:

    1.  Commit the release: the source, docs/appcast.xml AND
        docs/SipAI-$VERSION.html (the appcast names that page as its
        release notes; left out, the update dialog shows a 404 page).
        Then tag the commit:
          git -C "$REPO_DIR" add docs/appcast.xml docs/SipAI-$VERSION.html <the source>
          git -C "$REPO_DIR" commit
          git -C "$REPO_DIR" tag v$VERSION

    2.  Push the TAG alone — main stays put, so the feed does not move,
        and the tag exists on GitHub for the release to hang off:
          git -C "$REPO_DIR" push origin v$VERSION

    3.  Create the release from that tag with BOTH files. The zip must
        keep its name: the appcast's URL already names it.
          gh release create v$VERSION "$DMG" "$FEED_DIR/SipAI-$VERSION.zip" \\
              --title "SipAI $VERSION" --notes-file "$RELEASE_BODY"

    4.  Now push main. GitHub Pages publishes docs/, and the feed is live:
          git -C "$REPO_DIR" push origin main

    5.  Confirm from what a user's copy will fetch — the live feed, and
        the zip it names checked against the signature it carries:
          curl -sS https://updates.sipai.dev/appcast.xml | head -20
          curl -sSL -o /tmp/SipAI-$VERSION.zip \\
              https://github.com/$REPO_SLUG/releases/download/v$VERSION/SipAI-$VERSION.zip
          "$SPARKLE_BIN/sign_update" --verify /tmp/SipAI-$VERSION.zip "<sparkle:edSignature from the feed>"

SUMMARY

UNTRACKED_NOW="$(untracked_release_files)"
if [[ -n "$UNTRACKED_NOW" ]]; then
    printf '  Untracked files the release commit in step 1 must include:\n'
    sed 's/^/    /' <<<"$UNTRACKED_NOW"
    echo
fi
