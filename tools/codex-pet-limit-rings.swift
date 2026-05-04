import AppKit
import Foundation
import SQLite3

struct LimitBucket {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }
}

struct LimitState {
    var planType: String?
    var primary: LimitBucket?
    var secondary: LimitBucket?
    var additional: [(name: String, bucket: LimitBucket)]
    var observedAt: Date
    var source: String

    static let empty = LimitState(planType: nil, primary: nil, secondary: nil, additional: [], observedAt: Date(), source: "none")
}

private let limitStatePollInterval: TimeInterval = 20.0
private let petFramePollInterval: TimeInterval = 0.12
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let lockedPanelFrameDefaultsKey = "CodexPetLimitRings.lockedPanelFrame"
private let centerDisplayModeDefaultsKey = "CodexPetLimitRings.centerDisplayMode"
private let ringPanelPadding: CGFloat = 38.0
private let ringOverlayScale: CGFloat = 0.70
private let ringUsageStartAngle: CGFloat = CGFloat.pi / 2.0
private let liveUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

enum CenterDisplayMode: String {
    case used
    case remaining

    var next: CenterDisplayMode {
        self == .used ? .remaining : .used
    }
}

private struct EventPayload: Decodable {
    var type: String
    var plan_type: String?
    var rate_limits: RatePayload?
    var additional_rate_limits: [String: RatePayload]?
}

private struct AuthPayload: Decodable {
    var tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    var access_token: String?
}

private struct UsagePayload: Decodable {
    var plan_type: String?
    var rate_limit: RatePayload?
    var additional_rate_limits: [AdditionalUsagePayload]?
}

private struct AdditionalUsagePayload: Decodable {
    var limit_name: String?
    var metered_feature: String?
    var rate_limit: RatePayload?
}

private struct RatePayload: Decodable {
    var primary: BucketPayload?
    var secondary: BucketPayload?
    var primary_window: BucketPayload?
    var secondary_window: BucketPayload?
}

private struct BucketPayload: Decodable {
    var used_percent: Double?
    var window_minutes: Double?
    var limit_window_seconds: Double?
    var reset_at: Double?

    func toBucket() -> LimitBucket? {
        guard let used = used_percent else { return nil }
        let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset_at)
    }
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var authPath: URL
    var previewPath: URL?
    var fallbackSize: CGFloat = 220
}

final class LimitStateReader {
    private let logsPath: URL
    private let authPath: URL

    init(logsPath: URL, authPath: URL) {
        self.logsPath = logsPath
        self.authPath = authPath
    }

    func readLatest() -> LimitState {
        if let liveState = readLiveUsage() {
            return liveState
        }
        return readLatestLog()
    }

    private func readLiveUsage() -> LimitState? {
        guard let token = readAccessToken() else {
            return nil
        }

        var request = URLRequest(url: liveUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            resultData = data
            resultResponse = response
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 7.0) == .success,
              let http = resultResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data = resultData,
              let payload = try? JSONDecoder().decode(UsagePayload.self, from: data) else {
            return nil
        }

        let primary = (payload.rate_limit?.primary ?? payload.rate_limit?.primary_window)?.toBucket()
        let secondary = (payload.rate_limit?.secondary ?? payload.rate_limit?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [])
            .compactMap { item -> (String, LimitBucket)? in
                guard let bucket = (item.rate_limit?.primary ?? item.rate_limit?.primary_window ?? item.rate_limit?.secondary ?? item.rate_limit?.secondary_window)?.toBucket() else {
                    return nil
                }
                return (item.limit_name ?? item.metered_feature ?? "Additional", bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: Date(), source: "live")
    }

    private func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: authPath),
              let payload = try? JSONDecoder().decode(AuthPayload.self, from: data),
              let token = payload.tokens?.access_token,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func readLatestLog() -> LimitState {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return .empty
        }

        let body = String(cString: cText)
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data) else {
            return .empty
        }

        let primary = (payload.rate_limits?.primary ?? payload.rate_limits?.primary_window)?.toBucket()
        let secondary = (payload.rate_limits?.secondary ?? payload.rate_limits?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [:])
            .compactMap { name, payload -> (String, LimitBucket)? in
                guard let bucket = (payload.primary ?? payload.primary_window ?? payload.secondary ?? payload.secondary_window)?.toBucket() else {
                    return nil
                }
                return (name, bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: Date(), source: "log")
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var endIndex: String.Index?
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = body.index(after: index)
                        break
                    }
                }
            }
            index = body.index(after: index)
        }

        guard let endIndex else { return nil }
        return String(body[start..<endIndex])
    }
}

final class PetFrameReader {
    private let globalStatePath: URL

    init(globalStatePath: URL) {
        self.globalStatePath = globalStatePath
    }

    func readPetFrameTopLeft() -> CGRect? {
        guard let data = try? Data(contentsOf: globalStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isAvatarOverlayOpen(root),
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = number(bounds["x"]),
              let y = number(bounds["y"]),
              let mascot = bounds["mascot"] as? [String: Any],
              let left = number(mascot["left"]),
              let top = number(mascot["top"]),
              let width = number(mascot["width"]),
              let height = number(mascot["height"]) else {
            return nil
        }

        return CGRect(x: x + left, y: y + top, width: width, height: height)
    }

    private func isAvatarOverlayOpen(_ root: [String: Any]) -> Bool {
        if let isOpen = root["electron-avatar-overlay-open"] as? Bool {
            return isOpen
        }
        if let isOpen = root["electron-avatar-overlay-open"] as? NSNumber {
            return isOpen.boolValue
        }
        return true
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }
}

struct LimitRingRenderer {
    var state: LimitState
    var phase: Double
    var showsReadout: Bool = false
    var centerDisplayMode: CenterDisplayMode = .used

    func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.clear(rect)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minSide = min(rect.width, rect.height)
        let urgency = max(urgency(for: state.primary), urgency(for: state.secondary))
        let breathe = CGFloat((sin(phase * 2.0 * .pi) + 1.0) * 0.5)
        let pulse = CGFloat(1.0 + urgency * 0.025 * breathe)
        let outerRadius = (minSide * 0.5 - 16.0) * pulse
        let innerRadius = outerRadius - 13.0

        if let primary = state.primary {
            drawRing(
                context,
                center: center,
                radius: outerRadius,
                lineWidth: 7.0,
                bucket: primary,
                color: color(forUsage: primary.usedPercent, role: .primary)
            )
        } else {
            drawMissingRing(context, center: center, radius: outerRadius, lineWidth: 7.0)
        }

        if let secondary = state.secondary {
            drawRing(
                context,
                center: center,
                radius: innerRadius,
                lineWidth: 4.5,
                bucket: secondary,
                color: color(forUsage: secondary.usedPercent, role: .secondary)
            )
        }

        if showsReadout {
            drawLimitReadouts(context, center: center, bounds: rect)
        }
        drawCenterUsage(context, center: center, minSide: minSide)
        context.restoreGState()
    }

    private enum RingRole {
        case primary
        case secondary
    }

    private struct LimitReadout {
        var text: String
        var labelRect: CGRect
        var color: NSColor
    }

    private func urgency(for bucket: LimitBucket?) -> Double {
        guard let bucket else { return 0.0 }
        return min(max((bucket.usedPercent - 55.0) / 45.0, 0.0), 1.0)
    }

    private func drawRing(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        bucket: LimitBucket,
        color: NSColor
    ) {
        let start = ringUsageStartAngle
        let usage = CGFloat(min(max(bucket.usedPercent, 0.0), 100.0) / 100.0)
        let visibleUsage = bucket.usedPercent <= 0.0 ? 0.0 : max(usage, 0.018)
        let end = start - visibleUsage * CGFloat.pi * 2.0

        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)

        if visibleUsage > 0.0 {
            context.setShadow(offset: .zero, blur: 11.0, color: color.withAlphaComponent(0.46).cgColor)
            context.setStrokeColor(color.withAlphaComponent(0.24).cgColor)
            context.setLineWidth(lineWidth + 7.0)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            context.strokePath()

            context.setShadow(offset: .zero, blur: 4.0, color: color.withAlphaComponent(0.56).cgColor)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            context.strokePath()
        }

        context.restoreGState()
    }

    private func drawMissingRing(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 1.74, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private enum ReadoutSlot {
        case lowerTop
        case lowerBottom
    }

    private func drawLimitReadouts(_ context: CGContext, center: CGPoint, bounds: CGRect) {
        if let primary = state.primary {
            drawReadout(context, readout: makeReadout(
                text: "5h \(formatResetCountdown(primary))",
                center: center,
                color: color(forUsage: primary.usedPercent, role: .primary),
                slot: .lowerTop,
                bounds: bounds
            ))
        }

        if let secondary = state.secondary {
            drawReadout(context, readout: makeReadout(
                text: "Weekly \(formatResetCountdown(secondary))",
                center: center,
                color: color(forUsage: secondary.usedPercent, role: .secondary),
                slot: .lowerBottom,
                bounds: bounds
            ))
        }
    }

    private func makeReadout(
        text: String,
        center: CGPoint,
        color: NSColor,
        slot: ReadoutSlot,
        bounds: CGRect
    ) -> LimitReadout {
        let inset: CGFloat = 4.0
        let labelGap: CGFloat = 3.0
        let labelHeight = max(16.0, min(18.5, bounds.height * 0.13))
        let labelWidth = min(bounds.width - inset * 2.0, max(58.0, CGFloat(text.count) * 5.9 + 14.0))
        let labelY: CGFloat
        switch slot {
        case .lowerTop:
            labelY = bounds.minY + inset + labelHeight + labelGap
        case .lowerBottom:
            labelY = bounds.minY + inset
        }
        let labelRect = CGRect(
            x: center.x - labelWidth / 2.0,
            y: labelY,
            width: labelWidth,
            height: labelHeight
        )
        return LimitReadout(text: text, labelRect: labelRect, color: color)
    }

    private func formatResetCountdown(_ bucket: LimitBucket) -> String {
        guard let resetAt = bucket.resetAt else {
            return bucket.windowMinutes.map { "~\(formatDuration($0 * 60.0))" } ?? "reset ?"
        }

        return formatDuration(resetAt - Date().timeIntervalSince1970)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let remaining = max(0, Int(seconds.rounded(.up)))
        if remaining == 0 {
            return "now"
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }

    private func drawReadout(_ context: CGContext, readout: LimitReadout) {
        context.saveGState()
        let path = CGPath(roundedRect: readout.labelRect, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
        context.setShadow(offset: .zero, blur: 8.0, color: readout.color.withAlphaComponent(0.22).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.055, alpha: 0.78).cgColor)
        context.addPath(path)
        context.fillPath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(8.5, min(10.0, readout.labelRect.height * 0.56)), weight: .bold),
            .foregroundColor: readout.color.withAlphaComponent(0.96)
        ]
        let attributed = NSAttributedString(string: readout.text, attributes: attrs)
        let textSize = attributed.size()
        attributed.draw(at: CGPoint(x: readout.labelRect.midX - textSize.width / 2, y: readout.labelRect.midY - textSize.height / 2 + 0.5))
        context.restoreGState()
    }

    private func drawCenterUsage(_ context: CGContext, center: CGPoint, minSide: CGFloat) {
        guard state.primary != nil || state.secondary != nil else { return }

        context.saveGState()
        drawCenterBackdrop(context, center: center, minSide: minSide)
        context.setShadow(offset: .zero, blur: 10.0, color: NSColor(calibratedWhite: 0.0, alpha: 0.74).cgColor)

        if let primary = state.primary {
            let color = color(forUsage: primary.usedPercent, role: .primary)
            drawCenteredText(
                centerDisplayMode == .used ? "5h used" : "5h left",
                center: CGPoint(x: center.x, y: center.y + minSide * 0.112),
                font: NSFont.monospacedSystemFont(ofSize: max(6.5, minSide * 0.048), weight: .bold),
                color: color.withAlphaComponent(0.86)
            )
            drawCenteredText(
                formatPercent(centerValue(for: primary)),
                center: CGPoint(x: center.x, y: center.y + minSide * 0.015),
                font: NSFont.monospacedSystemFont(ofSize: max(16.0, minSide * 0.162), weight: .heavy),
                color: color
            )
        }

        if let secondary = state.secondary {
            let color = color(forUsage: secondary.usedPercent, role: .secondary)
            drawCenteredText(
                centerDisplayMode == .used ? "Wk used \(formatPercent(secondary.usedPercent))" : "Wk left \(formatPercent(secondary.remainingPercent))",
                center: CGPoint(x: center.x, y: center.y - minSide * 0.138),
                font: NSFont.monospacedSystemFont(ofSize: max(7.2, minSide * 0.052), weight: .bold),
                color: color.withAlphaComponent(0.92)
            )
        }

        context.restoreGState()
    }

    private func drawCenterBackdrop(_ context: CGContext, center: CGPoint, minSide: CGFloat) {
        let size = CGSize(width: minSide * 0.48, height: minSide * 0.37)
        let rect = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2 - minSide * 0.012,
            width: size.width,
            height: size.height
        )
        let path = CGPath(roundedRect: rect, cornerWidth: minSide * 0.07, cornerHeight: minSide * 0.07, transform: nil)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 12.0, color: NSColor(calibratedWhite: 0.0, alpha: 0.36).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.02, alpha: 0.40).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private func centerValue(for bucket: LimitBucket) -> Double {
        centerDisplayMode == .used ? bucket.usedPercent : bucket.remainingPercent
    }

    private func drawCenteredText(_ text: String, center: CGPoint, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: -0.35
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func color(forUsage usage: Double, role: RingRole) -> NSColor {
        if usage >= 88 {
            return NSColor(calibratedRed: 1.00, green: 0.24, blue: 0.22, alpha: 0.98)
        }
        if usage >= 70 {
            return NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.18, alpha: 0.98)
        }
        if usage >= 45 {
            return NSColor(calibratedRed: 0.93, green: 0.82, blue: 0.28, alpha: 0.96)
        }
        if role == .secondary {
            return NSColor(calibratedRed: 0.42, green: 0.72, blue: 1.00, alpha: 0.94)
        }
        return NSColor(calibratedRed: 0.24, green: 0.94, blue: 0.78, alpha: 0.98)
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }
}

final class LimitRingView: NSView {
    var state: LimitState = .empty {
        didSet { needsDisplay = true }
    }
    var phase: Double = 0 {
        didSet { needsDisplay = true }
    }
    var showsReadout: Bool = false {
        didSet { needsDisplay = true }
    }
    var centerDisplayMode: CenterDisplayMode = .used {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(
            state: state,
            phase: phase,
            showsReadout: showsReadout,
            centerDisplayMode: centerDisplayMode
        ).draw(in: bounds)
    }
}

final class LimitRingsApp: NSObject {
    private let config: LimitRingsConfig
    private let stateReader: LimitStateReader
    private let frameReader: PetFrameReader
    private let panel: NSPanel
    private let ringView: LimitRingView
    private let stateQueue = DispatchQueue(label: "codex-pet-limit-rings.state-reader")
    private var statusItem: NSStatusItem?
    private var summaryItem: NSMenuItem?
    private var showRingsItem: NSMenuItem?
    private var stateTimer: Timer?
    private var frameTimer: Timer?
    private var animationTimer: Timer?
    private var hoverTimer: Timer?
    private var resetPositionItem: NSMenuItem?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var centerClickStart: CGPoint?
    private var startTime = Date()
    private var currentPetFrameAppKit: CGRect?
    private var dragCenterOffset: CGPoint?
    private var holdDraggedFrameUntil: Date?
    private var lockedPanelFrame: CGRect?
    private var centerDisplayMode: CenterDisplayMode
    private var ringsVisible: Bool
    private var stateReadInFlight = false

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath)
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.lockedPanelFrame = Self.loadLockedPanelFrame()
        self.centerDisplayMode = Self.loadCenterDisplayMode()
        self.ringView.centerDisplayMode = self.centerDisplayMode
        self.panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = ringView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        super.init()
    }

    func run() {
        installStatusMenu()
        updateState()
        updateFrame()
        updateRingVisibility()

        stateTimer = Timer.scheduledTimer(withTimeInterval: limitStatePollInterval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
        frameTimer = Timer.scheduledTimer(withTimeInterval: petFramePollInterval, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateTooltip(at: NSEvent.mouseLocation)
        }
        installDragFollow()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ringView.phase = Date().timeIntervalSince(self.startTime) / 4.6
        }
    }

    private func updateState() {
        guard !stateReadInFlight else { return }
        stateReadInFlight = true
        stateQueue.async { [weak self] in
            guard let self else { return }
            let state = self.stateReader.readLatest()
            DispatchQueue.main.async {
                self.ringView.state = state
                self.updateSummaryMenuItem()
                self.stateReadInFlight = false
            }
        }
    }

    private func updateFrame() {
        if dragCenterOffset != nil {
            return
        }
        if let holdDraggedFrameUntil, Date() < holdDraggedFrameUntil {
            return
        }
        holdDraggedFrameUntil = nil

        if let lockedPanelFrame {
            applyLockedPanelFrame(lockedPanelFrame)
            return
        }

        guard let petFrame = frameReader.readPetFrameTopLeft() else {
            currentPetFrameAppKit = nil
            dragCenterOffset = nil
            ringView.showsReadout = false
            panel.orderOut(nil)
            return
        }

        currentPetFrameAppKit = appKitRectFromTopLeft(petFrame)
        panel.setFrame(panelFrame(forPetFrameTopLeft: petFrame), display: true)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
        updateResetPositionMenuItem()
    }

    private func panelFrame(forPetFrameTopLeft petFrame: CGRect) -> CGRect {
        let size = (max(petFrame.width, petFrame.height) + ringPanelPadding * 2) * ringOverlayScale
        let topLeft = CGPoint(x: petFrame.midX - size / 2, y: petFrame.midY - size / 2)
        let origin = appKitOriginFromTopLeft(topLeft, size: CGSize(width: size, height: size))

        return CGRect(origin: origin, size: CGSize(width: size, height: size))
    }

    private func applyLockedPanelFrame(_ frame: CGRect) {
        panel.setFrame(frame, display: true)
        currentPetFrameAppKit = inferredPetFrame(fromPanelFrame: frame)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
        updateResetPositionMenuItem()
    }

    private func inferredPetFrame(fromPanelFrame frame: CGRect) -> CGRect {
        let inset = min(ringPanelPadding * ringOverlayScale, max(0, min(frame.width, frame.height) / 2 - 1))
        return frame.insetBy(dx: inset, dy: inset)
    }

    private static func loadLockedPanelFrame() -> CGRect? {
        guard let raw = UserDefaults.standard.string(forKey: lockedPanelFrameDefaultsKey) else {
            return nil
        }
        let frame = NSRectFromString(raw)
        guard frame.width >= 40, frame.height >= 40 else {
            return nil
        }
        return frame
    }

    private static func loadCenterDisplayMode() -> CenterDisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: centerDisplayModeDefaultsKey),
              let mode = CenterDisplayMode(rawValue: raw) else {
            return .used
        }
        return mode
    }

    private func setCenterDisplayMode(_ mode: CenterDisplayMode) {
        centerDisplayMode = mode
        ringView.centerDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: centerDisplayModeDefaultsKey)
        updateSummaryMenuItem()
    }

    private func saveLockedPanelFrame(_ frame: CGRect) {
        lockedPanelFrame = frame
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: lockedPanelFrameDefaultsKey)
        updateResetPositionMenuItem()
    }

    private func clearLockedPanelFrame() {
        lockedPanelFrame = nil
        UserDefaults.standard.removeObject(forKey: lockedPanelFrameDefaultsKey)
        updateResetPositionMenuItem()
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Codex Pet Limit Rings"
        }

        let menu = NSMenu()
        let summary = NSMenuItem(title: "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Rings", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let resetItem = NSMenuItem(title: "Reset Ring Position", action: #selector(resetRingPosition(_:)), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        resetPositionItem = resetItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
        updateResetPositionMenuItem()
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        let outer = NSBezierPath()
        outer.appendArc(
            withCenter: NSPoint(x: 9, y: 9),
            radius: 6.7,
            startAngle: 22,
            endAngle: 338,
            clockwise: false
        )
        outer.lineWidth = 2.0
        outer.lineCapStyle = .round
        outer.stroke()

        let inner = NSBezierPath()
        inner.appendArc(
            withCenter: NSPoint(x: 9, y: 9),
            radius: 3.6,
            startAngle: 210,
            endAngle: 82,
            clockwise: false
        )
        inner.lineWidth = 1.6
        inner.lineCapStyle = .round
        inner.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func updateSummaryMenuItem() {
        guard let summaryItem else { return }
        let primary = ringView.state.primary.map { "5h used \(formatPercent($0.usedPercent))" }
        let secondary = ringView.state.secondary.map { "Weekly used \(formatPercent($0.usedPercent))" }
        let pieces = [primary, secondary].compactMap { $0 }
        if pieces.isEmpty {
            summaryItem.title = "Waiting for Codex limit data"
        } else {
            let source = ringView.state.source == "live" ? "Live" : "Cached"
            summaryItem.title = "\(source) " + pieces.joined(separator: " | ")
        }
    }

    private func updateShowRingsMenuItem() {
        showRingsItem?.state = ringsVisible ? .on : .off
    }

    private func updateResetPositionMenuItem() {
        resetPositionItem?.isEnabled = lockedPanelFrame != nil
    }

    private func updateRingVisibility() {
        updateShowRingsMenuItem()
        if ringsVisible, currentPetFrameAppKit != nil {
            panel.orderFrontRegardless()
            updateTooltip(at: NSEvent.mouseLocation)
        } else {
            ringView.showsReadout = false
            panel.orderOut(nil)
        }
    }

    private func setRingsVisible(_ visible: Bool) {
        ringsVisible = visible
        UserDefaults.standard.set(visible, forKey: ringsVisibleDefaultsKey)
        updateRingVisibility()
    }

    @objc private func toggleRings(_ sender: NSMenuItem) {
        setRingsVisible(!ringsVisible)
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        updateState()
        updateFrame()
        updateRingVisibility()
    }

    @objc private func resetRingPosition(_ sender: NSMenuItem) {
        clearLockedPanelFrame()
        updateFrame()
        updateRingVisibility()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func installDragFollow() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleMouseDown(at: NSEvent.mouseLocation)
            }
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleMouseDrag(at: NSEvent.mouseLocation)
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleMouseUp(at: NSEvent.mouseLocation)
            }
        }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTooltip(at: NSEvent.mouseLocation)
            }
        }
    }

    private func handleMouseDown(at mouse: CGPoint) {
        guard ringsVisible else { return }
        if isCenterToggleHit(mouse) {
            centerClickStart = mouse
            return
        }
        beginDragFollowIfNeeded(at: mouse)
    }

    private func handleMouseDrag(at mouse: CGPoint) {
        if let start = centerClickStart {
            if distanceSquared(mouse, to: start) > 36.0 {
                centerClickStart = nil
                beginDragFollowIfNeeded(at: mouse)
            } else {
                return
            }
        }
        continueDragFollow(at: mouse)
    }

    private func handleMouseUp(at mouse: CGPoint) {
        if centerClickStart != nil {
            defer { centerClickStart = nil }
            if isCenterToggleHit(mouse) {
                setCenterDisplayMode(centerDisplayMode.next)
            }
            return
        }
        endDragFollow()
    }

    private func beginDragFollowIfNeeded(at mouse: CGPoint) {
        guard ringsVisible else { return }
        updateFrame()
        guard let currentPetFrameAppKit else { return }
        let hitTarget = currentPetFrameAppKit.insetBy(dx: -24, dy: -24)
        guard hitTarget.contains(mouse) else { return }

        dragCenterOffset = CGPoint(x: panel.frame.midX - mouse.x, y: panel.frame.midY - mouse.y)
        holdDraggedFrameUntil = nil
    }

    private func continueDragFollow(at mouse: CGPoint) {
        guard let offset = dragCenterOffset else { return }
        let size = panel.frame.size
        let center = CGPoint(x: mouse.x + offset.x, y: mouse.y + offset.y)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let newFrame = CGRect(origin: origin, size: size)
        panel.setFrame(newFrame, display: true)
        currentPetFrameAppKit = inferredPetFrame(fromPanelFrame: newFrame)
        ringView.showsReadout = false
    }

    private func endDragFollow() {
        guard dragCenterOffset != nil else { return }
        dragCenterOffset = nil
        holdDraggedFrameUntil = nil
        saveLockedPanelFrame(panel.frame)
        currentPetFrameAppKit = inferredPetFrame(fromPanelFrame: panel.frame)
    }

    private func updateTooltip(at mouse: CGPoint) {
        if !ringsVisible || currentPetFrameAppKit == nil || dragCenterOffset != nil {
            ringView.showsReadout = false
            return
        }

        ringView.showsReadout = isHoveringRingOrPet(mouse)
    }

    private func isCenterToggleHit(_ mouse: CGPoint) -> Bool {
        guard ringsVisible, currentPetFrameAppKit != nil else { return false }
        let frame = panel.frame
        guard frame.contains(mouse) else { return false }
        let minSide = min(frame.width, frame.height)
        let hitSize = CGSize(width: minSide * 0.64, height: minSide * 0.50)
        let hitRect = CGRect(
            x: frame.midX - hitSize.width / 2,
            y: frame.midY - hitSize.height / 2 - minSide * 0.012,
            width: hitSize.width,
            height: hitSize.height
        )
        return hitRect.contains(mouse)
    }

    private func isHoveringRingOrPet(_ mouse: CGPoint) -> Bool {
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -10, dy: -10).contains(mouse) {
            return true
        }

        let frame = panel.frame
        guard frame.insetBy(dx: -4, dy: -4).contains(mouse) else {
            return false
        }

        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let distance = hypot(local.x - center.x, local.y - center.y)
        let radius = min(frame.width, frame.height) * 0.5 - 16.0
        return distance >= radius - 24.0 && distance <= radius + 19.0
    }

    private func appKitOriginFromTopLeft(_ topLeft: CGPoint, size: CGSize) -> CGPoint {
        let topLeftRect = CGRect(origin: topLeft, size: size)
        guard let screen = screenForTopLeftRect(topLeftRect) else {
            return CGPoint(x: topLeft.x, y: max(0, config.fallbackSize - topLeft.y))
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = topLeft.x - screenTopLeftFrame.minX
        let localY = topLeft.y - screenTopLeftFrame.minY
        return CGPoint(x: screen.frame.minX + localX, y: screen.frame.maxY - localY - size.height)
    }

    private func appKitRectFromTopLeft(_ rect: CGRect) -> CGRect {
        guard let screen = screenForTopLeftRect(rect) else {
            return rect
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = rect.minX - screenTopLeftFrame.minX
        let localY = rect.minY - screenTopLeftFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func screenForTopLeftRect(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { topLeftFrame(for: $0).contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: topLeftFrame(for: $0)) < distanceSquared(center, to: topLeftFrame(for: $1))
        }
    }

    private func topLeftFrame(for screen: NSScreen) -> CGRect {
        let primaryMaxY = (primaryScreen() ?? NSScreen.screens.first)?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func distanceSquared(_ lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }
}

func renderPreview(config: LimitRingsConfig) -> Bool {
    let state = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath).readLatest()
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    LimitRingRenderer(state: state, phase: 0.18, showsReadout: true).draw(in: CGRect(origin: .zero, size: size))
    image.unlockFocus()

    guard let previewPath = config.previewPath,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try FileManager.default.createDirectory(at: previewPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: previewPath)
        return true
    } catch {
        fputs("codex-pet-limit-rings: could not write preview: \(error)\n", stderr)
        return false
    }
}

func parseConfig() -> LimitRingsConfig? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
    var config = LimitRingsConfig(
        codexHome: codexHome,
        globalStatePath: codexHome.appendingPathComponent(".codex-global-state.json"),
        logsPath: defaultLogsPath(codexHome: codexHome),
        authPath: codexHome.appendingPathComponent("auth.json"),
        previewPath: nil
    )

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: codex-pet-limit-rings [--preview PATH] [--codex-home PATH] [--logs PATH] [--auth PATH] [--state PATH]

            Draws a transparent Codex rate-limit rings around the current pet.
            """)
            exit(0)
        case "--preview":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.previewPath = URL(fileURLWithPath: value)
        case "--codex-home":
            guard let value = args.first else { return nil }
            args.removeFirst()
            let url = URL(fileURLWithPath: value)
            config.codexHome = url
            config.globalStatePath = url.appendingPathComponent(".codex-global-state.json")
            config.logsPath = defaultLogsPath(codexHome: url)
            config.authPath = url.appendingPathComponent("auth.json")
        case "--logs":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.logsPath = URL(fileURLWithPath: value)
        case "--auth":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.authPath = URL(fileURLWithPath: value)
        case "--state":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.globalStatePath = URL(fileURLWithPath: value)
        case "--size":
            guard let value = args.first, let size = Double(value) else { return nil }
            args.removeFirst()
            config.fallbackSize = CGFloat(size)
        default:
            fputs("codex-pet-limit-rings: unknown argument \(arg)\n", stderr)
            return nil
        }
    }

    return config
}

func defaultLogsPath(codexHome: URL) -> URL {
    let logs2 = codexHome.appendingPathComponent("logs_2.sqlite")
    if FileManager.default.fileExists(atPath: logs2.path) {
        return logs2
    }
    return codexHome.appendingPathComponent("logs_1.sqlite")
}

guard let config = parseConfig() else {
    fputs("codex-pet-limit-rings: invalid arguments. Use --help.\n", stderr)
    exit(2)
}

if config.previewPath != nil {
    exit(renderPreview(config: config) ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rings = LimitRingsApp(config: config)
rings.run()
app.run()
