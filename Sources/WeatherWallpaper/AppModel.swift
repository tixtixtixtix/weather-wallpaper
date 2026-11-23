import AppKit
import Combine
import OSLog
import ServiceManagement
import MediaAccessibility
import WeatherCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var preferences: Preferences
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var isFetching = false
    @Published private(set) var weatherIssue: WeatherFailure?
    @Published private(set) var cacheWarning: String?
    @Published private(set) var rendererError: String?
    @Published private(set) var isLowPower = false
    @Published private(set) var isOnBattery = false
    @Published private(set) var isReduceMotion = false
    @Published private(set) var powerDescription = "Ready"
    @Published private(set) var wallpaperActive = false
    @Published private(set) var displayCount = NSScreen.screens.count
    @Published private(set) var now = Date()
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var generalError: String?
    @Published var previewKind: WeatherKind? {
        didSet {
            if let genus = previewCloudGenus,
               !CloudGenus.eligiblePreviews(for: previewKind ?? .clear).contains(genus) || previewKind == nil {
                previewCloudGenus = nil
            }
            if let development = previewCloudDevelopment,
               previewKind == nil || !CloudDevelopment.eligiblePreviews(for: previewKind ?? .clear).contains(development) {
                previewCloudDevelopment = nil
            }
            updateScenes()
        }
    }
    @Published var previewTime = PreviewTime.day { didSet { updateScenes() } }
    @Published var previewMoonPhase = PreviewMoonPhase.waxingGibbous { didSet { updateScenes() } }
    @Published var previewCloudGenus: CloudGenus? {
        didSet {
            if previewCloudGenus != nil { previewCloudDevelopment = nil }
            updateScenes()
        }
    }
    @Published var previewCloudDevelopment: CloudDevelopment? {
        didSet {
            if previewCloudDevelopment != nil { previewCloudGenus = nil }
            updateScenes()
        }
    }
    @Published var cloudCoverageBias: Double { didSet { saveTuning() } }
    @Published var cloudShade: Double { didSet { saveTuning() } }
    @Published var highCloudBias: Double { didSet { saveTuning() } }
    @Published var previewMeteors = false { didSet { savePreviewEffects() } }
    @Published var meteorSpeed: Double = 1 { didSet { saveMeteorSpeed() } }
    @Published var showsWidgetGuide = false { didSet { updatePolicy() } }
    var widgetRainAreas: [WidgetRainArea] { preferences.resolvedWidgetRainAreas }
    var notchHaze: NotchHazeConfiguration { (preferences.notchHaze ?? NotchHazeConfiguration()).sanitized }

    func setNotchHaze(_ configuration: NotchHazeConfiguration) {
        preferences.notchHaze = configuration.sanitized
        save()
        updatePolicy()
    }

    func setWidgetRainAreas(_ areas: [WidgetRainArea]) {
        preferences.widgetRainAreas = Array(areas.prefix(WidgetRainArea.maximumCount)).map(\.sanitized)
        save()
        updatePolicy()
    }

    let previewEnvironment: SceneEnvironment
    let desktopEnvironment: SceneEnvironment
    var showMainWindow: (() -> Void)?
    private let weatherClient = WeatherClient()
    private let logger = Logger(subsystem: "com.weatherwallpaper.mac", category: "App")
    private lazy var powerMonitor = PowerMonitor { [weak self] in self?.updatePolicy() }
    private lazy var desktop = DesktopController(environment: desktopEnvironment) { [weak self] error in
        self?.rendererError = error.localizedDescription
    }
    private var heartbeat: Task<Void, Never>?
    private var weatherTask: Task<Void, Never>?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var nextRefresh = Date.distantPast
    private var failures = 0
    private var systemSleeping = false
    private var displaysSleeping = false
    private var sleeping: Bool { systemSleeping || displaysSleeping }
    private var sessionInactive = false
    private var started = false

    init() {
        let saved = Persistence.loadPreferences()
        preferences = saved
        cloudCoverageBias = Double(saved.cloudCoverageBias ?? 0)
        cloudShade = Double(saved.cloudShade ?? 0.5)
        highCloudBias = Double(saved.highCloudBias ?? 0)
        previewMeteors = saved.previewMeteors ?? false
        meteorSpeed = Double(saved.meteorSpeed ?? 1)
        snapshot = Persistence.loadSnapshot(for: saved.city)
        let initial = SceneState.preview(kind: .partlyCloudy, time: .day)
        previewEnvironment = SceneEnvironment(scene: initial,renderLabel: "Weather preview")
        desktopEnvironment = SceneEnvironment(scene: initial,renderLabel: "Desktop wallpaper")
        if let snapshot {
            previewKind = nil
            nextRefresh = snapshot.effectiveProvider == .openMeteo ? RefreshPolicy.nextRefresh(after: snapshot) : .distantPast
        }
    }

    var isLivePreview: Bool { previewKind == nil }
    var weatherError: String? { weatherIssue?.errorDescription }
    var diagnosticText: String {
        "Provider: Open-Meteo\nEndpoint: api.open-meteo.com\nAuthentication: none required\n"
            + "Data: model-derived current conditions, refreshed every 15 minutes\n\n"
            + (weatherIssue?.diagnostics ?? "No weather error recorded.")
    }
    var city: City? { preferences.city }
    var canApplyLive: Bool { snapshot != nil && city != nil }
    var isStale: Bool { snapshot?.isStale(at: now) ?? false }
    var isPreviewWallpaper: Bool { wallpaperActive && preferences.wallpaperSource == .preview }
    var upcomingHours: [HourlyOutlook] { snapshot?.hourly.filter { $0.date > now } ?? [] }

    func start() {
        guard !started else { return }
        started = true
        observeLifecycle()
        powerMonitor.start()
        updatePolicy()
        updateScenes(immediate: true)
        syncDesktop()
        startHeartbeat()
    }

    func stop() {
        heartbeat?.cancel()
        weatherTask?.cancel()
        powerMonitor.stop()
        desktop.stop()
        for (center, token) in observations { center.removeObserver(token) }
        observations = []
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(kMADimFlashingLightsChangedNotification), nil)
    }

    func selectCity(_ city: City) {
        weatherTask?.cancel()
        weatherTask = nil
        isFetching = false
        preferences.city = city
        snapshot = Persistence.loadSnapshot(for: city)
        previewKind = nil
        weatherIssue = nil
        failures = 0
        nextRefresh = .distantPast
        save()
        updateScenes()
        syncDesktop()
        startHeartbeat()
        refresh()
    }

    func refresh() {
        guard let city, weatherTask == nil, !sleeping, !sessionInactive else { return }
        isFetching = true
        weatherIssue = nil
        weatherTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.weatherClient.fetch(for: city)
                try Task.checkCancellation()
                guard self.city?.id == city.id else { return }
                self.snapshot = value
                self.now = Date()
                self.failures = 0
                self.nextRefresh = RefreshPolicy.nextRefresh(after: value)
                self.cacheWarning = nil
                do { try Persistence.save(value) } catch {
                    self.logger.error("Weather cache write failed: \(error.localizedDescription, privacy: .public)")
                    self.cacheWarning = "Weather is live, but its offline cache couldn't be saved."
                }
                self.updateScenes()
                self.syncDesktop()
            } catch {
                guard !Task.isCancelled else { return }
                self.failures += 1
                self.nextRefresh = Date().addingTimeInterval(RefreshPolicy.retryDelay(failureCount: self.failures))
                self.weatherIssue = WeatherFailure(error: error)
                if self.weatherIssue == .http(429) { self.nextRefresh = Date().addingTimeInterval(30 * 60) }
                self.logger.error("Open-Meteo: \(error.localizedDescription, privacy: .public)")
            }
            self.isFetching = false
            self.weatherTask = nil
        }
    }

    func applyWallpaper() {
        if let kind = previewKind {
            preferences.wallpaperSource = .preview
            preferences.appliedKind = kind
            preferences.appliedTime = previewTime
            preferences.appliedMoonPhase = previewMoonPhase
            preferences.appliedCloudGenus = previewCloudGenus
            preferences.appliedCloudDevelopment = previewCloudDevelopment
        } else {
            guard canApplyLive else { return }
            preferences.wallpaperSource = .live
        }
        preferences.wallpaperEnabled = true
        rendererError = nil
        save()
        updateScenes()
        syncDesktop()
    }

    func removeWallpaper() {
        preferences.wallpaperEnabled = false
        save()
        syncDesktop()
    }

    func resumeWallpaper() {
        preferences.wallpaperEnabled = true
        save()
        updateScenes()
        syncDesktop()
        if !canApplyLive && preferences.wallpaperSource == .live { refresh() }
    }

    func setAnimations(_ enabled: Bool) {
        preferences.animationsEnabled = enabled
        save()
        updatePolicy()
    }

    func setEfficientRendering(_ enabled: Bool) {
        preferences.efficientRendering = enabled
        save()
        updatePolicy()
    }

    func setLightning(_ enabled: Bool) {
        preferences.lightningEnabled = enabled
        save()
        updatePolicy()
    }

    func setBloom(_ enabled: Bool) {
        preferences.bloomEnabled = enabled
        save()
        updatePolicy()
    }

    func setMeteors(_ enabled: Bool) {
        preferences.meteorsEnabled = enabled
        save()
        updatePolicy()
    }

    func setLoginEnabled(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                loginEnabled = SMAppService.mainApp.status == .enabled
                if enabled && !loginEnabled {
                    generalError = "Allow Weather Wallpaper in System Settings → General → Login Items."
                }
            } catch { generalError = "Couldn't update the login setting: \(error.localizedDescription)" }
        }
    }

    func reportRendererError(_ error: Error) {
        rendererError = error.localizedDescription
    }

    private func save() { Persistence.save(preferences) }

    private func saveTuning() {
        preferences.cloudCoverageBias = Float(cloudCoverageBias)
        preferences.cloudShade = Float(cloudShade)
        preferences.highCloudBias = Float(highCloudBias)
        save()
        updateScenes()
    }

    private func applyCloudTuning(to scene: inout SceneState) {
        scene.cloud = max(0, min(1, scene.cloud + Float(cloudCoverageBias)))
        guard var presentation = scene.cloudPresentation else { return }
        presentation.density = max(18, min(48, presentation.density * Float(0.7 + 0.6 * cloudShade)))
        presentation.erosion = max(0.008, min(0.09, presentation.erosion * Float(1.25 - 0.5 * cloudShade)))
        presentation.highFraction = max(0, min(1, presentation.highFraction + Float(highCloudBias) * 0.5))
        scene.cloudPresentation = presentation
    }

    private func savePreviewEffects() {
        preferences.previewMeteors = previewMeteors
        save()
        updateScenes()
    }

    private func saveMeteorSpeed() {
        preferences.meteorSpeed = Float(max(0.25, min(2.5, meteorSpeed)))
        save()
        updatePolicy()
    }

    /// Preview-only meteor demo. Live weather never passes through here.
    private func applyPreviewEffects(to scene: inout SceneState) {
        if previewMeteors {
            scene.solar = SolarState.preview(.night, phase: previewMoonPhase)
            if scene.cloud > 0.25 { scene.cloud = 0.12 }
            scene.cloudPresentation?.convection = .zero
        }
    }

    private func updateScenes(immediate: Bool = false) {
        let date = Date()
        var live: SceneState
        if let snapshot, let city {
            live = .live(snapshot: snapshot, city: city, at: date)
        } else {
            live = .preview(kind: .partlyCloudy, time: .day)
            if let city { live.solar = SolarCalculator.state(at: date, latitude: city.latitude, longitude: city.longitude) }
        }
        // Cloud tuning is a preview-look tool only. Live scenes use weather data directly.
        let uptime = ProcessInfo.processInfo.systemUptime
        if let city {
            let next = SolarCalculator.state(at: date.addingTimeInterval(120), latitude: city.latitude, longitude: city.longitude)
            if isLivePreview { previewEnvironment.setSolarMotion(from: live.solar, to: next, at: uptime) }
            else { previewEnvironment.clearSolarMotion() }
            if preferences.wallpaperSource == .live { desktopEnvironment.setSolarMotion(from: live.solar, to: next, at: uptime) }
            else { desktopEnvironment.clearSolarMotion() }
        } else {
            previewEnvironment.clearSolarMotion()
            desktopEnvironment.clearSolarMotion()
        }
        previewEnvironment.setScene(previewKind.map {
            var scene = SceneState.preview(kind: $0, time: previewTime, moonPhase: previewMoonPhase,
                                           cloudGenus: previewCloudGenus, cloudDevelopment: previewCloudDevelopment)
            applyCloudTuning(to: &scene)
            applyPreviewEffects(to: &scene)
            return scene
        } ?? live,
                                    immediate: immediate)
        var applied = preferences.wallpaperSource == .live ? live
            : SceneState.preview(kind: preferences.appliedKind, time: preferences.appliedTime,
                                 moonPhase: preferences.appliedMoonPhase ?? .waxingGibbous, cloudGenus: preferences.appliedCloudGenus,
                                 cloudDevelopment: preferences.appliedCloudDevelopment)
        if preferences.wallpaperSource != .live {
            applyCloudTuning(to: &applied)
            if preferences.previewMeteors ?? false {
                applied.solar = SolarState.preview(.night, phase: preferences.appliedMoonPhase ?? .waxingGibbous)
                if applied.cloud > 0.25 { applied.cloud = 0.12 }
                applied.cloudPresentation?.convection = .zero
            }
        }
        desktopEnvironment.setScene(applied, immediate: immediate)
    }

    private func syncDesktop() {
        let hasSource = preferences.wallpaperSource == .preview || canApplyLive
        if preferences.wallpaperEnabled && hasSource {
            desktop.start()
            wallpaperActive = desktop.isRunning
        } else {
            desktop.stop()
            wallpaperActive = false
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        guard city != nil, !sleeping, !sessionInactive else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                self.updateScenes()
                if self.now >= self.nextRefresh { self.refresh() }
                do { try await Task.sleep(for: .seconds(60), tolerance: .seconds(10)) } catch { return }
            }
        }
    }

    private func updatePolicy() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        isOnBattery = PowerMonitor.isOnBattery
        isReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let thermal = ProcessInfo.processInfo.thermalState
        let efficient = preferences.efficientRendering || isOnBattery || isLowPower || thermal == .serious || thermal == .critical
        var policy = RenderPolicy()
        policy.framesPerSecond = efficient ? 15 : 30
        // Bound total fragment work as displays are attached, not just per-display resolution.
        policy.maximumDimension = (efficient ? 1600 : 2560) / sqrt(CGFloat(max(1, NSScreen.screens.count)))
        policy.particleScale = efficient ? 0.5 : 1
        policy.animated = preferences.animationsEnabled && !isReduceMotion && thermal != .critical
        policy.suspended = sleeping || sessionInactive
        policy.permitsLightning = !isReduceMotion && !MADimFlashingLightsEnabled() && !efficient
            && (preferences.lightningEnabled ?? true)
        policy.bloom = preferences.bloomEnabled ?? true
        policy.bloomDownsample = efficient ? 8 : 4
        policy.cloudDownsample = efficient ? 4 : 2
        policy.cloudSteps = efficient ? 20 : 48
        policy.meteorSpeed = preferences.meteorSpeed ?? 1
        policy.permitsMeteors = preferences.meteorsEnabled ?? true
        policy.widgetRainAreas = widgetRainAreas
        policy.showsWidgetGuide = showsWidgetGuide
        policy.notchHaze = notchHaze
        desktopEnvironment.setPolicy(policy)
        var previewPolicy = policy
        previewPolicy.maximumDimension = min(1440, policy.maximumDimension)
        previewEnvironment.setPolicy(previewPolicy)
        displayCount = NSScreen.screens.count
        if thermal == .critical { powerDescription = "Paused to let your Mac cool down" }
        else if isReduceMotion { powerDescription = "Still frame · Reduce Motion" }
        else if !preferences.animationsEnabled { powerDescription = "Animation paused" }
        else if thermal == .serious { powerDescription = "15 fps · Thermal protection" }
        else if isLowPower { powerDescription = "15 fps · Low Power Mode" }
        else if isOnBattery { powerDescription = "15 fps · Battery power" }
        else if efficient { powerDescription = "15 fps · Energy saver" }
        else { powerDescription = "30 fps · Adaptive resolution" }
    }

    private func observeLifecycle() {
        func observe(_ center: NotificationCenter, _ name: Notification.Name,
                     _ action: @escaping @MainActor (AppModel) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
            }
            observations.append((center, token))
        }
        let system = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor [weak model] in model?.updatePolicy() }
            }, kMADimFlashingLightsChangedNotification, nil, .deliverImmediately)
        observe(system, .NSProcessInfoPowerStateDidChange) { $0.updatePolicy() }
        observe(system, ProcessInfo.thermalStateDidChangeNotification) { $0.updatePolicy() }
        observe(system, NSApplication.didChangeScreenParametersNotification) {
            $0.updatePolicy()
            $0.desktop.rebuildIfRunning()
            $0.wallpaperActive = $0.desktop.isRunning
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.updatePolicy() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemSleeping = true; $0.handleActivityChange() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysSleeping = true; $0.handleActivityChange() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemSleeping = false; $0.handleActivityChange() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysSleeping = false; $0.handleActivityChange() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSessionInactive(true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSessionInactive(false) }
    }

    private func setSessionInactive(_ value: Bool) {
        sessionInactive = value
        handleActivityChange()
    }

    private func handleActivityChange() {
        updatePolicy()
        if sleeping || sessionInactive {
            heartbeat?.cancel()
            weatherTask?.cancel()
            weatherTask = nil
            isFetching = false
        } else {
            updateScenes(immediate: true)
            startHeartbeat()
        }
    }
}
