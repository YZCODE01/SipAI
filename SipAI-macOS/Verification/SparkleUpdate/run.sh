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
#   * Every copy on a Mac shares one defaults domain, so a record one
#     copy writes for "am I just updated?" silences another's update.
#
# Run after: a Sparkle upgrade, any change to Info.plist or the
# INFOPLIST_* build settings, any change to UpdaterAvailability or
# UpdateController, and any change to the scheduler's first tick or to
# release.sh's launch check (§4 holds the two apart).
#
# Offline and non-destructive. It builds, reads and compiles; it never
# publishes, never signs a release, and never touches the appcast.
#
# Run from INSIDE a running SipAI — an agent session in the Xcode Debug
# build, say — two defaults bite. The build lands in Xcode's own
# DerivedData, i.e. over the binary that is running; and the launch
# check starts a second SipAI on the SAME data folder (Foundation ignores
# $HOME for it, measured), whose scheduler ticks at once and whose first
# agent turn would take over the running copy's approver socket. So:
#
#   SIPAI_SPARKLE_DERIVED_DATA=<dir>   build there instead, with packages
#       from SIPAI_SPARKLE_PACKAGES (default <dir>-src) and no package
#       resolution — Xcode's own must not be raced (CLAUDE.md, the latch).
#       The packages directory is a COPY of Xcode's resolved one, made
#       once: cp -R ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages <dir>-src
#   SIPAI_SPARKLE_NO_LAUNCH=1          skip the launch check, with a NOTE

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"          # SipAI-macOS
PROJECT="$ROOT/SipAI.xcodeproj"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DD="${SIPAI_SPARKLE_DERIVED_DATA:-}"
PKGS="${SIPAI_SPARKLE_PACKAGES:-${DD:+$DD-src}}"
XCB_LOCATION=()
[ -n "$DD" ] && XCB_LOCATION=(-derivedDataPath "$DD" -clonedSourcePackagesDirPath "$PKGS" -disableAutomaticPackageResolution)
# Every xcodebuild below spells it ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"}:
# /bin/bash is 3.2 here, where "${a[@]}" of an EMPTY array is an unbound
# variable under `set -u`, and that spelling expands to nothing instead.

# Looked up when needed, not here: a fresh clone has no DerivedData
# until section 2 has built.
artifacts_dir() {
    if [ -n "$DD" ]; then echo "$PKGS/artifacts"
    else ls -d ~/Library/Developer/Xcode/DerivedData/SipAI-*/SourcePackages/artifacts 2>/dev/null | head -1; fi
}
built_app() {
    if [ -n "$DD" ]; then echo "$DD/Build/Products/Debug/SipAI.app"
    else find ~/Library/Developer/Xcode/DerivedData/SipAI-*/Build/Products/Debug \
             -maxdepth 1 -name 'SipAI.app' 2>/dev/null | head -1; fi
}

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
import Foundation

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

func expect(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "OK \(label)" : "NO \(label) \(detail)")
}

// The greyed-out checkbox of a copy with no updater shows the setting as
// a release copy on this Mac reads it: the user's choice, else
// Info.plist's default. An ABSOLUTE-path suite, so nothing is left in
// ~/Library/Preferences after the run.
let suite = UserDefaults(suiteName: CommandLine.arguments[1] + "/automatic-checks")!
let key = UpdaterAvailability.automaticChecksKey
expect("Sparkle's own key name", key == "SUEnableAutomaticChecks")
suite.removeObject(forKey: key)
expect("no choice made → Info.plist's default (on)",
       UpdaterAvailability.automaticChecksSetting(defaults: suite, infoDictionary: [key: true]) == true)
expect("no choice and no default → off",
       UpdaterAvailability.automaticChecksSetting(defaults: suite, infoDictionary: nil) == false)
suite.set(false, forKey: key)
expect("the user's OFF outranks the default",
       UpdaterAvailability.automaticChecksSetting(defaults: suite, infoDictionary: [key: true]) == false)
suite.set(true, forKey: key)
expect("the user's ON outranks a missing default",
       UpdaterAvailability.automaticChecksSetting(defaults: suite, infoDictionary: nil) == true)

// "Just updated" is judged per COPY. Every copy on a Mac shares one
// defaults domain; one shared record lets an Xcode build at the next
// version silence the installed copy's update to it.
let newer: (String, String) -> Bool = { (Int($0) ?? 0) > (Int($1) ?? 0) }
let release = "/Applications/SipAI.app", xcode = "/DerivedData/Debug/SipAI.app"
let onDisk: (String) -> Bool = { $0 == release || $0 == xcode }
var r = CopyLaunchRecord.note(records: [:], copy: release, build: "4", isNewer: newer, exists: onDisk)
expect("a first launch says nothing", !r.updated && r.records == [release: "4"], "\(r)")
r = CopyLaunchRecord.note(records: r.records, copy: xcode, build: "5", isNewer: newer, exists: onDisk)
expect("another copy's first launch says nothing and keeps the first copy's record",
       !r.updated && r.records == [release: "4", xcode: "5"], "\(r)")
r = CopyLaunchRecord.note(records: r.records, copy: release, build: "5", isNewer: newer, exists: onDisk)
expect("the installed copy updated to the build the Xcode copy already ran IS an update",
       r.updated && r.records[release] == "5", "\(r)")
r = CopyLaunchRecord.note(records: r.records, copy: release, build: "5", isNewer: newer, exists: onDisk)
expect("a relaunch at the same build says nothing", !r.updated, "\(r)")
r = CopyLaunchRecord.note(records: r.records, copy: xcode, build: "4", isNewer: newer, exists: onDisk)
expect("a downgrade says nothing and is recorded",
       !r.updated && r.records[xcode] == "4" && r.records[release] == "5", "\(r)")
r = CopyLaunchRecord.note(records: [release: "5", "/tmp/gone/SipAI.app": "9"], copy: xcode, build: "6",
                          isNewer: newer, exists: onDisk)
expect("a copy no longer on disk drops out of the record",
       r.records == [release: "5", xcode: "6"], "\(r)")
r = CopyLaunchRecord.note(records: [xcode: "5"], copy: xcode, build: "6", isNewer: newer, exists: { _ in false })
expect("the launching copy keeps its own entry whatever the file check says",
       r.updated && r.records == [xcode: "6"], "\(r)")
SWIFT

if xcrun swiftc -O -o "$TMP/gate" \
      "$ROOT/SipAI/Utilities/UpdaterAvailability.swift" \
      "$TMP/main.swift" 2> "$TMP/swiftc.err"; then
    OUT="$("$TMP/gate" "$TMP")"
    while IFS= read -r line; do
        case "$line" in
            OK*) ok "${line#OK }" ;;
            NO*) bad "${line#NO }" "SipAI/Utilities/UpdaterAvailability.swift — one of its rules changed" ;;
        esac
    done <<< "$OUT"
else
    bad "gate compiles standalone" \
        "SipAI/Utilities/UpdaterAvailability.swift must stay free of view/app state so it can compile alone: $(head -3 "$TMP/swiftc.err")"
fi
echo

# ---------------------------------------------------------------- 2
echo "2. The built app carries Sparkle's two required keys"

echo "   (building Debug${DD:+ into $DD}…)"
if ! xcodebuild -project "$PROJECT" -scheme SipAI -configuration Debug \
        ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"} build \
        > "$TMP/build.log" 2>&1; then
    bad "Debug build succeeds" "see $TMP/build.log (kept until this script exits)"
    echo
else
    APP="$(built_app)"

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

    # Sparkle's update alert offers "Automatically download and install
    # updates in the future" whenever this key is ABSENT and automatic
    # checks are on. UpdateController pins downloads off at every launch
    # (the README's promise), so the box's tick was undone at the next
    # relaunch — a checkbox that lies. Off, Sparkle hides the box and
    # its setter refuses the value.
    ALLOW_AUTO="$(plist_get SUAllowsAutomaticUpdates)"
    if [ "$ALLOW_AUTO" = "false" ]; then ok "SUAllowsAutomaticUpdates present and off"
    else bad "SUAllowsAutomaticUpdates present and off" \
             "SipAI/Info.plist — reads '$ALLOW_AUTO'; without the key Sparkle's alert offers an automatic-download box the controller resets every launch"; fi

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
    if [ "${SIPAI_SPARKLE_NO_LAUNCH:-0}" = "1" ]; then
        echo "  NOTE  launch check skipped (SIPAI_SPARKLE_NO_LAUNCH=1) — a second SipAI would share the running one's data folder"
    else
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
    fi
    echo

    # ------------------------------------------------------------ 3
    echo "3. The shipped public key matches the private key that signs"

    BIN="$(find "$(artifacts_dir)/sparkle/Sparkle/bin" -name generate_keys 2>/dev/null | head -1)"
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
        ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"} -showBuildSettings 2>/dev/null \
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

# The per-machine identity, and the one thing about it that fails
# silently. Signing.xcconfig signs ad hoc by default so a clone builds
# with no account; a gitignored Local.xcconfig overrides that with your
# own team or certificate. In an xcconfig the LAST assignment wins, so
# the include has to be the last thing in the file — placed above the
# CODE_SIGN_* lines it lets Local.xcconfig carry SIPAI_TEAM and nothing
# else, and a machine relying on a named certificate silently signs ad
# hoc again. Ad hoc means the designated requirement is a per-build
# cdhash, so every rebuild is a new app to TCC and the folder grants
# agent sessions depend on are asked for again.
SIGCFG="$ROOT/Signing.xcconfig"
LOCALCFG="$ROOT/Local.xcconfig"

# Trailing comments and whitespace are stripped so that a `// why`
# after the include, or an editor's trailing space, is not a FAIL.
LAST_SETTING_LINE="$(grep -v '^[[:space:]]*//' "$SIGCFG" | grep -v '^[[:space:]]*$' | tail -1 \
                     | sed 's|[[:space:]]*//.*$||; s/^[[:space:]]*//; s/[[:space:]]*$//')"
case "$LAST_SETTING_LINE" in
    '#include? "Local.xcconfig"')
        ok "Signing.xcconfig includes Local.xcconfig LAST" ;;
    *)
        bad "Signing.xcconfig includes Local.xcconfig LAST" \
            "last setting-bearing line is '$LAST_SETTING_LINE' — an include above the CODE_SIGN_* lines is overridden by them, and a named identity in Local.xcconfig is silently ignored" ;;
esac

# Trims the ends only: an identity NAME contains spaces, which the
# `setting` helper above strips out along with the indentation.
setting_raw() {   # setting_raw <configuration> <name>
    xcodebuild -project "$PROJECT" -scheme SipAI -configuration "$1" \
        ${XCB_LOCATION[@]+"${XCB_LOCATION[@]}"} -disableAutomaticPackageResolution -showBuildSettings 2>/dev/null \
      | awk '/^Build settings for action/{s=1} s' \
      | awk -F' = ' -v k=" $2" '$1 ~ k"$" {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}'
}

# Read against the REAL project, never a copy handed to -xcconfig. The
# command-line file does override the project, but the copy carries
# `#include? "Local.xcconfig"`, and a relative include is looked for
# beside the including file FIRST and then in the project's directory
# (measured, independent of cwd) — so a copy with nothing beside it
# silently picks up this machine's real Local.xcconfig and passes for
# the wrong reason.
EFFECTIVE_ID="$(setting_raw Debug CODE_SIGN_IDENTITY)"
if [ -f "$LOCALCFG" ]; then
    WANT_ID="$(grep -E '^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=' "$LOCALCFG" \
               | tail -1 | sed 's/^[^=]*=[[:space:]]*//; s|[[:space:]]*//.*$||; s/[[:space:]]*$//')"
    if [ -z "$WANT_ID" ]; then
        # A team-only Local.xcconfig: the identity is deliberately left
        # empty so automatic signing picks the certificate itself.
        ok "Local.xcconfig present, sets no identity (team route) — nothing to pin"
    elif [ "$EFFECTIVE_ID" = "$WANT_ID" ]; then
        ok "Local.xcconfig's identity reaches the build ('$WANT_ID')"
        # A name that resolves to nothing is a build failure rather than
        # a silent one, but it is still worth saying which name. `-v`
        # lists VALID identities only, so an expired or untrusted one
        # fails here too. The identity may be given as a name (quoted
        # in the listing) or as its SHA-1 (the token before the name).
        if security find-identity -v -p codesigning 2>/dev/null \
             | grep -qF -e "\"$WANT_ID\"" -e ") $WANT_ID \""; then
            ok "that identity is installed and valid in this keychain"
        else
            bad "that identity is installed and valid in this keychain" \
                "Local.xcconfig names '$WANT_ID' and no valid code-signing identity by that name (or hash) is in the keychain — missing, untrusted or expired; builds will fail at the codesign step"
        fi
    else
        bad "Local.xcconfig's identity reaches the build" \
            "Local.xcconfig says '$WANT_ID' but the build evaluates '$EFFECTIVE_ID' — the include is being overridden, so this machine is signing ad hoc"
    fi
else
    # A clone: no per-machine file, so the ad-hoc default is what
    # protects the promise that `git clone` then ⌘R just works.
    if [ "$EFFECTIVE_ID" = "-" ]; then
        ok "no Local.xcconfig — signs ad hoc, so a fresh clone builds"
    else
        bad "no Local.xcconfig — signs ad hoc, so a fresh clone builds" \
            "evaluates '$EFFECTIVE_ID'; a machine-specific identity in a COMMITTED file fails every other clone"
    fi
fi

# release.sh's launch check runs the exported app for a few seconds on
# the REAL data folder and then kills it. The scheduler's first due
# check has to wait longer than that, or a slot that fell due while
# SipAI was quit for the release is consumed — recorded as run — and
# its run spawned and killed inside the check. Both numbers are read
# off the files, so a change to either side fails here.
SCHED="$ROOT/SipAI/Models/ScheduledTaskScheduler.swift"
LAUNCH_WAIT="$(sed -n 's/.*select(undef,undef,undef,\([0-9.]*\)).*/\1/p' "$ROOT/Release/release.sh" | head -1)"
FIRST_TICK="$(sed -n 's/.*static let firstTickDelay: TimeInterval = \([0-9.]*\).*/\1/p' "$SCHED" | head -1)"
if [ -n "$LAUNCH_WAIT" ] && [ -n "$FIRST_TICK" ] \
   && awk -v w="$LAUNCH_WAIT" -v d="$FIRST_TICK" 'BEGIN { exit (d >= 2 * w) ? 0 : 1 }'; then
    ok "the scheduler's first due check ($FIRST_TICK s) waits out release.sh's launch check ($LAUNCH_WAIT s)"
else
    bad "the scheduler's first due check waits out release.sh's launch check" \
        "ScheduledTaskScheduler.firstTickDelay='$FIRST_TICK' vs release.sh's launch wait '$LAUNCH_WAIT' — a due task fires and is recorded inside the check"
fi
if awk '/func start\(agents: AgentManager, appState: AppState\)/ {inside=1}
        inside && /^        tick\(\)$/ {bare=1}
        inside && /firstTickDelay/ {delayed=1}
        inside && /^    \}$/ {exit}
        END {exit (delayed && !bare) ? 0 : 1}' "$SCHED"; then
    ok "start() schedules the first tick on firstTickDelay instead of ticking at once"
else
    bad "start() schedules the first tick on firstTickDelay instead of ticking at once" \
        "SipAI/Models/ScheduledTaskScheduler.swift — a synchronous tick() in start() is what fired a task inside the launch check"
fi

# ---------------------------------------------------------------- 5
# An update that arrives while an agent turn is running is HELD, and
# the hold used to be silent: Sparkle draws nothing once the delegate
# postpones the relaunch, and the "Install and Relaunch" button the
# user just clicked has already had its handler cleared. Everything
# that makes the hold visible, endable and safe to quit through is
# ours, and each piece fails silently — the rule is therefore pure and
# compiled here, the wiring is read out of the views, and the two
# Sparkle facts the code leans on are checked against the framework.
echo "5. The install hold"

cat > "$TMP/hold.swift" <<'SWIFT'
// Exercises UpdateInstallHold.reduce with nothing else linked.
typealias S = UpdateInstallHold.State
typealias E = UpdateInstallHold.Event
typealias F = UpdateInstallHold.Effect

func check(_ label: String, _ from: S, _ event: E, _ want: (S, F)) {
    let got = UpdateInstallHold.reduce(from, event)
    print(got == want ? "OK \(label)" : "NO \(label) got=\(got) want=\(want)")
}

// Nothing running: Sparkle proceeds, no question asked.
check("no turn → proceed", .idle, .installRequested(runningTurns: 0), (.idle, .proceed))
// A turn running: ask, never silently hold.
check("one turn → ask", .idle, .installRequested(runningTurns: 1), (.asking, .ask))
check("three turns → ask", .idle, .installRequested(runningTurns: 3), (.asking, .ask))
// A new install resets whatever the last session left behind.
check("install request resets a stale hold", .holding, .installRequested(runningTurns: 0), (.idle, .proceed))
check("install request resets a stale installing", .installing, .installRequested(runningTurns: 1), (.asking, .ask))

// The sheet.
check("Wait → holding", .asking, .choseWait, (.holding, .beginHold))
check("Interrupt → invoke", .asking, .choseInterrupt, (.installing, .invokeInstall))
check("Wait outside the sheet is ignored", .holding, .choseWait, (.holding, .none))
check("Interrupt outside the sheet is ignored", .idle, .choseInterrupt, (.idle, .none))

// The poll and the buttons end a hold, and ONLY a hold.
check("quiet moment ends the hold", .holding, .quietMoment, (.installing, .invokeInstall))
check("quiet moment while asking does nothing", .asking, .quietMoment, (.asking, .none))
check("quiet moment after invoke does nothing", .installing, .quietMoment, (.installing, .none))
check("quiet moment when idle does nothing", .idle, .quietMoment, (.idle, .none))
check("Install Now ends the hold", .holding, .installNow, (.installing, .invokeInstall))
check("Install Now while asking does nothing", .asking, .installNow, (.asking, .none))
check("Install Now after invoke does nothing", .installing, .installNow, (.installing, .none))

// Quit: drop the block, never invoke it — and never undo an install
// that is already under way (Sparkle's own quit request passes
// through the app delegate too).
check("quit while asking abandons", .asking, .quitRequested, (.idle, .abandon))
check("quit while holding abandons", .holding, .quitRequested, (.idle, .abandon))
check("quit while installing is a no-op", .installing, .quitRequested, (.installing, .none))
check("quit when idle is a no-op", .idle, .quitRequested, (.idle, .none))

// The cycle ending (relaunch, error alert, dismissal) resets everything.
for state in [S.idle, .asking, .holding, .installing] {
    check("session end resets from \(state)", state, .sessionEnded, (.idle, .abandon))
}

// Two walks: the block is invoked at most once, and never by a quit.
func walk(_ events: [E]) -> Int {
    var state = S.idle
    var invocations = 0
    for e in events {
        let (next, effect) = UpdateInstallHold.reduce(state, e)
        state = next
        if effect == .invokeInstall { invocations += 1 }
    }
    return invocations
}
let once = walk([.installRequested(runningTurns: 1), .choseWait, .quietMoment, .installNow, .quietMoment, .choseInterrupt])
print(once == 1 ? "OK a held install is invoked exactly once" : "NO a held install is invoked exactly once got=\(once)")
let never = walk([.installRequested(runningTurns: 1), .choseWait, .quitRequested, .quietMoment, .installNow])
print(never == 0 ? "OK a quit during the hold never invokes the block" : "NO a quit during the hold never invokes the block got=\(never)")
SWIFT

# Top-level code needs the entry file to be named main.swift; §1 already
# owns $TMP/main.swift, so this driver gets a directory of its own.
mkdir -p "$TMP/hold-driver" && mv "$TMP/hold.swift" "$TMP/hold-driver/main.swift"
if xcrun swiftc -O -o "$TMP/hold" \
      "$ROOT/SipAI/Utilities/UpdateInstallHold.swift" \
      "$TMP/hold-driver/main.swift" 2> "$TMP/hold.err"; then
    OUT="$("$TMP/hold")"
    while IFS= read -r line; do
        case "$line" in
            OK*) ok "${line#OK }" ;;
            NO*) bad "${line#NO }" "SipAI/Utilities/UpdateInstallHold.swift — reduce() rule changed" ;;
        esac
    done <<< "$OUT"
else
    bad "hold rule compiles standalone" \
        "SipAI/Utilities/UpdateInstallHold.swift must stay free of Sparkle/AppKit/view state: $(head -3 "$TMP/hold.err")"
fi

# The delegate methods, by their IMPORTED Swift names, against the real
# framework. A wrong spelling compiles as an unrelated method that
# Sparkle never calls — the hold would then silently be either never
# offered or never reset, and the Settings badge would never learn of a
# release (or never let go of one skipped).
FWDIR="$(ls -d "$(artifacts_dir)/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64" 2>/dev/null | head -1)"
if [ -z "$FWDIR" ]; then
    bad "Sparkle framework available for the delegate-name probe" "build the project once first"
else
    cat > "$TMP/names.swift" <<'SWIFT'
import Sparkle
final class P: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool { true }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {}
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {}
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {}
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {}
}
let selectors = [#selector(P.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)),
                 #selector(P.updater(_:didFinishUpdateCycleFor:error:)),
                 #selector(P.updater(_:didFindValidUpdate:)),
                 #selector(P.updaterDidNotFindUpdate(_:)),
                 #selector(P.updater(_:userDidMake:forUpdate:state:))]
let declared = selectors.allSatisfy {
    protocol_getMethodDescription(SPUUpdaterDelegate.self, $0, false, true).name != nil
}
// The badge's "is this release newer than me" is Sparkle's own
// comparator, over build numbers.
let compares = SUStandardVersionComparator.default.compareVersion("10", toVersion: "9") == .orderedDescending
print(declared && compares ? "OK" : "NO")
SWIFT
    if xcrun swiftc -F "$FWDIR" -framework Sparkle -o "$TMP/names" "$TMP/names.swift" 2> "$TMP/names.err" \
       && [ "$(DYLD_FRAMEWORK_PATH="$FWDIR" "$TMP/names")" = "OK" ]; then
        ok "every delegate method exists under the Swift name the controller implements"
    else
        bad "every delegate method exists under the Swift name the controller implements" \
            "SipAI/Models/UpdateController.swift — a Sparkle upgrade renamed a delegate method: $(head -3 "$TMP/names.err")"
    fi
    FWBIN="$FWDIR/Sparkle.framework/Versions/B/Sparkle"
    if strings -a "$FWBIN" | grep -qx "SUStatusController" \
       && strings -a "$FWBIN" | grep -qx "SUStatusInstallAndRelaunch"; then
        ok "the framework still names SUStatusController (the best-effort window close can find it)"
    else
        bad "the framework still names SUStatusController" \
            "SipAI/Models/UpdateController.swift sparkleStatusWindow() — the private class moved; the inert window would be left on screen"
    fi
fi

# The wiring, read out of the source.
UC="$ROOT/SipAI/Models/UpdateController.swift"
APP="$ROOT/SipAI/SipAIApp.swift"
CV="$ROOT/SipAI/Views/ContentView.swift"
SV="$ROOT/SipAI/Views/Settings/SettingsView.swift"

# Never a YES to Sparkle without the sheet: inside the postpone
# delegate, every `return true` sits directly after presentChoice.
if awk '/shouldPostponeRelaunchForUpdate item:/ {inside=1}
        inside && /^    nonisolated func/ && !/shouldPostponeRelaunchForUpdate/ {inside=0}
        inside && /return true/ { total++; if (prev ~ /presentChoice\(/) good++ }
        {prev=$0}
        END {exit (total>0 && total==good) ? 0 : 1}' "$UC"; then
    ok "the delegate postpones only after presenting the choice"
else
    bad "the delegate postpones only after presenting the choice" \
        "SipAI/Models/UpdateController.swift — a silent YES is a dead button in Sparkle's window"
fi

# A check during the hold would re-show Sparkle's dead window: Sparkle's
# own canCheckForUpdates is YES from the moment the alert was shown, and
# checkForUpdates on a session showing an update calls showUpdateInFocus,
# i.e. [_statusController showWindow:]. So the published flag is
# Sparkle's AND no held install, and the action refuses on that flag.
if grep -q 'sparkleCanCheckForUpdates && heldUpdateVersion == nil' "$UC" \
   && grep -q 'self?.sparkleCanCheckForUpdates = u.canCheckForUpdates' "$UC" \
   && awk '/^    func checkForUpdates\(\)/ {inside=1} inside && /guard canCheckForUpdates else \{ return \}/ {found=1} inside && /^    \}$/ {exit} END {exit found?0:1}' "$UC"; then
    ok "Check Now is disabled and refused while an install is held"
else
    bad "Check Now is disabled and refused while an install is held" \
        "SipAI/Models/UpdateController.swift — a check mid-hold re-shows the inert, non-closable Ready to Install window"
fi

if grep -q 'RunLoop.main.add(timer, forMode: .common)' "$UC" && ! grep -q 'Timer.scheduledTimer' "$UC"; then
    ok "the quiet-moment poll runs in the common run-loop modes"
else
    bad "the quiet-moment poll runs in the common run-loop modes" \
        "SipAI/Models/UpdateController.swift — a default-mode timer never fires under a file picker or a Sparkle alert"
fi

if grep -q 'func abandonHoldForQuit()' "$UC" \
   && awk '/func applicationShouldTerminate/ {inside=1} inside && /abandonHoldForQuit\(\)/ {a=NR} inside && /flushPendingEdits\(\)/ {f=NR} inside && /runner.cancel\(\)/ {c=NR} END {exit (a && f && c && a<f && a<c) ? 0 : 1}' "$APP"; then
    ok "applicationShouldTerminate abandons the hold before anything else"
else
    bad "applicationShouldTerminate abandons the hold before anything else" \
        "SipAI/SipAIApp.swift — with the poll in .common a tick inside the quit deferral would resume the install with a relaunch"
fi

if grep -q 'didFinishUpdateCycleFor' "$UC" && awk '/didFinishUpdateCycleFor/ {inside=1} inside && /\.sessionEnded/ {found=1} END {exit found?0:1}' "$UC"; then
    ok "the end of Sparkle's cycle resets the hold"
else
    bad "the end of Sparkle's cycle resets the hold" \
        "SipAI/Models/UpdateController.swift — a failed install would leave the next session unable to start a hold"
fi

# The hold is said the moment it starts (beside the sidebar's logo — the
# window Sparkle leaves behind is inert and gets hidden), marked on the
# Settings badge for as long as it lasts, and endable from Settings. No
# banner over the main window any more.
if grep -q 'UpdateAnnouncer.shared.announce(' "$UC" \
   && awk '/private func beginHold\(\)/ {inside=1} inside && /UpdateAnnouncer.shared.announce\(/ {a=1} inside && /publishBadge\(\)/ {b=1} inside && /^    }/ {exit} END {exit (a && b) ? 0 : 1}' "$UC" \
   && grep -q 'items.append(.appInstall(version: heldUpdateVersion))' "$UC" \
   && grep -q 'updates.installNow()' "$SV" \
   && ! grep -q 'UpdateHoldBanner' "$CV"; then
    ok "the hold is said beside the logo, marked on the badge, and endable from Settings"
else
    bad "the hold is said beside the logo, marked on the badge, and endable from Settings" \
        "SipAI/Models/UpdateController.swift beginHold / Settings/SettingsView.swift — a hold nobody is told about reads as a dead Install button"
fi

if grep -q 'updateController.config = configManager' "$APP" && grep -q 'appDelegate.updateController = updateController' "$APP"; then
    ok "the controller is wired into the app delegate and the config"
else
    bad "the controller is wired into the app delegate and the config" \
        "SipAI/SipAIApp.swift onAppear — without the delegate wiring the quit never abandons the hold"
fi

# The harness knob must be unreachable on a shipped build: read only
# inside the .forcedForTesting guard, and nowhere else.
if [ "$(grep -c 'environment\[Self.simulatedTurnEnvironmentVariable\]' "$UC")" = "1" ] \
   && awk '/environment\[Self.simulatedTurnEnvironmentVariable\]/ { if (p2 ~ /availability == .forcedForTesting/ || p1 ~ /availability == .forcedForTesting/) found=1 } {p2=p1; p1=$0} END {exit found?0:1}' "$UC"; then
    ok "the simulated-turn knob is read only under the harness override"
else
    bad "the simulated-turn knob is read only under the harness override" \
        "SipAI/Models/UpdateController.swift — an environment variable must not be able to hold a shipped copy's install"
fi

# Given no answer from the delegate, Sparkle prefers a feed URL stored in
# the app's user defaults over Info.plist — and any process running as
# the user can write one. So a shipped copy answers with its compiled
# feed itself; only the harness override reads the environment.
FEED_FN="$(awk '/func feedURLString\(for updater: SPUUpdater\)/ {inside=1} inside {print} inside && /^    \}$/ {exit}' "$UC")"
if grep -q 'object(forInfoDictionaryKey: "SUFeedURL")' <<<"$FEED_FN" \
   && grep -q 'availability == .forcedForTesting' <<<"$FEED_FN" \
   && ! grep -q 'return nil' <<<"$FEED_FN"; then
    ok "a shipped copy answers with its compiled feed, never leaving it to the defaults"
else
    bad "a shipped copy answers with its compiled feed, never leaving it to the defaults" \
        "SipAI/Models/UpdateController.swift feedURLString(for:) — a nil answer lets a SUFeedURL written into the app's defaults re-point the feed"
fi

if ! grep -q 'terminate(' "$UC"; then
    ok "the controller never terminates the app itself"
else
    bad "the controller never terminates the app itself" \
        "SipAI/Models/UpdateController.swift — Sparkle's agent quits the host with an Apple event; a terminate from a dispatch block hangs the quit"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
