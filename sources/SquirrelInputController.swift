//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit
import Carbon

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  // The controller serving the focused client; used by the global Command+Space
  // event tap to toggle ascii_mode on the active session.
  static weak var current: SquirrelInputController?
  // Frontend pangu spacing on/off, mirrors `pangu_spacing/enabled` in the Rime config.
  private var panguSpacingEnabled = true
  // Smart space on/off, mirrors `smart_space/enabled` in the Rime config.
  private var smartSpaceEnabled = true
  // Auto-English on/off, mirrors `auto_english/enabled` in the Rime config (default off).
  // When the input has no candidates (typical for table schemas like wubi without
  // sentence input), the frontend takes over: it accumulates raw ASCII into its own
  // buffer and commits only on Return, so Rime stops trying to match Chinese.
  private var autoEnglishEnabled = false
  private var englishMode = false
  private var englishBuffer = ""
  private var englishCaret = 0
  // Candidate count from the previous update. Auto-English fires only on the
  // transition from "had candidates" to zero, so it won't grab inputs that start
  // at zero candidates (e.g. the z / ` reverse-lookup leaders, or uppercase).
  private var previousCandidateCount = 0

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      // In frontend English mode, swallow modifier changes so Rime can't act on
      // a Shift tap (e.g. toggle ascii_mode) while we own the composition.
      if englishMode {
        lastModifiers = modifiers
        handled = true
        break
      }
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15 (#715)
      // Some remote desktop software (e.g. Parsec) sends flagsChanged events with
      // keyCode defaulting to 0 (kVK_ANSI_A) instead of the actual modifier keycode,
      // causing a ghost 'a' keypress. Validate and infer the correct keycode from
      // the changed modifier flags when necessary. (#825)
      var keyCode = event.keyCode
      if !SquirrelKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = SquirrelKeycode.inferModifierKeycode(from: changes) else {
          lastModifiers = modifiers
          rimeUpdate()
          handled = true
          break
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      // Frontend English mode owns the keystrokes; it returns false (after flushing
      // its buffer) for keys it wants to pass on to the normal path below.
      if englishMode, handleEnglishModeKey(event: event, modifiers: modifiers) {
        return true
      }
      // Command+Space toggles between Chinese and ASCII (English) mode.
      // Requires the system Command+Space shortcut to be unbound so the event reaches here.
      if modifiers.intersection([.command, .control, .option, .shift]) == .command,
         event.keyCode == UInt16(kVK_Space) {
        toggleAsciiMode()
        return true
      }
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      insertPanguSpaceForPassthroughIfNeeded(event: event, modifiers: modifiers)

      if handleSmartSpaceIfNeeded(event: event, modifiers: modifiers) {
        return true
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  // Toggle Chinese/ASCII (English) mode on the active session. Reused by the
  // in-process keyDown handler and the global Command+Space event tap.
  func toggleAsciiMode() {
    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 { return }
    }
    rimeAPI.set_option(session, "ascii_mode", !rimeAPI.get_option(session, "ascii_mode"))
    rimeUpdate()
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    SquirrelInputController.current = self
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
    resetEnglishMode()
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
  }

  override func deactivateServer(_ sender: Any!) {
    // print("[DEBUG] deactivateServer: \(sender ?? "nil")")
    if englishMode { commitEnglishBuffer() }
    hidePalettes()
    commitComposition(sender)
    client = nil
    if SquirrelInputController.current === self {
      SquirrelInputController.current = nil
    }
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    if englishMode {
      commitEnglishBuffer()
      return
    }
    //  commit raw input
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()
    // The frontend owns the display while in English mode; nothing from Rime
    // should overwrite our marked text.
    if englishMode { return }

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        reloadSpacingSettings(schemaID: schemaId)
        // inline preedit
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          // if not inline, embed soft cursor in preedit string
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // Auto-English trigger: the input *just lost* its candidates (had some, now
      // zero) while still composing — e.g. an invalid wubi code. The "had some"
      // guard avoids hijacking inputs that begin at zero candidates, such as the
      // z / ` reverse-lookup leaders or uppercase English segments.
      let candidateCount = Int(ctx.menu.num_candidates)
      if autoEnglishEnabled, !englishMode, ctx.composition.length > 0,
         candidateCount == 0, previousCandidateCount > 0 {
        let seed = rimeAPI.get_input(session).map { String(cString: $0) } ?? ""
        if !seed.isEmpty {
          previousCandidateCount = 0
          _ = rimeAPI.free_context(&ctx)
          enterEnglishMode(seed: seed)
          return
        }
      }
      previousCandidateCount = candidateCount
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }
    // print("[DEBUG] commitString: \(string)")
    var string = string
    if needsPanguSpace(before: string, client: client) {
      string = " " + string
    }
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  // Pangu spacing: add a space at a CJK <-> ASCII-alphanumeric boundary, based on
  // the real character before the insertion point in the client app (robust to
  // cursor moves and pasted text). Falls back to no space when the app doesn't
  // expose its text (e.g. some terminals).
  private func needsPanguSpace(before string: String, client: IMKTextInput) -> Bool {
    guard panguSpacingEnabled, let next = string.unicodeScalars.first else { return false }
    // The committed text replaces the marked (composing) text, so the character
    // before it sits just before the marked range, not inside the composing buffer.
    let marked = client.markedRange()
    let insertLocation: Int
    if marked.location != NSNotFound {
      insertLocation = marked.location
    } else {
      let selected = client.selectedRange()
      guard selected.location != NSNotFound else { return false }
      insertLocation = selected.location
    }
    guard insertLocation > 0,
          let prev = client.attributedSubstring(from: NSRange(location: insertLocation - 1, length: 1))?.string.unicodeScalars.first
    else { return false }
    return (Self.isCJK(prev) && Self.isASCIIAlphanumeric(next)) ||
           (Self.isASCIIAlphanumeric(prev) && Self.isCJK(next))
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x4E00...0x9FFF,   // CJK Unified Ideographs
         0x3400...0x4DBF,   // Extension A
         0xF900...0xFAFF,   // Compatibility Ideographs
         0x20000...0x2A6DF, // Extension B
         0x2A700...0x2EBEF: // Extensions C–F
      return true
    default:
      return false
    }
  }

  private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
      return true
    default:
      return false
    }
  }

  // Typing right after a CJK character inserts a leading space for input that
  // passes straight through to the client without going through commit():
  // - ascii (English) mode: any letter/digit passes through;
  // - Chinese mode: digits pass through, but only when not composing (letters start
  //   composing and digits select candidates while composing).
  private func insertPanguSpaceForPassthroughIfNeeded(event: NSEvent, modifiers: NSEvent.ModifierFlags) {
    guard panguSpacingEnabled,
          modifiers.intersection([.command, .control, .option]).isEmpty,
          let next = event.charactersIgnoringModifiers?.unicodeScalars.first,
          let client = client else { return }
    let passesThrough: Bool
    if rimeAPI.get_option(session, "ascii_mode") {
      passesThrough = Self.isASCIIAlphanumeric(next)
    } else {
      passesThrough = (0x30...0x39).contains(next.value) && !isComposing()
    }
    guard passesThrough else { return }
    let selected = client.selectedRange()
    guard selected.location != NSNotFound, selected.location > 0,
          let prev = client.attributedSubstring(from: NSRange(location: selected.location - 1, length: 1))?.string.unicodeScalars.first,
          Self.isCJK(prev) else { return }
    client.insertText(" ", replacementRange: .empty)
  }

  // Read the spacing switches (mirror `pangu_spacing/enabled` and `smart_space/enabled`,
  // the same keys the Rime Lua scripts use). Schema config takes precedence over the
  // default config; an absent key defaults to enabled.
  private func reloadSpacingSettings(schemaID: String) {
    let defaultConfig = SquirrelConfig()
    _ = defaultConfig.open(config: "default")
    let schema = SquirrelConfig()
    defer {
      schema.close()
      defaultConfig.close()
    }
    let config = schema.open(schemaID: schemaID, baseConfig: defaultConfig) ? schema : defaultConfig
    panguSpacingEnabled = config.getBool("pangu_spacing/enabled") ?? true
    smartSpaceEnabled = config.getBool("smart_space/enabled") ?? true
    autoEnglishEnabled = config.getBool("auto_english/enabled") ?? false
  }

  // Smart space: when space is typed outside composition (and not in ASCII mode),
  // choose a full-width "　" or half-width " " space. It's half-width when either
  // side of the cursor is English — the previous char is printable ASCII (0x20–0x7E),
  // or the next char is an ASCII letter/digit — so a space landing between Chinese and
  // English stays half-width; full-width otherwise. When the previous char can't be
  // read (line start / unsupported app), fall back to the default behavior.
  private func handleSmartSpaceIfNeeded(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard smartSpaceEnabled,
          event.keyCode == UInt16(kVK_Space),
          modifiers.intersection([.command, .control, .option]).isEmpty,
          !rimeAPI.get_option(session, "ascii_mode"),
          !isComposing(),
          let client = client else { return false }
    let selected = client.selectedRange()
    guard selected.location != NSNotFound, selected.location > 0,
          let prev = client.attributedSubstring(from: NSRange(location: selected.location - 1, length: 1))?.string.unicodeScalars.first
    else { return false }
    let prevIsASCII = prev.value >= 0x20 && prev.value <= 0x7E
    let next = client.attributedSubstring(from: NSRange(location: selected.location, length: 1))?.string.unicodeScalars.first
    let nextIsEnglish = next.map(Self.isASCIIAlphanumeric) ?? false
    let space = (prevIsASCII || nextIsEnglish) ? " " : "\u{3000}"
    client.insertText(space, replacementRange: .empty)
    return true
  }

  private func isComposing() -> Bool {
    var ctx = RimeContext_stdbool.rimeStructInit()
    guard rimeAPI.get_context(session, &ctx) else { return false }
    defer { _ = rimeAPI.free_context(&ctx) }
    return ctx.composition.length > 0
  }

  // MARK: - Frontend English mode (no-candidate passthrough)

  private func enterEnglishMode(seed: String) {
    englishBuffer = seed
    englishCaret = seed.count
    englishMode = true
    rimeAPI.clear_composition(session)
    showEnglishPreedit()
  }

  // Show the English buffer as composing text, following the schema's inline_preedit
  // setting: inline marked text when on, otherwise the floating panel (where the user
  // expects the preedit to appear). The buffer is ASCII only, so its character count
  // equals the UTF-16 offset used for the caret.
  private func showEnglishPreedit() {
    if inlinePreedit {
      // soft_cursor is off here; the system shows a real text caret via the selection.
      show(preedit: englishBuffer, selRange: NSRange(location: 0, length: englishBuffer.utf16.count), caretPos: englishCaret)
      hidePalettes()
    } else {
      // We build this preedit ourselves, so insert the soft-cursor caret (the same
      // U+2038 ‸ Rime uses) at the caret position; the panel renders it inline.
      let caretIndex = englishBuffer.index(englishBuffer.startIndex, offsetBy: englishCaret)
      let display = String(englishBuffer[..<caretIndex]) + "\u{2038}" + String(englishBuffer[caretIndex...])
      // Keep a placeholder in the inline composing region (same trick as rimeUpdate),
      // and render the buffer in the floating panel with no candidates.
      show(preedit: "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
      showPanel(preedit: display, selRange: NSRange(location: 0, length: display.utf16.count), caretPos: englishCaret,
                candidates: [], comments: [], labels: [], highlighted: 0, page: 0, lastPage: true)
    }
  }

  // Commit the buffer as final text (reuses pangu spacing) and leave English mode.
  private func commitEnglishBuffer() {
    let text = englishBuffer
    englishMode = false
    englishBuffer = ""
    englishCaret = 0
    if text.isEmpty {
      show(preedit: "", selRange: .empty, caretPos: 0)
      hidePalettes()
    } else {
      commit(string: text)
    }
  }

  // Discard the buffer (Escape) and leave English mode without committing.
  private func cancelEnglishMode() {
    resetEnglishMode()
    show(preedit: "", selRange: .empty, caretPos: 0)
    hidePalettes()
  }

  private func resetEnglishMode() {
    englishMode = false
    englishBuffer = ""
    englishCaret = 0
    previousCandidateCount = 0
  }

  // After a backspace, if the (shortened) buffer is a pure-letter code, feed it back
  // to the engine. If candidates reappear, hand control back to the engine (so its
  // candidates / reverse lookup return); otherwise the engine lets go again and we
  // stay in English mode. Returns true when control was handed back to the engine.
  private func redirectToEngineIfMatches() -> Bool {
    guard englishBuffer.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
    _ = rimeAPI.set_input(session, englishBuffer)
    var ctx = RimeContext_stdbool.rimeStructInit()
    let hasCandidates = rimeAPI.get_context(session, &ctx) && ctx.menu.num_candidates > 0
    _ = rimeAPI.free_context(&ctx)
    if hasCandidates {
      resetEnglishMode()
      rimeUpdate()
      return true
    }
    rimeAPI.clear_composition(session)
    return false
  }

  // Returns true when the keystroke was consumed by English mode. Returns false to
  // pass the key on to the normal path (after flushing the buffer first).
  private func handleEnglishModeKey(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
    // Let Command/Control/Option combos through after committing the buffer.
    if !modifiers.intersection([.command, .control, .option]).isEmpty {
      commitEnglishBuffer()
      return false
    }
    switch event.keyCode {
    case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
      commitEnglishBuffer()
      return true
    case UInt16(kVK_Escape):
      cancelEnglishMode()
      return true
    case UInt16(kVK_Delete): // Backspace: delete the char before the caret.
      guard englishCaret > 0 else { return true }
      let index = englishBuffer.index(englishBuffer.startIndex, offsetBy: englishCaret - 1)
      englishBuffer.remove(at: index)
      englishCaret -= 1
      if englishBuffer.isEmpty {
        cancelEnglishMode()
      } else if !redirectToEngineIfMatches() {
        showEnglishPreedit()
      }
      return true
    case UInt16(kVK_LeftArrow):
      if englishCaret > 0 {
        englishCaret -= 1
        showEnglishPreedit()
      }
      return true
    case UInt16(kVK_RightArrow):
      if englishCaret < englishBuffer.count {
        englishCaret += 1
        showEnglishPreedit()
      }
      return true
    default:
      // Printable ASCII (letters, digits, symbols, space): insert at the caret.
      if let chars = event.characters, chars.unicodeScalars.count == 1,
         let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value <= 0x7E {
        let index = englishBuffer.index(englishBuffer.startIndex, offsetBy: englishCaret)
        englishBuffer.insert(contentsOf: chars, at: index)
        englishCaret += 1
        showEnglishPreedit()
        return true
      }
      // Anything else (Up/Down, Home/End, etc.): flush and let it through.
      commitEnglishBuffer()
      return false
    }
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }
}
