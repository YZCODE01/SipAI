#!/bin/bash
# Verification/SparkleUpdate/run.sh
#
# Pins the parts of the updater that fail SILENTLY.
#
# Every check here corresponds to something that breaks with no error
# message and no visible symptom until the day an update is actually
# needed — at which point it is too late, because the broken build is
# already on other people's machines:
#
#   * A missing SUFeedURL means "never find an update", not an error.
#   * A SUPublicEDKey that disagrees with the key in the keychain means
#     every signed update is rejected as forged.
#   * `INFOPLIST_KEY_<name>` silently drops keys Xcode does not know —
#     measured on this project, which is why Info.plist exists at all.
#   * The availability gate deciding "enabled" for a locally-built copy
#     would offer contributors our binary over their own work.
#
# Run after: a Sparkle upgrade, any change to Info.plist or the
# INFOPLIST_* build settings, and any change to UpdaterAvailability.
#
# Offline and non-destructive. It builds, reads and compiles; it never
# publishes, never signs a release, and never touches the appcast.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # SipAI-macOS
PROJECT="$ROOT/SipAI.xcodeproj"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; echo "        → $2"; FAIL=$((FAIL+1)); }

echo "== SparkleUpdate verification =="
echo

# ---------------------------------------------------------------- 1
echo "1. The availability gate (pure rule, compiled headlessly)"

cat > "$TMP/main.swift" <<'SWIFT'
// Exercises UpdaterAvailability.verdict without a bundle, a keychain,
// a network or an AgentManager — the same way TranscriptFollow and
// ScheduledTaskScheduler.decide are exercised.
func check(_ label: String, _ got: UpdaterAvailability.Verdict,
           _ want: UpdaterAvailability.Verdict) {
    print(got == want ? "OK \(label)" : "NO \(label) got=\(got) want=\(want)")
}

// A Developer ID build: has a team identifier.
check("developer-id build updates",
      UpdaterAvailability.verdict(teamIdentifier: "ABCDE12345", forceEnabled: false),
      .enabled)

// A self-signed certificate carries no team at all.
check("self-signed build does not update",
      UpdaterAvailability.verdict(teamIdentifier: nil, forceEnabled: false),
      .notDistributionSigned)

// Ad-hoc signing reports an empty string where unsigned reports nil.
// Neither is a team, and treating "" as one would enable the updater
// on an ad-hoc build.
check("ad-hoc (empty team) does not update",
      UpdaterAvailability.verdict(teamIdentifier: "", forceEnabled: false),
      .notDistributionSigned)

// The harness override, which is how a locally-signed build can be
// driven through a real update before a Developer ID exists.
check("override forces enable",
      UpdaterAvailability.verdict(teamIdentifier: nil, forceEnabled: true),
      .forcedForTesting)

// …and ONLY such a build. A distribution-signed copy must ignore the
// override outright: an environment variable must not be able to
// re-point a shipped updater at someone else's feed.
check("override is ignored on a distribution build",
      UpdaterAvailability.verdict(teamIdentifier: "ABCDE12345", forceEnabled: true),
      .enabled)

// allowsUpdates is what every caller actually branches on.
check("notDistributionSigned blocks",
      UpdaterAvailability.verdict(teamIdentifier: nil, forceEnabled: false).allowsUpdates
        ? .enabled : .notDistributionSigned,
      .notDistributionSigned)
SWIFT

if xcrun swiftc -O -o "$TMP/gate" \
      "$ROOT/SipAI/Utilities/UpdaterAvailability.swift" \
      "$TMP/main.swift" 2> "$TMP/swiftc.err"; then
    OUT="$("$TMP/gate")"
    while IFS= read -r line; do
        case "$line" in
            OK*) ok "${line#OK }" ;;
            NO*) bad "${line#NO }" "SipAI/Utilities/UpdaterAvailability.swift — verdict() rule changed" ;;
        esac
    done <<< "$OUT"
else
    bad "gate compiles standalone" \
        "SipAI/Utilities/UpdaterAvailability.swift must stay free of view/app state so it can compile alone: $(head -3 "$TMP/swiftc.err")"
fi
echo

# ---------------------------------------------------------------- 2
echo "2. The built app carries Sparkle's two required keys"

echo "   (building Debug…)"
if ! xcodebuild -project "$PROJECT" -scheme SipAI -configuration Debug build \
        > "$TMP/build.log" 2>&1; then
    bad "Debug build succeeds" "see $TMP/build.log (kept until this script exits)"
    echo
else
    APP="$(find ~/Library/Developer/Xcode/DerivedData/SipAI-*/Build/Products/Debug \
            -maxdepth 1 -name 'SipAI.app' 2>/dev/null | head -1)"

    plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }

    FEED="$(plist_get SUFeedURL)"
    if [ -n "$FEED" ]; then ok "SUFeedURL present ($FEED)"
    else bad "SUFeedURL present" \
             "SipAI/Info.plist — without it Sparkle never finds an update AND never errors"; fi

    case "$FEED" in
        https://*) ok "feed is HTTPS" ;;
        *) bad "feed is HTTPS" "SipAI/Info.plist — .dev is HSTS-preloaded; plain HTTP cannot work" ;;
    esac

    PUB="$(plist_get SUPublicEDKey)"
    if [ -n "$PUB" ]; then ok "SUPublicEDKey present"
    else bad "SUPublicEDKey present" \
             "SipAI/Info.plist — unsigned updates would be the only ones accepted"; fi

    # The delegate suppresses Sparkle's permission prompt, and Sparkle
    # only schedules automatic checks when the user has answered that
    # prompt OR this key pre-answers it. Suppressed prompt + no key =
    # the daily check silently never runs, on every installed copy.
    AUTO="$(plist_get SUEnableAutomaticChecks)"
    if [ "$AUTO" = "true" ]; then ok "SUEnableAutomaticChecks present and on"
    else bad "SUEnableAutomaticChecks present and on" \
             "SipAI/Info.plist — without it the suppressed permission prompt means no scheduled check ever runs"; fi

    # Release notes are HTML fetched from the feed host and rendered in a
    # WKWebView. Their CONTENT is not something the EdDSA key protects:
    # Sparkle accepts notes served over HTTPS without a signature, and
    # the signature — when there is one — is declared in the appcast,
    # which comes from the same host. So anyone who can serve the feed
    # can choose the text.
    #
    # What bounds that is this key staying OFF, which is Sparkle's
    # default: markup can mislead, script could act. Switching it on
    # turns a compromised feed from a phishing surface into code running
    # inside the app, and nothing else in the project would object.
    JS="$(plist_get SUEnableJavaScript)"
    if [ -z "$JS" ] || [ "$JS" = "false" ]; then
        ok "release-notes WebView has JavaScript off"
    else
        bad "release-notes WebView has JavaScript off" \
            "SUEnableJavaScript is '$JS' — remove it from SipAI/Info.plist"
    fi

    # The generated keys must SURVIVE the merge. This is the regression
    # that would follow from someone "tidying" Info.plist by restating
    # them: the generated value wins, and a stale hand-written copy
    # would be silently ignored — or, worse, GENERATE_INFOPLIST_FILE
    # gets switched off and the version stops tracking MARKETING_VERSION.
    if [ -n "$(plist_get CFBundleShortVersionString)" ] \
       && [ -n "$(plist_get CFBundleVersion)" ] \
       && [ -n "$(plist_get NSPrincipalClass)" ]; then
        ok "Xcode's generated keys still merge in"
    else
        bad "Xcode's generated keys still merge in" \
            "GENERATE_INFOPLIST_FILE must stay YES alongside INFOPLIST_FILE"
    fi

    # An AppIcon set with no images compiles without error or warning
    # and ships an app wearing the generic document icon. The catalog
    # only emits AppIcon.icns and the icon keys once the set holds
    # images, so the BUILT app is the test — the build log says nothing.
    if [ -f "$APP/Contents/Resources/AppIcon.icns" ] \
       && [ "$(plist_get CFBundleIconName)" = "AppIcon" ]; then
        ok "app icon compiled in (AppIcon.icns + CFBundleIconName)"
    else
        bad "app icon compiled in" \
            "AppIcon.appiconset must hold the icon PNGs — an empty set builds clean and ships the generic icon"
    fi

    # Sparkle is useless without its helpers: the framework alone
    # cannot install anything.
    SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    if [ -x "$SPK/Autoupdate" ] && [ -d "$SPK/Updater.app" ]; then
        ok "Sparkle.framework embedded with Autoupdate + Updater.app"
    else
        bad "Sparkle.framework embedded with helpers" \
            "the SPM product must be linked AND embedded in the SipAI target"
    fi

    # The load is the test — a signature can verify on an app that
    # cannot launch (see CLAUDE.md on hardened runtime + the debug
    # dylib). Adding an embedded framework is exactly the kind of
    # change that can break it.
    "$APP/Contents/MacOS/SipAI" > "$TMP/launch.log" 2>&1 &
    LPID=$!
    /usr/bin/perl -e 'select(undef,undef,undef,3)'
    if kill -0 $LPID 2>/dev/null; then
        ok "app launches with Sparkle embedded"
        # `wait` absorbs the shell's own "Killed: 9" job notice, which
        # otherwise prints on a PASSING run and reads like a failure.
        kill -9 $LPID 2>/dev/null
        wait $LPID 2>/dev/null
    else
        bad "app launches with Sparkle embedded" \
            "$(head -3 "$TMP/launch.log")"
    fi
    echo

    # ------------------------------------------------------------ 3
    echo "3. The shipped public key matches the private key that signs"

    BIN="$(find ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
            -name generate_keys 2>/dev/null | head -1)"
    if [ -z "$BIN" ]; then
        bad "Sparkle tools available" "run xcodebuild -resolvePackageDependencies first"
    else
        # -p prints the PUBLIC key for the private key already in the
        # keychain. A mismatch here means every update this machine
        # signs will be rejected by every copy already installed —
        # invisible until the first real release.
        KEYCHAIN_PUB="$("$BIN" -p 2>/dev/null | tr -d '[:space:]')"
        if [ -z "$KEYCHAIN_PUB" ]; then
            bad "a signing key exists in the keychain" \
                "run generate_keys — and export a backup immediately"
        elif [ "$KEYCHAIN_PUB" = "$PUB" ]; then
            ok "Info.plist key == keychain key"
        else
            bad "Info.plist key == keychain key" \
                "SipAI/Info.plist SUPublicEDKey is not the key this machine signs with"
        fi
    fi
fi

echo

# ---------------------------------------------------------------- 4
# Embedding a framework gave library validation something to reject,
# and the three settings below are the ones the WRONG fixes move. Each
# is read straight out of the build settings — no extra build, and no
# dependence on which certificate happens to be installed.
echo "4. The signing settings an embedded framework makes load-bearing"

setting() {   # setting <configuration> <name>
    xcodebuild -project "$PROJECT" -scheme SipAI -configuration "$1" \
        -showBuildSettings 2>/dev/null \
      | awk -F' = ' -v k=" $2" '$1 ~ k"$" {gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

# Release must KEEP hardened runtime: it is a notarization requirement,
# and the tempting way to make a local Release build launch is to turn
# it off in the project — which passes here and fails at notarization.
if [ "$(setting Release ENABLE_HARDENED_RUNTIME)" = "YES" ]; then
    ok "Release keeps hardened runtime"
else
    bad "Release keeps hardened runtime" \
        "notarization requires it — smoke-test with ENABLE_HARDENED_RUNTIME=NO on the command line instead of changing the project"
fi

# Debug must NOT have it: library validation would reject both
# SipAI.debug.dylib and Sparkle.framework. See CLAUDE.md.
if [ "$(setting Debug ENABLE_HARDENED_RUNTIME)" = "NO" ]; then
    ok "Debug still has hardened runtime off"
else
    bad "Debug still has hardened runtime off" \
        "library validation rejects SipAI.debug.dylib AND Sparkle.framework under the team-less local cert"
fi

# The other tempting fix. This entitlement would ride into the
# distribution build and switch off the check that stops a swapped
# framework loading into a signed app — for an updater, the whole point.
ENT="$(setting Release CODE_SIGN_ENTITLEMENTS)"
case "$ENT" in
    "")   ENT_FILE="" ;;                    # no entitlements file at all
    /*)   ENT_FILE="$ENT" ;;                # absolute
    *)    ENT_FILE="$ROOT/$ENT" ;;          # relative to SRCROOT
esac
if [ -z "$ENT_FILE" ]; then
    ok "Release does not disable library validation (no entitlements file)"
elif [ ! -f "$ENT_FILE" ]; then
    # Passing here because the file could not be read would be the
    # check going quietly blind — exactly what it exists to prevent.
    bad "Release does not disable library validation" \
        "CODE_SIGN_ENTITLEMENTS is '$ENT' but no such file — cannot verify"
elif grep -q 'disable-library-validation' "$ENT_FILE"; then
    bad "Release does not disable library validation" \
        "$ENT — never ship this entitlement; it defeats the protection the updater depends on"
else
    ok "Release does not disable library validation"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
