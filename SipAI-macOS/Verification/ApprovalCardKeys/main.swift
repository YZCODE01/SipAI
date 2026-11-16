// ApprovalCardKeys harness — see run.sh for what it pins and why.
//
// Arguments: <source-root> <work-dir>
// Environment: CARDKEYS_HARNESS_MCP_DIR (read by Stubs.swift), the
// directory the REAL MCPBridge binds its socket in and finds approver.py;
// CARD_KEYS_RENDER=<dir> writes PNGs of the cards as they are driven.
//
// The cards, the key monitor, the composer's text box, the bridge and
// approver.py are the shipping ones. What is the harness's own is the
// SCENARIO: a root view that stacks the pending cards over the composer
// the way the transcript does, and the keys it presses.
import SwiftUI
import AppKit
import Combine

// Unbuffered: a run that is cut short must still show how far it got.
setvbuf(stdout, nil, _IONBF, 0)

let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let renderDir = ProcessInfo.processInfo.environment["CARD_KEYS_RENDER"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
}

var passed = 0
var failed = 0
func section(_ title: String) { print("\n" + title) }
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(name)" + (d.isEmpty ? "" : "\n        \(d)"))
    }
}
func note(_ text: String) { print("        \(text)") }

func pump(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@discardableResult
func pumpUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return condition()
}

// MARK: - The real bridge and the real approver.py

let mcpDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARDKEYS_HARNESS_MCP_DIR"]!,
                 isDirectory: true)
let approverPath = mcpDir.appendingPathComponent("approver.py").path
let socketPath = mcpDir.appendingPathComponent("approver.sock").path
let draftUuid = "0123456789abcdef0123456789abcdef"

/// One approver process and one tools/call, the way claude makes it.
final class ApproverCall {
    let process = Process()
    private let stdout = Pipe()

    init(tool: String, input: [String: Any]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", approverPath]
        var env = ProcessInfo.processInfo.environment
        env["SIPAI_APPROVER_SOCKET"] = socketPath
        env["SIPAI_SESSION_ID"] = draftUuid
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try! process.run()
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": ["name": "approve",
                                              "arguments": ["tool_name": tool, "input": input]]]
        stdin.fileHandleForWriting.write(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8) + Data("\n".utf8))
        stdin.fileHandleForWriting.write(
            (try! JSONSerialization.data(withJSONObject: call)) + Data("\n".utf8))
        try? stdin.fileHandleForWriting.close()
    }

    var answered: Bool { !process.isRunning }

    /// What claude would read back: the permission result, decoded.
    func result(within seconds: TimeInterval = 10) -> [String: Any] {
        pumpUntil(seconds) { !self.process.isRunning }
        guard !process.isRunning else { return [:] }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["id"] as? Int == 2,
                  let result = obj["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  let inner = content.first?["text"] as? String,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any]
            else { continue }
            return decoded
        }
        return [:]
    }
}

/// approver.py in its hook mode, fed what claude's PermissionRequest hook
/// is fed: the call and claude's own suggestions for it.
func reportSuggestions(tool: String, input: [String: Any], suggestions: [[String: Any]]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", approverPath, "--permission-context"]
    var env = ProcessInfo.processInfo.environment
    env["SIPAI_APPROVER_SOCKET"] = socketPath
    env["SIPAI_SESSION_ID"] = draftUuid
    process.environment = env
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": tool,
                                  "tool_input": input, "permission_suggestions": suggestions]
    stdin.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: payload))
    try? stdin.fileHandleForWriting.close()
    pumpUntil(10) { !process.isRunning }
}

// MARK: - The scenario: pending cards over the composer

final class Scene: ObservableObject {
    @Published var text = ""
    @Published var height: CGFloat = 30
    @Published var listedModes = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    @Published var modeBeforePlan: String? = nil
    var submits = 0
    var adopted: [String] = []
    /// A menu of the window's own — the shape of the sidebar's settings
    /// menu: a focusable view that takes the arrows and Return itself.
    @Published var menuUp = false
    var menuMoves = 0
    var menuReturns = 0
    /// "Implement this plan?" is on offer — the runner's `planFollowUp`.
    @Published var followUp = false
    var implemented = 0
    /// The modes "Implement this plan?" carried the plan out in.
    var implementedIn: [String] = []
    var stayed = 0
    /// The width the cards are drawn at; nil, the window's.
    @Published var cardWidth: CGFloat? = nil
}

struct MenuReplica: View {
    @ObservedObject var scene: Scene
    @FocusState private var focused: Bool

    var body: some View {
        Text("menu")
            .padding(8)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { scene.menuMoves += 1; return .handled }
            .onKeyPress(.return) { scene.menuReturns += 1; return .handled }
            .onAppear { focused = true }
    }
}

struct Root: View {
    @ObservedObject var bridge: MCPBridge
    @ObservedObject var scene: Scene
    let keys: ApprovalCardKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(bridge.pending) { req in
                card(req, owns: req.id == bridge.pending.last?.id)
                    .frame(width: scene.cardWidth)
            }
            // As the transcript draws it: once the turn is over, and never
            // under a card a turn waits on.
            if scene.followUp && bridge.pending.isEmpty {
                CodexPlanFollowUpCard(cardId: Self.followUpId,
                                      choices: CodexAppServer.harnessFollowUpChoices,
                                      ownsKeys: true, keys: keys,
                                      onImplement: { mode in
                                          scene.implemented += 1
                                          scene.implementedIn.append(mode)
                                          scene.followUp = false
                                      },
                                      onStay: { scene.stayed += 1; scene.followUp = false })
            }
            GrowingTextField(text: $scene.text, measuredHeight: $scene.height,
                             onSubmit: { scene.submits += 1 },
                             spellChecking: false, fontSize: 14, lineSpacing: 0)
                .frame(height: 60)
            if scene.menuUp { MenuReplica(scene: scene) }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 760, height: 1000, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(bridge)
        .background(CardWindowReader { [keys] window in keys.window = window })
        .onChange(of: activeCard, initial: true) { _, newest in
            keys.setActiveCard(newest)
        }
    }

    static let followUpId = "plan-follow-up:harness"

    /// The card on the keyboard, as the transcript picks it
    /// (`RunnerStreamView.activeCardId`): the newest one a turn waits on,
    /// else the plan follow-up.
    private var activeCard: String? {
        bridge.pending.last?.id ?? (scene.followUp ? Self.followUpId : nil)
    }

    /// The transcript's own order (`RunnerStreamView.approvalCard`): a card
    /// an agent's own protocol asked for is drawn from what it carries,
    /// FIRST — a kimi ExitPlanMode must never reach claude's plan card.
    @ViewBuilder
    private func card(_ req: MCPApprovalRequest, owns: Bool) -> some View {
        if let content = req.permissionContent {
            AgentPermissionCard(request: req, content: content, ownsKeys: owns, keys: keys,
                                onModeAdopted: { scene.adopted.append($0) })
        } else if let content = req.planContent {
            AgentPlanReviewCard(request: req, content: content, ownsKeys: owns, keys: keys,
                                onModeAdopted: { scene.adopted.append($0) })
        } else if let content = req.linkContent {
            AgentLinkCard(request: req, content: content, ownsKeys: owns, keys: keys)
        } else if req.toolName == MCPBridge.planApprovalTool {
            PlanApprovalCard(request: req, agentName: "Agent", ownsKeys: owns, keys: keys,
                             listedModes: scene.listedModes, modeBeforePlan: scene.modeBeforePlan,
                             savedNote: bridge.cardNotes[req.id],
                             onModeAdopted: { scene.adopted.append($0) })
        } else if let form = req.question {
            AgentQuestionCard(request: req, form: form, agentName: "Agent", ownsKeys: owns,
                              keys: keys, savedDraft: bridge.questionDrafts[req.id])
        } else {
            ToolApprovalCard(request: req, folder: nil, ownsKeys: owns, keys: keys,
                             onModeAdopted: { scene.adopted.append($0) })
        }
    }
}

/// An offscreen window that says it is key without the app being
/// activated — which would take the keyboard from whatever the user is
/// doing. AppKit draws a filled button's accent only in a key window, and
/// the filled button is what is under test.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // What AppKit's controls ask before drawing themselves active. Not in
    // the public headers, so they are answered by name — in this harness
    // only. Without them the render check below reports a note, not a
    // failure: the answers each key leads to are judged either way.
    @objc func hasKeyAppearance() -> Bool { true }
    @objc func hasMainAppearance() -> Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
}

enum Key {
    static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
    static let ret: UInt16 = 36, esc: UInt16 = 53, delete: UInt16 = 51
}

func findTextView(in view: NSView) -> NSTextView? {
    if let tv = view as? NSTextView { return tv }
    for sub in view.subviews {
        if let tv = findTextView(in: sub) { return tv }
    }
    return nil
}


@MainActor
final class Harness {
    let bridge = MCPBridge()
    let scene = Scene()
    let keys = ApprovalCardKeys()
    let window: KeyableWindow
    let host: NSHostingView<Root>
    let composer: NSTextView

    init?() {
        NSApplication.shared.setActivationPolicy(.accessory)
        bridge.isApprovalFocused = { _ in true }   // never post a notification from a harness
        bridge.questionPolicy = { _ in .ask }
        do {
            try bridge.ensureRuntime()
        } catch {
            print("FAIL  the real MCPBridge would not start: \(error)")
            return nil
        }
        // Told the way RunnerStreamView tells the real one, from
        // AppState.overlayHoldsKeys: an overlay of the window has the keys.
        keys.overlayHasKeys = { [scene] in scene.menuUp }
        keys.install()
        window = KeyableWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 760, height: 1000),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        host = NSHostingView(rootView: Root(bridge: bridge, scene: scene, keys: keys))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        pump(0.6)
        guard let composer = findTextView(in: host) else {
            print("FAIL  the composer's text view was not built — nothing below can hold")
            return nil
        }
        self.composer = composer
    }

    /// One key-down through NSApplication, the way the keyboard's arrive.
    func press(_ code: UInt16, repeating: Bool = false, flags: NSEvent.ModifierFlags = [],
               in target: NSWindow? = nil) {
        var characters = ""
        var modifiers = flags
        switch code {
        case Key.up: characters = "\u{F700}"; modifiers.insert([.function, .numericPad])
        case Key.down: characters = "\u{F701}"; modifiers.insert([.function, .numericPad])
        case Key.left: characters = "\u{F702}"; modifiers.insert([.function, .numericPad])
        case Key.right: characters = "\u{F703}"; modifiers.insert([.function, .numericPad])
        case Key.ret: characters = "\r"
        case Key.esc: characters = "\u{1B}"
        case Key.delete: characters = "\u{7F}"
        default: break
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: (target ?? window).windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: repeating, keyCode: code) else { return }
        NSApp.sendEvent(event)
        pump(0.08)
    }

    /// Type into whatever is being edited.
    func type(_ text: String) {
        (window.firstResponder as? NSTextView)?
            .insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        pump(0.15)
    }

    func focusComposer(text: String = "") {
        scene.text = text
        pump(0.1)
        window.makeFirstResponder(composer)
        pump(0.1)
    }

    /// Ask for one approval and wait until its card owns the keys and has
    /// settled. `settle: false` returns the instant the card is pending.
    @discardableResult
    func ask(_ tool: String, _ input: [String: Any], settle: Bool = true) -> (call: ApproverCall, request: MCPApprovalRequest?) {
        let known = Set(bridge.pending.map(\.id))
        let call = ApproverCall(tool: tool, input: input)
        var found: MCPApprovalRequest?
        pumpUntil(10) {
            found = bridge.pending.first { !known.contains($0.id) }
            return found != nil
        }
        if settle { pump(CardKeyRouting.settle + 0.25) }
        return (call, found)
    }

    func bash(_ command: String) -> [String: Any] { ["command": command, "description": "harness"] }

    /// What became of a card an agent's own protocol asked for.
    final class AgentAsk {
        var answers: [CardResolution] = []
        var request: MCPApprovalRequest?
    }

    /// A request the way a codex or kimi turn's driver makes one: through
    /// the bridge's one door, with the agent's own presentation and a
    /// responder — no approver, no socket.
    @discardableResult
    func askAgent(_ agent: String, _ tool: String, _ presentation: CardPresentation,
                  form: AgentQuestionForm? = nil, settle: Bool = true) -> AgentAsk {
        let asked = AgentAsk()
        let request = MCPApprovalRequest(agentKey: agent, sessionId: "agent-session", taskUuid: nil,
                                         toolName: tool, presentation: presentation, question: form,
                                         respond: { asked.answers.append($0) })
        asked.request = request
        bridge.enqueue(request)
        pump(0.15)
        if settle { pump(CardKeyRouting.settle + 0.25) }
        return asked
    }

    /// The window's pixels, to tell whether a card redrew.
    func snapshot() -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func render(_ name: String) {
        guard let renderDir else { return }
        try? FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: renderDir.appendingPathComponent(name + ".png"))
    }

    /// The horizontal centre of the pixels drawn in the accent colour inside
    /// the top `height` points of the window — where the filled button is.
    /// nil when nothing is filled.
    func filledCentre() -> (x: Double, y: Double, count: Int)? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB),
              let data = rep.bitmapData else { return nil }
        let (ar, ag, ab) = (Double(accent.redComponent) * 255, Double(accent.greenComponent) * 255,
                            Double(accent.blueComponent) * 255)
        let perPixel = rep.bitsPerPixel / 8
        var sumX = 0.0, sumY = 0.0, count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = data + y * rep.bytesPerRow + x * perPixel
                let (r, g, b) = (Double(p[0]), Double(p[1]), Double(p[2]))
                let distance = abs(r - ar) + abs(g - ag) + abs(b - ab)
                if distance < 90 {
                    sumX += Double(x); sumY += Double(y); count += 1
                }
            }
        }
        guard count > 200 else { return nil }
        let scale = Double(rep.pixelsWide) / Double(host.bounds.width)
        return (sumX / Double(count) / scale, sumY / Double(count) / scale, count)
    }

    func run() {
        // MARK: - 0. Controls

        section("0. Controls: the keys sent here travel the keyboard's own road")
        note("window key: \(window.isKeyWindow), app active: \(NSApp.isActive)")
        focusComposer(text: "hello")
        press(Key.ret)
        check("with no card waiting, Return in the message box is the box's own (it submits)",
              scene.submits == 1, "submits = \(scene.submits)")
        check("the agent composer's box says it yields its keys to a card while empty",
              (composer as? CardKeyYielding)?.yieldsCardKeys == true)
        focusComposer()

        // MARK: - 1. The permission card

        section("1. The permission card: arrows move the highlight, Return takes it")
        do {
            // Return already on its way when the card appears, and a held Return.
            let early = ask("Bash", bash("swift --version"), settle: false)
            press(Key.ret)
            check("a Return that lands as the card appears answers nothing", !early.call.answered
                    && bridge.pending.count == 1)
            pump(CardKeyRouting.settle + 0.25)
            press(Key.ret, repeating: true)
            check("a held-down Return (a key repeat) answers nothing", !early.call.answered)
            let before = scene.submits
            press(Key.ret)
            let allowed = early.call.result()
            check("Return on a settled card takes the highlighted answer — Allow, to begin with",
                  allowed["behavior"] as? String == "allow" && allowed["updatedPermissions"] == nil,
                  "got \(allowed)")
            check("…and the empty message box did not take that Return", scene.submits == before)
            check("a plain Allow remembers nothing", bridge.cache.isEmpty)

            // ← : Deny.
            let denied = ask("Bash", bash("swift --version"))
            render("1-permission-allow")
            let onAllow = filledCentre()
            press(Key.left)
            render("1-permission-deny")
            let onDeny = filledCentre()
            if let onAllow, let onDeny {
                check("the filled button moves with the arrow key: ← takes it from Allow to Deny",
                      onDeny.x < onAllow.x - 40 && abs(onDeny.y - onAllow.y) < 8,
                      "Allow at x \(Int(onAllow.x)) y \(Int(onAllow.y)), Deny at x \(Int(onDeny.x)) y \(Int(onDeny.y))")
            } else {
                note("no accent-filled button found in the render (a window that is not key draws none) — the move is judged by its answers below")
            }
            press(Key.ret)
            let deny = denied.call.result()
            check("←, Return: Deny", deny["behavior"] as? String == "deny"
                    && deny["message"] as? String == "Denied by SipAI.", "got \(deny)")
            check("…and a plain Deny remembers nothing", bridge.cache.isEmpty)

            // ↑ : Allow Always, with claude's own suggestion for the call.
            let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                       "rules": [["toolName": "Bash", "ruleContent": "swift build *"]]]
            reportSuggestions(tool: "Bash", input: bash("swift build -c release"), suggestions: [rule])
            let always = ask("Bash", bash("swift build -c release"))
            check("the call's card carries the rule approver.py's hook mode reported for it",
                  always.request?.alwaysOffer.count == 1
                    && always.request?.alwaysOffer.first?.destination == "localSettings")
            check("…and says what Allow Always will do with it",
                  ToolApprovalCard.alwaysLines(for: always.request?.alwaysOffer ?? [])
                    .first?.contains("“swift build *”") == true)
            render("1-permission-offer")
            let beforeUp = filledCentre()
            press(Key.up)
            let afterUp = filledCentre()
            if let beforeUp, let afterUp {
                check("↑ takes the filled button from Allow up to Allow Always",
                      afterUp.y < beforeUp.y - 10 && abs(afterUp.x - beforeUp.x) < 30,
                      "Allow at y \(Int(beforeUp.y)), Allow Always at y \(Int(afterUp.y))")
            }
            press(Key.ret)
            let alwaysResult = always.call.result()
            let handedBack = alwaysResult["updatedPermissions"] as? [[String: Any]] ?? []
            check("↑, Return: Allow Always hands claude back exactly the rule it suggested",
                  alwaysResult["behavior"] as? String == "allow" && handedBack.count == 1
                    && handedBack.first?["type"] as? String == "addRules"
                    && handedBack.first?["destination"] as? String == "localSettings"
                    && ((handedBack.first?["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String) == "swift build *",
                  "got \(alwaysResult)")
            check("…and SipAI itself remembers nothing for it (claude matches its own rule)",
                  bridge.cache.isEmpty)

            // The same command asked again takes its own suggestions, not the last call's.
            let plain = ask("Bash", bash("swift build -c release"))
            check("a suggestion is taken once: a later call with none reported offers none",
                  plain.request?.alwaysOffer.isEmpty == true)
            press(Key.up)
            press(Key.left)
            press(Key.ret)
            let denyAlways = plain.call.result()
            check("↑, ←, Return: Deny Always — a deny, remembered for this exact call",
                  denyAlways["behavior"] as? String == "deny" && bridge.cache.values.first?.count == 1,
                  "got \(denyAlways), cache \(bridge.cache)")
            let remembered = ApproverCall(tool: "Bash", input: bash("swift build -c release"))
            let rememberedResult = remembered.result()
            check("…so the very same call is refused without a card",
                  rememberedResult["behavior"] as? String == "deny" && bridge.pending.isEmpty,
                  "got \(rememberedResult)")

            // Claude runs its hook beside the approve call, so a card is
            // usually up before its suggestions land: it redraws when they do.
            let late = ask("Bash", bash("swift test --parallel"))
            let bare = snapshot()
            let testRule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                           "rules": [["toolName": "Bash", "ruleContent": "swift test *"]]]
            reportSuggestions(tool: "Bash", input: bash("swift test --parallel"), suggestions: [testRule])
            pumpUntil(5) { late.request?.alwaysOffer.isEmpty == false }
            pump(0.2)
            render("1-permission-late-offer")
            check("suggestions that land after the card is up are taken by it, and the card redraws to say so",
                  late.request?.alwaysOffer.count == 1 && bare != nil && snapshot() != bare)
            press(Key.up)
            press(Key.ret)
            let lateResult = late.call.result()
            check("…and Allow Always then hands that rule back",
                  ((lateResult["updatedPermissions"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]])?
                    .first?["ruleContent"] as? String == "swift test *", "got \(lateResult)")

            // An edit: claude suggests accept-edits for the session.
            let acceptEdits: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
            let write: [String: Any] = ["file_path": "/tmp/harness/x.txt", "content": "y\n"]
            reportSuggestions(tool: "Write", input: write, suggestions: [acceptEdits])
            let edit = ask("Write", write)
            scene.adopted = []
            press(Key.up)
            press(Key.ret)
            let editResult = edit.call.result()
            let editPermissions = editResult["updatedPermissions"] as? [[String: Any]] ?? []
            check("Allow Always on an edit hands back claude's accept-edits switch",
                  editPermissions.first?["type"] as? String == "setMode"
                    && editPermissions.first?["mode"] as? String == "acceptEdits", "got \(editResult)")
            check("…and tells the session's chip to follow", scene.adopted == ["acceptEdits"],
                  "adopted \(scene.adopted)")
        }

        // MARK: - 2. Text being typed keeps its keys

        section("2. Text being typed keeps every key")
        do {
            let held = ask("Bash", bash("ls -la"))
            focusComposer(text: "a half-written message")
            let before = scene.submits
            press(Key.left)
            press(Key.ret)
            check("Return in a message box with text in it answers nothing", !held.call.answered)
            check("…it is the box's own Return", scene.submits == before + 1)
            focusComposer()
            press(Key.ret)
            let result = held.call.result()
            check("…and the ← typed into that text never moved the highlight (Return is still Allow)",
                  result["behavior"] as? String == "allow", "got \(result)")

            // Modified keys are not a card's.
            let modified = ask("Bash", bash("ls -la"))
            press(Key.ret, flags: [.shift])
            press(Key.ret, flags: [.command])
            press(Key.left, flags: [.option])
            check("Shift-Return, ⌘Return and ⌥← are not a card's keys", !modified.call.answered)

            // Out of view.
            keys.cardIsInView = { false }
            press(Key.ret)
            check("a card scrolled out of sight is not answered by a key", !modified.call.answered)
            keys.cardIsInView = { true }

            // Another window.
            let other = KeyableWindow(contentRect: NSRect(x: -30_000, y: -28_000, width: 200, height: 100),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            other.orderFront(nil)
            press(Key.ret, in: other)
            check("a Return aimed at another window is not a card's", !modified.call.answered)
            other.orderOut(nil)

            // A sheet over the transcript's window.
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(sheet)
            pump(0.3)
            if window.attachedSheet != nil {
                press(Key.ret)
                check("nor is a key pressed while a sheet covers the window", !modified.call.answered)
                window.endSheet(sheet)
                pump(0.3)
            } else {
                note("the offscreen window took no sheet; the rule is read from the source in ApprovalCards §5")
            }
            window.makeKeyAndOrderFront(nil)
            focusComposer()
            press(Key.ret)
            check("back in view, Return answers it", modified.call.result()["behavior"] as? String == "allow")

            // A menu of the window's own — the sidebar's settings menu —
            // takes the arrows and Return through SwiftUI focus, which the
            // window dispatches AFTER a local monitor has seen the key; and
            // under it the first responder is the hosting view, as when
            // nothing has focus. The monitor has to be TOLD the menu is up.
            let behind = ask("Bash", bash("git status"))
            window.makeFirstResponder(nil)
            scene.menuUp = true
            pump(0.5)
            note("first responder under the menu: \(String(describing: window.firstResponder.map { Swift.type(of: $0) }))")
            press(Key.down)
            press(Key.ret)
            check("a menu of the window's own holding the keyboard keeps ↓ and Return — the card behind it is not answered",
                  !behind.call.answered && scene.menuMoves == 1 && scene.menuReturns == 1,
                  "card answered: \(behind.call.answered), menu moves \(scene.menuMoves), returns \(scene.menuReturns)")
            // The negative control: untold, the monitor takes both keys
            // from the menu — which is what the window alone would do.
            keys.overlayHasKeys = { false }
            press(Key.down)
            check("…and it is the telling that keeps them there: untold, the monitor takes the arrow from the menu",
                  scene.menuMoves == 1, "menu moves \(scene.menuMoves)")
            keys.overlayHasKeys = { [scene] in scene.menuUp }
            scene.menuUp = false
            pump(0.3)
            focusComposer()
            press(Key.ret)
            check("the menu gone, Return answers the card again",
                  behind.call.result()["behavior"] as? String == "allow")
        }

        // MARK: - 3. Several cards

        section("3. Several cards: only the newest takes the keys")
        do {
            let first = ask("Bash", bash("echo one"))
            let second = ask("Bash", bash("echo two"))
            render("3-two-cards")
            press(Key.ret)
            let secondResult = second.call.result()
            check("Return answers the newest card", secondResult["behavior"] as? String == "allow")
            check("…and only that one", !first.call.answered && bridge.pending.count == 1)
            press(Key.ret)
            check("…the card that is now the newest has to settle first: the same Return's echo answers nothing",
                  !first.call.answered)
            pump(CardKeyRouting.settle + 0.25)
            press(Key.left)
            press(Key.ret)
            check("then it takes the keys like any other", first.call.result()["behavior"] as? String == "deny")
        }

        // MARK: - 4. The plan card

        section("4. The plan card: claude's own answers, and a line for what to change")
        let planInput: [String: Any] = ["plan": "# Harness plan\n\n1. Do it.\n",
                                        "planFilePath": "/tmp/plans/harness.md"]
        func setMode(_ result: [String: Any]) -> String? {
            let permissions = result["updatedPermissions"] as? [[String: Any]] ?? []
            return permissions.first { $0["type"] as? String == "setMode" }?["mode"] as? String
        }
        do {
            scene.modeBeforePlan = nil
            scene.adopted = []
            let first = ask("ExitPlanMode", planInput)
            render("4-plan")
            press(Key.ret)
            let accept = first.call.result()
            check("Return on a plan launched on Plan: \"Yes, auto-accept edits\"",
                  accept["behavior"] as? String == "allow" && setMode(accept) == "acceptEdits"
                    && scene.adopted == ["acceptEdits"], "got \(accept), adopted \(scene.adopted)")

            scene.adopted = []
            let auto = ask("ExitPlanMode", planInput)
            press(Key.right)
            press(Key.ret)
            let autoResult = auto.call.result()
            check("→, Return: \"Yes, and use auto mode\" — claude is switched to auto, and the chip follows",
                  setMode(autoResult) == "auto" && scene.adopted == ["auto"], "got \(autoResult), adopted \(scene.adopted)")

            scene.adopted = []
            let manual = ask("ExitPlanMode", planInput)
            press(Key.left)
            press(Key.ret)
            let manualResult = manual.call.result()
            check("←, Return: \"Yes, manually approve edits\" — claude's default mode, the chip's Manual",
                  setMode(manualResult) == "default" && scene.adopted == ["manual"],
                  "got \(manualResult), adopted \(scene.adopted)")

            // Keep planning, with what to change.
            let revise = ask("ExitPlanMode", planInput)
            press(Key.left)
            press(Key.left)
            pump(0.3)
            let editor = window.firstResponder as? NSTextView
            let inField = editor != nil && editor !== composer
            check("←, ←: the highlight reaches \"No, keep planning\" and the cursor goes into its field",
                  inField, "first responder: \(String(describing: window.firstResponder))")
            if inField {
                type("Add a rollback step")
                render("4-plan-feedback")
                check("what is typed is kept on the bridge while the card waits",
                      revise.request.map { bridge.cardNotes[$0.id] == "Add a rollback step" } == true)
                press(Key.left)
                check("with words in the field, ← moves its caret and answers nothing", !revise.call.answered)
                press(Key.ret)
                let revised = revise.call.result()
                check("Return in the field: keep planning, with the user's words for the model to revise to",
                      revised["behavior"] as? String == "deny"
                        && revised["message"] as? String == PlanReplies.keepPlanning(feedback: "Add a rollback step"),
                      "got \(revised)")
            } else {
                press(Key.ret)
                let revised = revise.call.result()
                check("Return on \"No, keep planning\": a deny with the words the model reads",
                      revised["behavior"] as? String == "deny"
                        && revised["message"] as? String == PlanReplies.keepPlanning, "got \(revised)")
            }
            focusComposer()

            // Leaving the field again.
            let back = ask("ExitPlanMode", planInput)
            press(Key.left)
            press(Key.left)
            pump(0.3)
            press(Key.right)
            pump(0.2)
            press(Key.ret)
            let backResult = back.call.result()
            check("→ out of the empty field moves on to \"Yes, manually approve edits\"",
                  setMode(backResult) == "default", "got \(backResult)")
            focusComposer()

            // A turn that planned out of Bypass may go back to it.
            scene.modeBeforePlan = "bypassPermissions"
            pump(0.1)
            scene.adopted = []
            let bypass = ask("ExitPlanMode", planInput)
            render("4-plan-bypass")
            press(Key.ret)
            let bypassResult = bypass.call.result()
            check("a turn that planned out of Bypass: Return goes back to it",
                  setMode(bypassResult) == "bypassPermissions" && scene.adopted == ["bypassPermissions"],
                  "got \(bypassResult), adopted \(scene.adopted)")
            scene.modeBeforePlan = nil
            pump(0.1)

            // Esc.
            let escaped = ask("ExitPlanMode", planInput)
            press(Key.esc)
            if escaped.call.answered || pumpUntil(1.0, { escaped.call.answered }) {
                let result = escaped.call.result()
                check("Esc: keep planning, nothing said",
                      result["behavior"] as? String == "deny"
                        && result["message"] as? String == PlanReplies.keepPlanning, "got \(result)")
            } else {
                note("Esc did not reach the card's cancel shortcut in this offscreen window; its binding is read from the source in ApprovalCards §5")
                if let req = escaped.request { bridge.resolve(requestId: req.id, verdict: .deny) }
                _ = escaped.call.result()
            }
        }

        // MARK: - 5. The question card

        section("5. The question card: the keys walk it the way claude's terminal does")
        let q1 = "Which color should the probe use?"
        let q2 = "Which extras should it add?"
        let askInput: [String: Any] = ["questions": [
            ["question": q1, "header": "Color", "multiSelect": false,
             "options": [["label": "Red", "description": "Warm"],
                         ["label": "Blue", "description": "Cool"]]],
            ["question": q2, "header": "Extras", "multiSelect": true,
             "options": [["label": "Logs", "description": "Write logs"],
                         ["label": "Tests", "description": "Add tests"]]],
        ]]
        do {
            focusComposer()
            let asked = ask("AskUserQuestion", askInput)
            render("5-question")
            press(Key.down)                 // Red → Blue
            press(Key.ret)                  // pick Blue; a single choice moves on
            pump(0.6)
            check("↓, Return picks the second option, and a single choice moves on to the next question",
                  asked.request.map { bridge.questionDrafts[$0.id]?.answers[q1]?.labels == ["Blue"]
                      && bridge.questionDrafts[$0.id]?.page == 1 } == true,
                  "draft \(String(describing: asked.request.flatMap { bridge.questionDrafts[$0.id] }))")
            press(Key.ret)                  // Logs
            press(Key.down)                 // Tests
            press(Key.ret)
            check("on a multi-select, Return ticks each option the keyboard is on",
                  asked.request.map { Set(bridge.questionDrafts[$0.id]?.answers[q2]?.labels ?? []) == ["Logs", "Tests"] } == true)
            render("5-question-page-2")
            press(Key.left)                 // back to the first question
            pump(0.2)
            check("← on an option turns back to the previous question",
                  asked.request.map { bridge.questionDrafts[$0.id]?.page == 0 } == true)
            press(Key.right)
            pump(0.2)
            press(Key.down)                 // Tests
            press(Key.down)                 // the user's own answer
            pump(0.3)
            let inOther = (window.firstResponder as? NSTextView).map { $0 !== composer } ?? false
            check("↓ past the last option puts the cursor in \"Or type your own answer\"", inOther,
                  "first responder: \(String(describing: window.firstResponder))")
            press(Key.down)                 // the buttons: the main one
            pump(0.2)
            render("5-question-submit")
            press(Key.ret)
            let answered = asked.call.result()
            let answers = (answered["updatedInput"] as? [String: Any])?["answers"] as? [String: String] ?? [:]
            check("↓ to the buttons, Return: Submit sends the answers",
                  answered["behavior"] as? String == "allow" && answers == [q1: "Blue", q2: "Logs, Tests"],
                  "got \(answered)")
            focusComposer()

            // Chat about this.
            let chat = ask("AskUserQuestion", askInput)
            press(Key.down)                 // Blue
            press(Key.down)                 // own answer
            press(Key.down)                 // buttons → the main one
            press(Key.left)                 // Chat about this
            pump(0.2)
            render("5-question-chat")
            press(Key.ret)
            let chatResult = chat.call.result()
            check("… ←, Return on \"Chat about this\": a deny telling the agent to ask what to clarify",
                  chatResult["behavior"] as? String == "deny"
                    && (chatResult["message"] as? String)?.hasPrefix("The user wants to talk these questions over") == true
                    && (chatResult["message"] as? String)?.contains("\"\(q1)\"") == true,
                  "got \(chatResult)")
            focusComposer()

            // Return on an unanswered last page must not send an empty card.
            let single: [String: Any] = ["questions": [
                ["question": q1, "header": "Color", "multiSelect": false,
                 "options": [["label": "Red", "description": "Warm"], ["label": "Blue", "description": "Cool"]]]]]
            let empty = ask("AskUserQuestion", single)
            press(Key.down)                 // Blue
            press(Key.down)                 // own answer
            press(Key.down)                 // Submit (disabled: nothing answered)
            press(Key.ret)
            check("Return on Submit with nothing answered sends nothing", !empty.call.answered)
            press(Key.left)                 // Chat about this
            press(Key.left)                 // Skip
            press(Key.ret)
            let skipped = empty.call.result()
            check("←, ←, Return: Skip", skipped["message"] as? String == AgentQuestionReplies.skipped,
                  "got \(skipped)")
            focusComposer()

            // A pick corrected inside the beat that follows it. The card
            // moves the keyboard on a quarter of a second after a single
            // choice; an arrow pressed before then is the user changing
            // their mind, and the keyboard must stay where they put it —
            // moved to the main button under them, the next Return would
            // send the answer being corrected.
            let corrected = ask("AskUserQuestion", single)
            press(Key.ret)                  // Red
            press(Key.down)                 // …no: Blue, inside the beat
            pump(0.5)
            press(Key.ret)                  // pick Blue
            check("an arrow inside the beat after a pick keeps the keyboard there: the next Return picks, and sends nothing",
                  !corrected.call.answered
                    && corrected.request.map { bridge.questionDrafts[$0.id]?.answers[q1]?.labels == ["Blue"] } == true,
                  "answered \(corrected.call.answered), draft \(String(describing: corrected.request.flatMap { bridge.questionDrafts[$0.id] }))")
            pump(0.5)
            press(Key.ret)                  // the main button now
            let correctedAnswers = (corrected.call.result()["updatedInput"] as? [String: Any])?["answers"] as? [String: String] ?? [:]
            check("…and the answer sent is the corrected one", correctedAnswers == [q1: "Blue"], "got \(correctedAnswers)")
        }

        // MARK: - 6. An agent's own cards

        section("6. The cards codex and kimi ask for themselves: the same keyboard, the agent's own answers")
        do {
            focusComposer()
            let kimiChoices = [
                CardChoice(id: "approve_once", label: "Approve once", role: .accept),
                CardChoice(id: "approve_always", label: "Approve for this session", role: .acceptForSession),
                CardChoice(id: "reject", label: "Reject", role: .decline),
            ]
            func command(_ choices: [CardChoice], prompt: String? = nil, notes: [String] = []) -> CardPresentation {
                .permission(PermissionCardContent(
                    prompt: prompt, preview: .command("echo hi-from-harness", cwd: "/tmp/w", reason: nil),
                    notes: notes, choices: choices))
            }
            let cacheBefore = bridge.cache

            // A Return on its way as the card appears answers nothing here either.
            let early = askAgent("kimi", "Bash", command(kimiChoices), settle: false)
            press(Key.ret)
            check("a Return that lands as an agent's card appears answers nothing",
                  early.answers.isEmpty && bridge.pending.count == 1)
            pump(CardKeyRouting.settle + 0.25)
            render("6-kimi-permission")
            let onFirst = filledCentre()
            press(Key.ret)
            check("Return takes the agent's first acceptance, under the agent's own id",
                  early.answers == [.chose("approve_once")] && bridge.pending.isEmpty, "\(early.answers)")

            let always = askAgent("kimi", "Bash", command(kimiChoices))
            press(Key.right)
            let onSecond = filledCentre()
            if let onFirst, let onSecond {
                check("the filled answer moves with the arrow key",
                      onSecond.x > onFirst.x + 20, "x \(Int(onFirst.x)) → \(Int(onSecond.x))")
            } else {
                note("no accent-filled button found in the render — the move is judged by its answers")
            }
            press(Key.ret)
            check("→, Return: \"for this session\" is handed to the agent — nothing lands in SipAI's exact-call cache",
                  always.answers == [.chose("approve_always")] && bridge.cache == cacheBefore, "\(always.answers)")

            let held = askAgent("kimi", "Bash", command(kimiChoices))
            focusComposer(text: "half a message")
            let submitsBefore = scene.submits
            press(Key.ret)
            check("Return in a half-written message is the message's, never the card's",
                  held.answers.isEmpty && scene.submits == submitsBefore + 1,
                  "answers \(held.answers), submits \(scene.submits - submitsBefore)")
            focusComposer()
            press(Key.right)
            press(Key.right)
            press(Key.right)                // no wrap: still the last answer
            press(Key.ret)
            check("→ to the end, Return: the agent's refusal",
                  held.answers == [.chose("reject")], "\(held.answers)")

            // Codex's card: its own sentence, its two answers, a note.
            let codexChoices = [
                CardChoice(id: "accept", label: "Yes, proceed", role: .accept),
                CardChoice(id: "cancel", label: "No, and tell Codex what to do differently", role: .decline),
            ]
            let run = askAgent("codex", "exec_command",
                               command(codexChoices, prompt: "Would you like to run the following command?"))
            render("6-codex-command")
            press(Key.ret)
            check("codex's card: Return is \"Yes, proceed\"", run.answers == [.chose("accept")], "\(run.answers)")
            let refuse = askAgent("codex", "exec_command",
                                  command(codexChoices, prompt: "Would you like to run the following command?"))
            press(Key.esc)
            if !refuse.answers.isEmpty || pumpUntil(1.0, { !refuse.answers.isEmpty }) {
                check("Esc takes codex's own refusal — the one that ends the turn, as in its terminal",
                      refuse.answers == [.chose("cancel")], "\(refuse.answers)")
            } else {
                note("Esc did not reach the card's cancel shortcut in this offscreen window; → and Return take the same answer")
                press(Key.right)
                press(Key.ret)
                check("→, Return: codex's own refusal", refuse.answers == [.chose("cancel")], "\(refuse.answers)")
            }

            // A plan review, in kimi's answers — under the tool name claude's plan card answers to —
            // with the modes an approval continues in, as Claude Code's plan dialog names them.
            let planChoices = [
                CardChoice(id: "plan_approve", label: "Approve", role: .accept),
                CardChoice(id: "plan_revise", label: "Revise", role: .decline, adoptsMode: "kimi-plan"),
                CardChoice(id: "plan_reject_and_exit", label: "Reject and Exit", role: .other,
                           adoptsMode: "leave-plan"),
            ]
            let continueModes = [
                CardChoice(id: "", label: "Default", role: .other, adoptsMode: ""),
                CardChoice(id: "kimi-yolo", label: "Ask When Needed", role: .other, adoptsMode: "kimi-yolo"),
                CardChoice(id: "kimi-never-ask", label: "Never Ask", role: .other, adoptsMode: "kimi-never-ask"),
            ]
            let review = CardPresentation.plan(PlanCardContent(
                plan: "# Harness plan\n\n1. Do it.\n", filePath: "/tmp/plans/harness.md", choices: planChoices,
                continueModes: continueModes))
            scene.adopted = []
            let approved = askAgent("kimi", "ExitPlanMode", review)
            render("6-kimi-plan")
            press(Key.ret)
            check("a kimi plan review is the agent's own plan card: Return approves it into Default, in kimi's id, and the chip follows",
                  approved.answers == [.chose(PlanContinue.id(answer: "plan_approve", mode: ""))]
                    && scene.adopted == [""],
                  "\(approved.answers), adopted \(scene.adopted)")
            scene.adopted = []
            let approvedAWN = askAgent("kimi", "ExitPlanMode", review)
            press(Key.right)
            press(Key.ret)
            check("→, Return: approved into Ask When Needed, as the answer names it",
                  approvedAWN.answers == [.chose(PlanContinue.id(answer: "plan_approve", mode: "kimi-yolo"))]
                    && scene.adopted == ["kimi-yolo"],
                  "\(approvedAWN.answers), adopted \(scene.adopted)")
            scene.adopted = []
            let revised = askAgent("kimi", "ExitPlanMode", review)
            press(Key.right)
            press(Key.right)
            press(Key.right)
            press(Key.ret)
            check("→ → →, Return: Revise — kimi keeps planning, and the chip goes to Plan with the session",
                  revised.answers == [.chose("plan_revise")] && scene.adopted == ["kimi-plan"],
                  "\(revised.answers), adopted \(scene.adopted)")
            // A plan drawn up in an Ask When Needed turn: Return starts on that mode.
            scene.adopted = []
            let reviewAWN = CardPresentation.plan(PlanCardContent(
                plan: "# Harness plan\n\n1. Do it.\n", filePath: nil, choices: planChoices,
                continueModes: [
                    CardChoice(id: "", label: "Default", role: .other, adoptsMode: ""),
                    CardChoice(id: "kimi-yolo", label: "Ask When Needed", role: .accept, adoptsMode: "kimi-yolo"),
                    CardChoice(id: "kimi-never-ask", label: "Never Ask", role: .other, adoptsMode: "kimi-never-ask"),
                ]))
            let approvedInPlace = askAgent("kimi", "ExitPlanMode", reviewAWN)
            press(Key.ret)
            check("a plan reviewed in an Ask When Needed turn: Return approves it into Ask When Needed, not Default",
                  approvedInPlace.answers == [.chose(PlanContinue.id(answer: "plan_approve", mode: "kimi-yolo"))]
                    && scene.adopted == ["kimi-yolo"],
                  "\(approvedInPlace.answers), adopted \(scene.adopted)")
            // A plan offering approaches: the approach first, the mode next, Back between.
            let approaches = CardPresentation.plan(PlanCardContent(
                plan: "A or B", filePath: nil,
                choices: [CardChoice(id: "plan_opt_0", label: "Approach A", role: .accept),
                          CardChoice(id: "plan_opt_1", label: "Approach B", role: .accept),
                          CardChoice(id: "plan_revise", label: "Revise", role: .decline)],
                continueModes: continueModes))
            scene.adopted = []
            let picked = askAgent("kimi", "ExitPlanMode", approaches)
            press(Key.right)            // Approach B
            press(Key.ret)              // → the mode step, B's
            render("6-kimi-plan-mode-step")
            press(Key.ret)              // on the heels of the Return that brought the step up
            check("the mode step has to settle first: a second Return on the heels of the first answers nothing",
                  picked.answers.isEmpty && scene.adopted.isEmpty, "\(picked.answers)")
            pump(CardKeyRouting.settle + 0.2)
            press(Key.right)
            press(Key.right)
            press(Key.right)            // Back
            press(Key.ret)              // → the approaches again, B under the keys
            pump(CardKeyRouting.settle + 0.2)
            press(Key.ret)              // B again
            pump(CardKeyRouting.settle + 0.2)
            press(Key.right)            // B, then Ask When Needed
            press(Key.ret)
            check("approaches: B picked, Back, B again, then Ask When Needed — one answer, B's id with the mode",
                  picked.answers == [.chose(PlanContinue.id(answer: "plan_opt_1", mode: "kimi-yolo"))]
                    && scene.adopted == ["kimi-yolo"],
                  "\(picked.answers), adopted \(scene.adopted)")

            // Questions through the neutral form.
            let kimiQuestion = "Which database should we use?"
            let kimiForm = AgentQuestionForm(questions: [
                AgentQuestionForm.Question(
                    text: kimiQuestion, header: "DB",
                    options: [AgentQuestionForm.Option(label: "Postgres", description: "robust", preview: nil),
                              AgentQuestionForm.Option(label: "SQLite", description: "simple", preview: nil)],
                    multiSelect: false, id: "q0", allowsOther: false, isSecret: false)],
                offersSkip: true, offersChat: false)
            if let kimiForm {
                let asked = askAgent("kimi", "AskUserQuestion", .question, form: kimiForm)
                render("6-kimi-question")
                press(Key.down)             // SQLite
                press(Key.ret)              // pick it; with no question left the main button is next
                pump(0.6)
                press(Key.ret)              // Submit
                check("a kimi question: ↓, Return, Return picks and sends — the answer by the agent's own label",
                      asked.answers == [.answered([kimiQuestion: AgentQuestionAnswer(labels: ["SQLite"])])],
                      "\(asked.answers)")
                let skipped = askAgent("kimi", "AskUserQuestion", .question, form: kimiForm)
                press(Key.down)             // SQLite
                press(Key.down)             // straight to the buttons: no row for the user's own words
                let stillComposer = window.firstResponder === composer
                press(Key.left)             // Skip — and no "Chat about this" between
                press(Key.ret)
                check("with no answer in the user's own words and no Chat about this, ↓ ↓ ← lands on Skip",
                      skipped.answers == [.skipped] && stillComposer,
                      "\(skipped.answers), first responder \(String(describing: window.firstResponder))")
            } else {
                check("the neutral form takes a kimi question", false)
            }
            let codexQuestion = "Which UI toolkit?"
            let codexForm = AgentQuestionForm(questions: [
                AgentQuestionForm.Question(
                    text: codexQuestion, header: "UI",
                    options: [AgentQuestionForm.Option(label: "SwiftUI (Recommended)", description: "Native.", preview: nil),
                              AgentQuestionForm.Option(label: "AppKit", description: "Older.", preview: nil)],
                    multiSelect: false, id: "ui", allowsOther: true, isSecret: false)],
                offersSkip: true, offersChat: false)
            if let codexForm {
                let asked = askAgent("codex", "request_user_input", .question, form: codexForm)
                press(Key.down)             // AppKit
                press(Key.down)             // the user's own answer
                pump(0.3)
                let inOwn = (window.firstResponder as? NSTextView).map { $0 !== composer } ?? false
                check("a codex question that takes the user's own words: ↓ ↓ puts the cursor in its field", inOwn,
                      "first responder: \(String(describing: window.firstResponder))")
                if inOwn {
                    type("MyKit")
                    press(Key.ret)          // Return in the field does what the main button does
                } else if let id = asked.request?.id {
                    bridge.skipQuestion(requestId: id)
                }
                var own = AgentQuestionAnswer()
                own.otherPicked = true
                own.otherText = "MyKit"
                check("…and Return there sends them as the answer",
                      asked.answers == [.answered([codexQuestion: own])], "\(asked.answers)")
                focusComposer()
            } else {
                check("the neutral form takes a codex question", false)
            }

            // "Implement this plan?": the keys only once no card waits.
            scene.followUp = true
            let waiting = askAgent("codex", "exec_command",
                                   command(codexChoices, prompt: "Would you like to run the following command?"))
            press(Key.ret)
            check("with a card a turn waits on up, Return answers THAT card — the plan follow-up is not drawn under it",
                  waiting.answers == [.chose("accept")] && scene.implemented == 0 && scene.stayed == 0,
                  "\(waiting.answers), implemented \(scene.implemented)")
            press(Key.ret)
            check("the follow-up that then appears has to settle first: the same Return's echo answers nothing",
                  scene.implemented == 0 && scene.followUp)
            pump(CardKeyRouting.settle + 0.25)
            render("6-codex-plan-follow-up")
            press(Key.ret)
            check("then Return is \"Yes, implement in Default\"",
                  scene.implemented == 1 && scene.implementedIn == [""] && !scene.followUp,
                  "implemented \(scene.implementedIn)")
            scene.followUp = true
            pump(CardKeyRouting.settle + 0.4)
            press(Key.right)
            press(Key.ret)
            check("→, Return: \"Yes, implement in Workspace Write\" — the mode the answer names",
                  scene.implemented == 2 && scene.implementedIn == ["", "workspace-write"],
                  "implemented \(scene.implementedIn)")
            scene.followUp = true
            pump(CardKeyRouting.settle + 0.4)
            press(Key.right)
            press(Key.right)
            press(Key.ret)
            check("→ →, Return: \"No, stay in Plan mode\"", scene.stayed == 1 && scene.implemented == 2,
                  "stayed \(scene.stayed), implemented \(scene.implemented)")
        }

        section("7. An MCP server's cards: a form that waits for what its field takes, a link the keys open only when asked")
        do {
            focusComposer()
            let schema: [String: Any] = ["type": "object",
                                         "properties": ["count": ["type": "integer", "title": "How many",
                                                                  "minimum": 1, "maximum": 9]],
                                         "required": ["count"]]
            let hook: [String: Any] = ["mcp_server_name": "reports", "message": "Tell the report how many",
                                       "mode": "form", "requested_schema": schema]
            if let request = McpElicitation.Request(claudeHook: hook),
               let form = McpElicitation.card(for: request)?.question {
                let asked = askAgent("claude_code", "reports", .question, form: form)
                render("7-mcp-form")
                press(Key.ret)              // the field is the page's first stop: Return puts the cursor there
                pump(0.3)
                let inField = (window.firstResponder as? NSTextView).map { $0 !== composer } ?? false
                check("an MCP form's typed field: Return on it puts the cursor in it", inField,
                      "first responder: \(String(describing: window.firstResponder))")
                if inField {
                    type("12")              // past the field's maximum
                    press(Key.ret)
                    check("Return with words the field does not take sends nothing — the card waits",
                          asked.answers.isEmpty && bridge.pending.contains { $0.id == asked.request?.id })
                    press(Key.delete)
                    press(Key.delete)
                    type("3")
                    press(Key.ret)
                    var three = AgentQuestionAnswer()
                    three.otherText = "3"
                    three.otherPicked = true
                    check("…and once they fit, Return sends them",
                          asked.answers == [.answered([form.questions[0].text: three])], "\(asked.answers)")
                } else if let id = asked.request?.id {
                    bridge.skipQuestion(requestId: id)
                }
                focusComposer()
            } else {
                check("an MCP form with a number field is a question card", false)
            }

            // Codex's question before it runs an MCP tool: its four answers,
            // in codex's words, laid out as Claude's permission card lays out
            // its four — the two that keep the approval above, Cancel and
            // Allow below, Allow (where Return starts) at the bottom right.
            let toolMeta: [String: Any] = ["codex_approval_kind": "mcp_tool_call", "persist": ["session", "always"],
                                           "tool_params": ["path": "notes.md"]]
            let toolParams: [String: Any] = ["serverName": "reports", "mode": "form",
                                             "message": "Allow the reports MCP server to run tool \"save\"?",
                                             "requestedSchema": ["type": "object", "properties": [String: Any]()],
                                             "_meta": toolMeta]
            if let request = McpElicitation.Request(codexParams: toolParams),
               case .permission(let content, _)? = McpElicitation.card(
                   for: request,
                   sessionNote: "Allow for this session: don’t ask again for this tool until this message’s turn ends",
                   alwaysNote: "Always allow: don’t ask again for this tool, in SipAI or in Codex’s own apps") {
                let first = askAgent("codex", "reports", .permission(content))
                render("7-mcp-tool-approval")
                let allowAt = filledCentre()
                press(Key.ret)
                check("Codex's MCP tool card: Return is Allow", first.answers == [.chose("accept")], "\(first.answers)")
                if let allowAt {
                    check("…and Allow, the filled button, sits at the card's bottom right, as on Claude's card",
                          allowAt.x > Double(host.bounds.width) * 0.75, "Allow at x \(Int(allowAt.x))")
                }
                let always = askAgent("codex", "reports", .permission(content))
                let fromAllow = filledCentre()
                press(Key.up)
                let onAlways = filledCentre()
                render("7-mcp-tool-approval-always")
                if let fromAllow, let onAlways {
                    check("↑ takes the filled button from Allow straight up to Always allow",
                          onAlways.y < fromAllow.y - 10 && abs(onAlways.x - fromAllow.x) < 30,
                          "Allow at x \(Int(fromAllow.x)) y \(Int(fromAllow.y)), then x \(Int(onAlways.x)) y \(Int(onAlways.y))")
                } else {
                    note("no accent-filled button found in the render — the moves are judged by their answers")
                }
                press(Key.ret)
                check("…↑, Return: Always allow, under codex's own id",
                      always.answers == [.chose("accept_always")], "\(always.answers)")
                let session = askAgent("codex", "reports", .permission(content))
                let start = filledCentre()
                press(Key.left)
                let onCancel = filledCentre()
                if let start, let onCancel {
                    check("← from Allow is Cancel, on the same row",
                          onCancel.x < start.x - 40 && abs(onCancel.y - start.y) < 8,
                          "Allow at x \(Int(start.x)) y \(Int(start.y)), Cancel at x \(Int(onCancel.x)) y \(Int(onCancel.y))")
                }
                press(Key.up)
                press(Key.ret)
                check("←, ↑, Return: Allow for this session, above Cancel",
                      session.answers == [.chose("accept_session")], "\(session.answers)")
                // Too narrow for two columns, the answers stack in one column
                // in the order the rows read, Allow last — and the arrows walk
                // that column, not the rows it no longer draws.
                scene.cardWidth = 240
                pump(0.3)
                let narrow = askAgent("codex", "reports", .permission(content))
                render("7-mcp-tool-approval-narrow")
                press(Key.up)
                press(Key.ret)
                check("on a card too narrow for two columns, ↑ from Allow is Cancel, the answer just above it",
                      narrow.answers == [.chose("cancel")], "\(narrow.answers)")
                scene.cardWidth = nil
                pump(0.3)
            } else {
                check("Codex's MCP tool approval is a permission card", false)
            }

            // Return on "Open in browser" would open a browser: the checks
            // never press it.
            let link = askAgent("claude_code", "reports", .link(LinkCardContent(
                asker: "reports", message: "Sign in to the report service",
                url: "https://example.com/sign-in", opens: true)))
            render("7-mcp-link")
            press(Key.right)
            press(Key.ret)
            check("a link card: → then Return is Decline", link.answers == [.chose("decline")], "\(link.answers)")
            let unsafe = askAgent("claude_code", "reports", .link(LinkCardContent(
                asker: "reports", message: "Sign in", url: "http://example.com/sign-in", opens: false)))
            render("7-mcp-link-unsafe")
            press(Key.ret)
            check("a link SipAI will not open offers Decline alone, and Return takes it",
                  unsafe.answers == [.chose("decline")], "\(unsafe.answers)")
        }

        bridge.shutdown()
        keys.remove()
    }
}

// Synchronous on the main thread, never inside a main-queue block: the
// bridge hops to the main queue for every request, and a run loop nested
// inside such a block cannot drain it.
MainActor.assumeIsolated {
    guard let harness = Harness() else { exit(1) }
    harness.run()
}
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
