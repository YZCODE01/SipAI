#!/bin/bash
# Verification/SparkleUpdate/end-to-end.sh
#
# Drives a REAL update: builds the project's current version and the
# next patch release of it, signs the newer one with the actual EdDSA
# key from the keychain, serves a real appcast over a local HTTP server,
# launches the older one, and waits for the bundle on disk to become the
# newer one. Both version numbers are read out of project.pbxproj, so
# this keeps testing an upgrade no matter what the app is versioned at.
#
# This is the only check that exercises the parts nothing else can:
# that `sign_update` and the `SUPublicEDKey` in Info.plist agree at
# INSTALL time (run.sh compares the keys, this proves an archive signed
# with one is accepted by the other), that Sparkle can parse an appcast
# we generated, that the download and the atomic bundle swap work, and
# that the app relaunches afterwards instead of dying.
#
# It needs ONE click from you — "Install and Relaunch" in Sparkle's
# window. That click is part of what is being tested: the standard user
# driver is what ships, so a test that bypassed it would not be testing
# the shipping path.
#
# SIPAI_E2E_HOLD=<seconds> drives the HOLD as well: the staged app is
# told (SIPAI_UPDATER_SIMULATE_TURN, honoured only under the harness
# override) that an agent turn is running for that long after the
# click, so Sparkle's "Install and Relaunch" has to be answered with a
# sheet — click "Wait for the Turn" — and the install must land no
# earlier than the pretend turn's end. Two clicks; the app's stderr
# lines time it, since the click and the sheet are invisible from here.
#
# Nothing here touches the real feed, the real releases, or the repo.
# Everything lives in a temp directory that is removed on exit. But the
# install step LAUNCHES a real SipAI, and it runs on your real data
# folder, ~/Library/Application Support/SipAI (Foundation ignores $HOME
# for it — measured): it reads and may write config, its scheduler ticks
# at once and can fire a task that is due, and its first agent turn
# would take over the approver socket of any SipAI you have open. Quit
# SipAI and run this from Terminal. SIPAI_E2E_DRY_RUN=1 launches nothing.
#
# SIPAI_SPARKLE_DERIVED_DATA=<dir> builds in a DerivedData of its own,
# with packages from SIPAI_SPARKLE_PACKAGES (default <dir>-src) and no
# package resolution — needed when this runs from inside the Xcode build,
# whose DerivedData (and Xcode's own resolution) must not be raced.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # SipAI-macOS
PROJECT="$ROOT/SipAI.xcodeproj"

DD="${SIPAI_SPARKLE_DERIVED_DATA:-}"
PKGS="${SIPAI_SPARKLE_PACKAGES:-${DD:+$DD-src}}"
XCB_LOCATION=()
[ -n "$DD" ] && XCB_LOCATION=(-derivedDataPath "$DD" -clonedSourcePackagesDirPath "$PKGS" -disableAutomaticPackageResolution)
# Each xcodebuild spells it ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"}:
# /bin/bash 3.2 calls an EMPTY array unbound under `set -u`.
STAGE="$(mktemp -d)"
FEED="$STAGE/feed"
APPS="$STAGE/Applications"
PORT=8765
SERVER_PID=""
APP_PID=""

OLD_VERSION=""   # derived from the project below, never hardcoded
NEW_VERSION=""
OLD_BUILD=""
NEW_BUILD=""

cleanup() {
    [ -n "$APP_PID" ]    && kill -9 "$APP_PID" 2>/dev/null
    [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
    pkill -f "$APPS/SipAI.app/Contents/MacOS/SipAI" 2>/dev/null
    rm -rf "$STAGE"
}
trap cleanup EXIT

say()  { echo "$@"; }
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; echo "        → $2"; exit 1; }

mkdir -p "$FEED" "$APPS"

if [ -n "$DD" ]; then
    TOOLS="$(find "$PKGS/artifacts/sparkle/Sparkle/bin" -name sign_update 2>/dev/null | head -1)"
else
    TOOLS="$(find ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
              -name sign_update 2>/dev/null | head -1)"
fi
TOOLS="$(dirname "$TOOLS" 2>/dev/null)"
[ -x "$TOOLS/sign_update" ] || bad "Sparkle tools present" \
    "run: xcodebuild -project SipAI.xcodeproj -scheme SipAI -resolvePackageDependencies"

# The version under test is DERIVED from the project, never restated
# here. A harness that hardcodes "1.0.0" keeps passing after you ship
# 1.1.0 — while quietly testing a downgrade nobody would ever be
# offered. Reading it also makes the two configurations' agreement a
# checked fact rather than an assumption.
read_setting() {
    grep "$1" "$PROJECT/project.pbxproj" | sed 's/.*= *//; s/;//' | tr -d ' ' | sort -u
}

OLD_VERSION="$(read_setting MARKETING_VERSION)"
OLD_BUILD="$(read_setting CURRENT_PROJECT_VERSION)"

[ "$(printf '%s\n' "$OLD_VERSION" | wc -l | tr -d ' ')" = "1" ] \
    || bad "Debug and Release agree on MARKETING_VERSION" \
           "project.pbxproj has more than one value: $(printf '%s' "$OLD_VERSION" | tr '\n' ' ')"
[ "$(printf '%s\n' "$OLD_BUILD" | wc -l | tr -d ' ')" = "1" ] \
    || bad "Debug and Release agree on CURRENT_PROJECT_VERSION" \
           "project.pbxproj has more than one value: $(printf '%s' "$OLD_BUILD" | tr '\n' ' ')"

# The update under test is the next patch release of whatever the
# project currently is.
# OFS must be set BEFORE $NF is assigned: assigning to a field rebuilds
# $0 using the output separator in effect at that moment, so setting it
# afterwards yields "1 0 1" — which xcodebuild accepts verbatim as a
# version string, and which every assertion below then matches against
# consistently. A passing test proving nothing.
NEW_VERSION="$(printf '%s' "$OLD_VERSION" | awk -F. 'BEGIN { OFS="." } { $NF = $NF + 1; print }')"
NEW_BUILD=$(( OLD_BUILD + 1 ))

case "$NEW_VERSION" in
    *.*.*) : ;;
    *) bad "computed next version looks like a version" \
           "bumping '$OLD_VERSION' produced '$NEW_VERSION'" ;;
esac

say "== Sparkle end-to-end update =="
say "   staging in $STAGE"
say "   $OLD_VERSION (build $OLD_BUILD)  →  $NEW_VERSION (build $NEW_BUILD)"
say "   both read from project.pbxproj"
say

# ------------------------------------------------------------------ 1
say "1. Building $OLD_VERSION (the copy that will update itself)"
xcodebuild -project "$PROJECT" -scheme SipAI -configuration Debug \
    ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"} \
    MARKETING_VERSION="$OLD_VERSION" CURRENT_PROJECT_VERSION="$OLD_BUILD" \
    CONFIGURATION_BUILD_DIR="$STAGE/build-old" \
    build > "$STAGE/build-old.log" 2>&1 \
    || bad "build $OLD_VERSION" "see $STAGE/build-old.log"
cp -R "$STAGE/build-old/SipAI.app" "$APPS/SipAI.app"
ok "$OLD_VERSION built and staged in a writable folder"

# Sparkle fetches the appcast and the archive with URLSession, and App
# Transport Security blocks plain HTTP — including to 127.0.0.1. The
# exception is added to the STAGED COPY only, never to the source
# Info.plist: the shipping app talks to an https:// feed and has no
# business permitting cleartext anything.
/usr/libexec/PlistBuddy \
    -c "Add :NSAppTransportSecurity dict" \
    -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
    "$APPS/SipAI.app/Contents/Info.plist" > /dev/null 2>&1
# Re-signed with a STABLE identity, and that is not a detail. Sparkle
# refuses an update whose designated requirement does not match the
# running copy's, and an ad-hoc signature's requirement is a per-build
# cdhash — so two ad-hoc builds of the same app never match and this
# test would fail for a reason that has nothing to do with updating.
# Any certificate with a fixed leaf works: a self-signed one from
# Keychain Access, or your own Apple Development cert.
E2E_IDENTITY="${SIPAI_E2E_IDENTITY:-SipAI Local Dev}"
codesign --force --deep --sign "$E2E_IDENTITY" "$APPS/SipAI.app" > /dev/null 2>&1 \
    || bad "re-sign staged app" \
        "no '$E2E_IDENTITY' identity in the keychain. This test needs a
        stable signing identity — ad hoc will not do, see the comment
        above. Point it at one you have:
            SIPAI_E2E_IDENTITY='Apple Development: You (ABCDE12345)' $0"
ok "staged copy patched for local HTTP and re-signed as '$E2E_IDENTITY'"
say

# ------------------------------------------------------------------ 2
say "2. Building $NEW_VERSION (the update)"
xcodebuild -project "$PROJECT" -scheme SipAI -configuration Debug \
    ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"} \
    MARKETING_VERSION="$NEW_VERSION" CURRENT_PROJECT_VERSION="$NEW_BUILD" \
    CONFIGURATION_BUILD_DIR="$STAGE/build-new" \
    build > "$STAGE/build-new.log" 2>&1 \
    || bad "build $NEW_VERSION" "see $STAGE/build-new.log"

# ditto, not zip: it is what Sparkle's own docs specify and what
# preserves the bundle's symlinks and extended attributes. A plain
# `zip -r` produces an archive that unpacks into a broken framework.
ditto -c -k --sequesterRsrc --keepParent \
    "$STAGE/build-new/SipAI.app" "$FEED/SipAI-$NEW_VERSION.zip" \
    || bad "archive $NEW_VERSION" "ditto failed"
ok "$NEW_VERSION archived ($(du -h "$FEED/SipAI-$NEW_VERSION.zip" | cut -f1))"

# Release notes, same basename as the archive — generate_appcast picks
# these up automatically. This is the shape Phase 2's release script
# will use for each CHANGELOG section, so the path is worth proving now.
cat > "$FEED/SipAI-$NEW_VERSION.html" <<'HTML'
<h2>Test build</h2>
<p>If you can read this in the update window, release notes flow from a
file beside the archive into the appcast and out to the user.</p>
HTML
ok "release notes staged beside the archive"
say

# ------------------------------------------------------------------ 3
say "3. Signing and generating the appcast (real key, from the keychain)"
"$TOOLS/generate_appcast" --download-url-prefix "http://127.0.0.1:$PORT/" \
    "$FEED" > "$STAGE/appcast.log" 2>&1 \
    || bad "generate_appcast" "see $STAGE/appcast.log"

[ -f "$FEED/appcast.xml" ] || bad "appcast.xml written" "generate_appcast produced no feed"

grep -q "sparkle:edSignature" "$FEED/appcast.xml" \
    || bad "appcast carries an EdDSA signature" \
           "without it Sparkle refuses every update; is the private key in the keychain?"
ok "appcast signed"

# Assert on the VERSION SPARKLE WILL READ, not on the filename.
# generate_appcast takes the version out of the app bundle inside the
# archive and ignores what the file is called — so a grep for "1.0.1"
# matches the enclosure URL (SipAI-1.0.1.zip) even when the bundle
# inside is 1.0.0, and the test passes while proving nothing. Measured:
# archiving a 1.0.0 build as SipAI-1.0.1.zip yields an appcast whose
# shortVersionString reads 1.0.0 and whose URL reads 1.0.1.
grep -q "<sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>" \
     "$FEED/appcast.xml" \
    || bad "appcast offers $NEW_VERSION" \
           "the archived bundle is not $NEW_VERSION — appcast says $(sed -n 's|.*<sparkle:shortVersionString>\(.*\)</sparkle:shortVersionString>.*|\1|p' "$FEED/appcast.xml" | head -1)"
ok "appcast offers $NEW_VERSION (read from the bundle, not the filename)"

grep -q "<sparkle:minimumSystemVersion>" "$FEED/appcast.xml" \
    && ok "minimumSystemVersion carried through ($(sed -n 's|.*<sparkle:minimumSystemVersion>\(.*\)</sparkle:minimumSystemVersion>.*|\1|p' "$FEED/appcast.xml" | head -1))"

grep -q "<description>" "$FEED/appcast.xml" \
    && ok "release notes embedded from the .html beside the archive"

# The signature must actually verify, not merely be present.
# sign_update takes the signature POSITIONALLY on verify
# (`sign_update --verify <file> <signature>`); -s is the private key and
# -p means "print the signature only". It checks against the keychain
# key, and run.sh separately proves that key matches Info.plist's
# SUPublicEDKey — together that is the whole chain.
SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$FEED/appcast.xml" | head -1)"
[ -n "$SIG" ] || bad "signature extracted" "could not read sparkle:edSignature out of the appcast"
if "$TOOLS/sign_update" --verify "$FEED/SipAI-$NEW_VERSION.zip" "$SIG" > /dev/null 2>&1; then
    ok "signature verifies against the signing key"
else
    bad "signature verifies" \
        "sign_update --verify rejected the signature it just produced — the archive changed after signing, or the wrong key was used"
fi
say

if [ "${SIPAI_E2E_DRY_RUN:-0}" = "1" ]; then
    say
    say "== DRY RUN PASS =="
    say "   Everything up to the install is verified: two builds, a real"
    say "   archive, a real signature, a parseable appcast. Re-run without"
    say "   SIPAI_E2E_DRY_RUN=1 to drive the actual install."
    exit 0
fi

# ------------------------------------------------------------------ 4
say "4. Serving the feed on 127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED" \
    > "$STAGE/server.log" 2>&1 &
SERVER_PID=$!
/usr/bin/perl -e 'select(undef,undef,undef,1.5)'
curl -sf --max-time 5 --noproxy '*' "http://127.0.0.1:$PORT/appcast.xml" -o /dev/null \
    || bad "local feed reachable" "python3 http.server did not come up; see $STAGE/server.log"
ok "feed reachable"
say

# ------------------------------------------------------------------ 5
say "5. Launching $OLD_VERSION and asking it to update"
say
say "   ┌────────────────────────────────────────────────────────────┐"
say "   │  SipAI will open. Sparkle should offer version $NEW_VERSION.     │"
say "   │  Click  Install and Relaunch.                              │"
say "   │                                                            │"
say "   │  (If a turn were running, the install would be HELD until   │"
say "   │   it finished — that is the guard, and it is why the app    │"
say "   │   is launched here with no session open.)                  │"
say "   └────────────────────────────────────────────────────────────┘"
say

HOLD="${SIPAI_E2E_HOLD:-}"
if [ -n "$HOLD" ]; then
    say "   ┌────────────────────────────────────────────────────────────┐"
    say "   │  HOLD RUN: a pretend agent turn runs for ${HOLD}s after the   │"
    say "   │  click. Click  Install and Relaunch, then, in the sheet,    │"
    say "   │  Wait for the Turn.  The install must land only after the  │"
    say "   │  pretend turn ends. Meanwhile the sidebar says it will     │"
    say "   │  install for 5 s, and the Settings badge + Install Now stay.│"
    say "   └────────────────────────────────────────────────────────────┘"
    say
fi

SIPAI_UPDATER_FORCE_ENABLED=1 \
SIPAI_UPDATER_FEED_URL="http://127.0.0.1:$PORT/appcast.xml" \
SIPAI_UPDATER_SIMULATE_TURN="$HOLD" \
no_proxy="127.0.0.1,localhost" \
NO_PROXY="127.0.0.1,localhost" \
    "$APPS/SipAI.app/Contents/MacOS/SipAI" > "$STAGE/app.log" 2>&1 &
APP_PID=$!

/usr/bin/perl -e 'select(undef,undef,undef,3)'
if ! kill -0 "$APP_PID" 2>/dev/null; then
    bad "staged app launched" "$(head -5 "$STAGE/app.log")"
fi
ok "app running (pid $APP_PID)"

# The updater's own menu item is the trigger a user would reach for, but
# Sparkle also checks on its own schedule; give it a nudge by waiting.
say
say "   waiting up to 240s for the bundle on disk to become $NEW_VERSION…"

DEADLINE=$(( $(date +%s) + 240 ))
INSTALLED=""
ASK_AT=""          # epoch second of the click — the pretend turn runs from here
HOLD_BEGAN=""      # epoch second the app reported the hold beginning (Wait clicked)
LANDED_AT=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if [ -n "$HOLD" ] && [ -z "$ASK_AT" ] \
       && grep -q "SIPAI_UPDATER: asking" "$STAGE/app.log" 2>/dev/null; then
        ASK_AT="$(date +%s)"
        say "   Install and Relaunch was clicked; the sheet is up — click Wait for the Turn"
    fi
    if [ -n "$HOLD" ] && [ -z "$HOLD_BEGAN" ] \
       && grep -q "SIPAI_UPDATER: hold began" "$STAGE/app.log" 2>/dev/null; then
        HOLD_BEGAN="$(date +%s)"
        say "   hold began (the app said so) — waiting for the pretend turn to end"
    fi
    V="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
         "$APPS/SipAI.app/Contents/Info.plist" 2>/dev/null)"
    if [ "$V" = "$NEW_VERSION" ]; then INSTALLED=yes; LANDED_AT="$(date +%s)"; break; fi
    /usr/bin/perl -e 'select(undef,undef,undef,1)'
done
say

if [ -n "$HOLD" ]; then
    # The hold's own evidence, from the lines the controller writes ONLY
    # under the harness override.
    if [ -n "$HOLD_BEGAN" ]; then
        ok "the app reported the hold beginning (the sheet was answered with Wait)"
    else
        bad "the app reported the hold beginning" \
            "no 'SIPAI_UPDATER: hold began' in $STAGE/app.log — was the sheet shown, and was Wait clicked? (Interrupt is the other run.)"
    fi
    if grep -q "hid Sparkle's status window: true" "$STAGE/app.log"; then
        ok "Sparkle's inert 'Ready to Install' window was hidden for the hold"
    else
        say "  NOTE  the app could not find Sparkle's status window to hide it — the dead button stayed on screen"
    fi
    if grep -q "SIPAI_UPDATER: hold ended — invoking install" "$STAGE/app.log"; then
        ok "the hold ended by invoking Sparkle's install block"
    else
        bad "the hold ended by invoking Sparkle's install block" \
            "no 'hold ended' line in $STAGE/app.log"
    fi
    if [ -n "$INSTALLED" ] && [ -n "$ASK_AT" ]; then
        # The pretend turn is timed from the CLICK, not from "Wait":
        # its deadline is set when Sparkle first asks. The poll ticks
        # every 2 s and the log is polled every 1 s, so a landing up
        # to 3 s before the nominal end is the hold working, not
        # failing.
        if [ $(( LANDED_AT - ASK_AT )) -ge $(( HOLD - 3 )) ]; then
            ok "the install landed only after the pretend turn ended ($(( LANDED_AT - ASK_AT ))s after the click ≥ ${HOLD}s − 3)"
        else
            bad "the install landed only after the pretend turn ended" \
                "landed $(( LANDED_AT - ASK_AT ))s after the click, with a ${HOLD}s pretend turn — the hold did not hold"
        fi
    fi
fi

if [ -n "$INSTALLED" ]; then
    ok "the app on disk is now $NEW_VERSION — the update installed"
    B="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
         "$APPS/SipAI.app/Contents/Info.plist" 2>/dev/null)"
    [ "$B" = "$NEW_BUILD" ] && ok "build number advanced to $NEW_BUILD" \
                           || say "  NOTE  build number reads '$B', expected $NEW_BUILD"

    /usr/bin/perl -e 'select(undef,undef,undef,4)'
    if pgrep -f "$APPS/SipAI.app/Contents/MacOS/SipAI" > /dev/null 2>&1; then
        ok "app relaunched after the swap"
    else
        say "  NOTE  no running process found after the install — Sparkle may"
        say "        still be relaunching, or the relaunch failed. Check by hand."
    fi
    say
    say "== END-TO-END PASS =="
    exit 0
else
    say "  FAIL  the app on disk is still $(/usr/libexec/PlistBuddy -c \
            "Print :CFBundleShortVersionString" \
            "$APPS/SipAI.app/Contents/Info.plist" 2>/dev/null)"
    say
    say "  Where to look:"
    say "    * Did an update window appear at all? If not, the feed was not"
    say "      fetched — check $STAGE/app.log and $STAGE/server.log (the"
    say "      server logs every request it receives)."
    say "    * 'Update is improperly signed' → SUPublicEDKey in Info.plist"
    say "      disagrees with the key generate_appcast signed with."
    say "    * No window and no request in server.log → the feed override"
    say "      was ignored: UpdateController.feedURLString(for:) only honours"
    say "      it when the verdict is .forcedForTesting."
    say
    say "  Staging kept for inspection is about to be deleted; copy it now if"
    say "  you need it: $STAGE"
    exit 1
fi
