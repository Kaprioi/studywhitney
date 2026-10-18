import Cocoa
import WebKit
import EventKit

/// Web view that reacts to the first click even when the app isn't active,
/// so Whitney can be petted without focusing StudyWhitney first.
final class ClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The Claude API key lives in the login Keychain, never in the web page.
enum KeyStore {
    static let service = "local.studywhitney.claude"
    static let account = "api-key"
    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Turns any string into a JavaScript string literal.
func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s])
    let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(arr.dropFirst().dropLast())
}

/// To-dos go to Apple Reminders and/or Calendar through EventKit. macOS asks for access once for each.
final class AppleSync {
    let store = EKEventStore()

    func access(_ type: EKEntityType, _ done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { done(ok) } }
        if #available(macOS 14.0, *) {
            if type == .reminder { store.requestFullAccessToReminders(completion: finish) } else { store.requestFullAccessToEvents(completion: finish) }
        } else { store.requestAccess(to: type, completion: finish) }
    }

    /// Creates, updates or removes the reminder and calendar event for one to-do, then reports the new identifiers.
    func sync(_ t: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let to = t["to"] as? String ?? "none"
        var out: [String: Any] = ["key": t["key"] as? String ?? "", "announce": t["announce"] as? Bool ?? false, "to": to]
        var errors: [String] = []
        step(.reminder, want: to == "reminders" || to == "both", id: t["reminderId"] as? String, t) { id, err in
            out["reminderId"] = id ?? ""; if let err { errors.append(err) }
            self.step(.event, want: to == "calendar" || to == "both", id: t["eventId"] as? String, t) { id, err in
                out["eventId"] = id ?? ""; if let err { errors.append(err) }
                out["error"] = errors.joined(separator: " ")
                reply(out)
            }
        }
    }

    func remove(reminderId: String, eventId: String) {
        if let r = item(reminderId) as? EKReminder { try? store.remove(r, commit: true) }
        if let e = item(eventId) as? EKEvent { try? store.remove(e, span: .thisEvent, commit: true) }
    }

    /// The reminders among these identifiers that were checked off in the Reminders app.
    func completed(_ ids: [String]) -> [String] {
        ids.filter { (item($0) as? EKReminder)?.isCompleted == true }
    }

    private func item(_ id: String?) -> EKCalendarItem? {
        guard let id, !id.isEmpty else { return nil }
        return store.calendarItem(withIdentifier: id)
    }

    private func step(_ type: EKEntityType, want: Bool, id: String?, _ t: [String: Any], done: @escaping (String?, String?) -> Void) {
        guard want else {
            if type == .reminder { remove(reminderId: id ?? "", eventId: "") } else { remove(reminderId: "", eventId: id ?? "") }
            return done(nil, nil)
        }
        access(type) { ok in
            guard ok else {
                let app = type == .reminder ? "Reminders" : "Calendars"
                return done(id, "StudyWhitney can't reach \(app) yet. Turn it on in System Settings → Privacy & Security → \(app).")
            }
            do { done(try self.save(type, existing: self.item(id), t), nil) } catch { done(id, error.localizedDescription) }
        }
    }

    private func save(_ type: EKEntityType, existing: EKCalendarItem?, _ t: [String: Any]) throws -> String {
        let title = t["title"] as? String ?? "To-do", notes = t["notes"] as? String ?? ""
        let ymd = (t["due"] as? String ?? "").split(separator: "-").compactMap { Int($0) }
        let hm = (t["time"] as? String ?? "").split(separator: ":").compactMap { Int($0) }
        let cal = Calendar.current
        var at = DateComponents()
        if ymd.count == 3 { at.year = ymd[0]; at.month = ymd[1]; at.day = ymd[2] }
        if hm.count == 2 { at.hour = hm[0]; at.minute = hm[1] }

        if type == .reminder {
            let r = existing as? EKReminder ?? EKReminder(eventStore: store)
            if r.calendar == nil { r.calendar = store.defaultCalendarForNewReminders() }
            r.title = title; r.notes = notes
            r.isCompleted = t["done"] as? Bool ?? false
            r.dueDateComponents = ymd.count == 3 ? at : nil
            r.alarms?.forEach { r.removeAlarm($0) }
            if ymd.count == 3 {
                var ring = at; if hm.count != 2 { ring.hour = 9; ring.minute = 0 }  // date only: nudge at 9 that morning
                if let d = cal.date(from: ring) { r.addAlarm(EKAlarm(absoluteDate: d)) }
            }
            try store.save(r, commit: true)
            return r.calendarItemIdentifier
        }

        guard ymd.count == 3, let start = cal.date(from: at) else {
            throw NSError(domain: "StudyWhitney", code: 1, userInfo: [NSLocalizedDescriptionKey: "Add a due date to put it on your calendar."])
        }
        let e = existing as? EKEvent ?? EKEvent(eventStore: store)
        if e.calendar == nil { e.calendar = store.defaultCalendarForNewEvents }
        e.title = title; e.notes = notes
        e.isAllDay = hm.count != 2
        e.startDate = start
        e.endDate = e.isAllDay ? start : start.addingTimeInterval(3600)
        e.alarms?.forEach { e.removeAlarm($0) }
        if !e.isAllDay { e.addAlarm(EKAlarm(relativeOffset: -1800)) }
        try store.save(e, span: .thisEvent, commit: true)
        return e.calendarItemIdentifier
    }
}

/// Floating strip above the Dock. Transparent everywhere except Whitney and her bubble.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    var petPanel: PetPanel!
    var petWeb: WKWebView!
    var statusItem: NSStatusItem!
    var petMenuItem: NSMenuItem!
    var petStatusMenuItem: NSMenuItem!
    var hitRects: [NSRect] = []
    var dragging = false
    var mouseTimer: Timer?
    var printWindow: NSWindow?
    var printWeb: WKWebView?
    var petFloor: CGFloat = 0
    let apple = AppleSync()

    var petVisible: Bool {
        get { UserDefaults.standard.object(forKey: "petVisible") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "petVisible") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildMainWindow()
        buildPet()
        buildStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(placePet),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: main window

    func buildMainWindow() {
        let mainConfig = WKWebViewConfiguration()
        mainConfig.userContentController.add(self, name: "app")
        web = WKWebView(frame: .zero, configuration: mainConfig)
        web.uiDelegate = self
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "StudyWhitney"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        let z = UserDefaults.standard.double(forKey: "pageZoom"); if z > 0 { web.pageZoom = z }
        window.center()
        window.setFrameAutosaveName("StudyWhitneyMain")
        window.makeKeyAndOrderFront(nil)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // Closing the window hides it; Whitney keeps living on the desktop.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(nil)
        return true
    }

    @objc func showMain(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: desktop Whitney

    func buildPet() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "pet")
        petWeb = ClickThroughWebView(frame: .zero, configuration: config)
        petWeb.navigationDelegate = self
        petWeb.setValue(false, forKey: "drawsBackground")
        petWeb.underPageBackgroundColor = .clear

        petPanel = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        petPanel.isOpaque = false
        petPanel.backgroundColor = .clear
        petPanel.hasShadow = false
        petPanel.level = .floating
        petPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        petPanel.hidesOnDeactivate = false
        petPanel.isReleasedWhenClosed = false
        petPanel.ignoresMouseEvents = true
        petPanel.contentView = petWeb
        placePet()

        if let url = Bundle.main.url(forResource: "pet", withExtension: "html") {
            petWeb.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        if petVisible { petPanel.orderFrontRegardless() }

        // Clicks pass through to the apps underneath unless the pointer is over Whitney or her bubble.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateMousePassThrough()
        }
    }

    /// Whitney's window covers the whole screen (below the menu bar) so she can be dragged anywhere.
    /// Her default spot is on top of the Dock. With auto-hide on, that's the height the Dock slides up to.
    @objc func placePet() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.frame, vf = screen.visibleFrame
        var floor = vf.minY - sf.minY
        let dock = "com.apple.dock" as CFString
        let autohide = (CFPreferencesCopyAppValue("autohide" as CFString, dock) as? Bool) ?? false
        let orientation = (CFPreferencesCopyAppValue("orientation" as CFString, dock) as? String) ?? "bottom"
        if autohide && orientation == "bottom" && floor < 8 {
            let tile = (CFPreferencesCopyAppValue("tilesize" as CFString, dock) as? NSNumber)?.doubleValue ?? 48
            floor = CGFloat(tile) + 18
        }
        petFloor = floor
        petPanel.setFrame(NSRect(x: sf.minX, y: sf.minY, width: sf.width, height: vf.maxY - sf.minY), display: true)
        petWeb?.evaluateJavaScript("window.setFloor && window.setFloor(\(Int(floor)))", completionHandler: nil)
    }

    func updateMousePassThrough() {
        guard petPanel.isVisible else { return }
        let p = NSEvent.mouseLocation
        let f = petPanel.frame
        let local = NSPoint(x: p.x - f.minX, y: f.maxY - p.y)
        let hit = dragging || hitRects.contains { $0.contains(local) }
        if petPanel.ignoresMouseEvents == hit { petPanel.ignoresMouseEvents = !hit }
    }

    @objc func togglePet(_ sender: Any?) {
        petVisible.toggle()
        if petVisible { placePet(); petPanel.orderFrontRegardless() } else { petPanel.orderOut(nil) }
        petMenuItem.state = petVisible ? .on : .off
        petStatusMenuItem.state = petVisible ? .on : .off
        syncPetSwitch()
    }

    func syncPetSwitch() {
        web.evaluateJavaScript("window.__petVisible && window.__petVisible(\(petVisible))", completionHandler: nil)
    }

    func pushDataToPet() {
        web.evaluateJavaScript("window.__petData ? window.__petData() : null") { [weak self] result, _ in
            guard let json = result as? String else { return }
            self?.petWeb.evaluateJavaScript("window.petData && window.petData(\(json))", completionHandler: nil)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if message.name == "app" {
            switch type {
            case "togglePet": togglePet(nil)
            case "keyStatus": sendKeyStatus()
            case "setKey": KeyStore.set(body["key"] as? String ?? ""); sendKeyStatus()
            case "claude": callClaude(id: body["id"] as? String ?? "", body: body["body"] as? String ?? "{}")
            case "print": printHTML(body["html"] as? String ?? "")
            case "openHTML": openHTMLInBrowser(body["html"] as? String ?? "")
            case "todoSync": apple.sync(body) { [weak self] out in self?.callJS("__todoSynced", out) }
            case "todoRemove": apple.remove(reminderId: body["reminderId"] as? String ?? "", eventId: body["eventId"] as? String ?? "")
            default: break
            }
            return
        }
        switch type {
        case "rects":
            if let rects = body["rects"] as? [[Double]] {
                hitRects = rects.filter { $0.count == 4 }.map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            }
        case "drag":
            dragging = body["on"] as? Bool ?? false
        case "hide":
            if petVisible { togglePet(nil) }
        case "getData":
            pushDataToPet()
        case "open":
            showMain(nil)
            let payload: [String: String] = ["code": body["code"] as? String ?? "", "ask": body["ask"] as? String ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                web.evaluateJavaScript("window.__openFromPet && window.__openFromPet(\(json))", completionHandler: nil)
            }
        default: break
        }
    }

    func callJS(_ fn: String, _ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.\(fn) && window.\(fn)(\(json))", completionHandler: nil)
    }

    // Anything checked off in the Reminders app is checked off here too.
    func applicationDidBecomeActive(_ notification: Notification) {
        web?.evaluateJavaScript("window.__todoIds ? window.__todoIds() : '[]'") { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let ids = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String], !ids.isEmpty else { return }
            let done = self.apple.completed(ids)
            if !done.isEmpty { self.callJS("__todoDone", done) }
        }
    }

    // MARK: Claude (raw HTTP: there is no official Swift SDK)

    func sendKeyStatus() {
        web.evaluateJavaScript("window.__keyStatus && window.__keyStatus(\(KeyStore.get() != nil))", completionHandler: nil)
    }

    func callClaude(id: String, body: String) {
        let reply: (String) -> Void = { text in
            DispatchQueue.main.async {
                self.web.evaluateJavaScript("window.__claudeDone && window.__claudeDone(\(jsString(id)), \(jsString(text)))", completionHandler: nil)
            }
        }
        guard let key = KeyStore.get() else {
            reply(#"{"type":"error","error":{"type":"authentication_error","message":"No API key saved."}}"#); return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let data, let text = String(data: data, encoding: .utf8), !text.isEmpty { reply(text); return }
            let msg = (err?.localizedDescription ?? "No response from Claude.").replacingOccurrences(of: "\"", with: "'")
            reply(#"{"type":"error","error":{"type":"network_error","message":"\#(msg)"}}"#)
        }.resume()
    }

    // MARK: printing practice exams

    func printHTML(_ html: String) {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056))
        w.navigationDelegate = self
        let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 816, height: 1056), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = w
        win.isReleasedWhenClosed = false
        printWindow = win
        printWeb = w
        w.loadHTMLString(html, baseURL: URL(string: "https://studywhitney.local/"))
    }

    func runPrint(_ w: WKWebView) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        let op = w.printOperation(with: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.view?.frame = w.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func openHTMLInBrowser(_ html: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StudyWhitney", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("practice-exam.html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(file)
    }

    // MARK: menu bar icon

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSApp.applicationIconImage.copy() as? NSImage {
            icon.size = NSSize(width: 20, height: 20)
            statusItem.button?.image = icon
        }
        statusItem.button?.toolTip = "StudyWhitney"
        let menu = NSMenu()
        petStatusMenuItem = NSMenuItem(title: "Show Whitney on Desktop", action: #selector(togglePet(_:)), keyEquivalent: "")
        petStatusMenuItem.state = petVisible ? .on : .off
        menu.addItem(petStatusMenuItem)
        menu.addItem(withTitle: "Open StudyWhitney", action: #selector(showMain(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit StudyWhitney", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    // MARK: web view plumbing

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === web { syncPetSwitch(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pushDataToPet() } }
        if webView === printWeb {
            showMain(nil)
            // give the math typesetting a moment to finish before printing
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runPrint(webView) }
        }
        if webView === petWeb { petWeb.evaluateJavaScript("window.setFloor && window.setFloor(\(Int(petFloor)))", completionHandler: nil) }
    }

    // <input type="file"> needs a native open panel
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // Links to websites open in the default browser
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    @objc func reload(_ sender: Any?) { web.reload() }

    // Cmd+ / Cmd- / Cmd+0 make everything bigger or smaller, and the size is remembered
    func setZoom(_ z: Double) {
        web.pageZoom = min(3, max(0.5, (z * 10).rounded() / 10))
        UserDefaults.standard.set(web.pageZoom, forKey: "pageZoom")
    }
    @objc func zoomIn(_ sender: Any?) { setZoom(web.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(web.pageZoom - 0.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    // MARK: main menu

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About StudyWhitney", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        petMenuItem = NSMenuItem(title: "Show Whitney on Desktop", action: #selector(togglePet(_:)), keyEquivalent: "d")
        petMenuItem.keyEquivalentModifierMask = [.command, .shift]
        petMenuItem.state = petVisible ? .on : .off
        appMenu.addItem(petMenuItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide StudyWhitney", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit StudyWhitney", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        let plus = view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        plus.isHidden = true; plus.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "StudyWhitney", action: #selector(showMain(_:)), keyEquivalent: "1")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
