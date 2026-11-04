//
//  TripRunner.swift
//  StikDebug
//
//  Runs trip scripts (JavaScript) that drive the simulated location. Swift provides
//  realistic primitives (drives with real traffic lights/stop signs from OpenStreetMap,
//  rounded turns with braking, traffic slowdowns, walking paths, stays); the scripts in
//  the GitHub `trips/` folder decide what happens, so behaviour can change without a rebuild.
//

import Foundation
import CoreLocation
import MapKit
import JavaScriptCore
import ActivityKit

private struct TripCancelled: Error {}
/// Thrown when the trip hands back to the real location early (e.g. near home).
private struct TripEnded: Error {}

final class TripRunner: ObservableObject {
    static let shared = TripRunner()

    /// Folder holding `index.json` (presets), `lib.js` and the trip scripts.
    static let defaultBaseURL = "https://raw.githubusercontent.com/Angxers2/StikDebug/main/trips/"
    static let baseURLKey = "trip.baseURL"
    static var baseURL: String {
        let saved = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        let base = saved.isEmpty ? defaultBaseURL : saved
        return base.hasSuffix("/") ? base : base + "/"
    }

    /// Used when the remote script can't be fetched and nothing is cached.
    static let fallbackScript = """
    const a = trip.args;
    trip.goto(a.start);
    (a.stops || []).forEach(function (s) { trip.drive(s); trip.stay((s.minutes || 5) * 60); });
    trip.drive(a.dest);
    trip.stay(a.stayMinutes * 60);
    if (a.driveBack) trip.drive(a.start);
    if (a.clearAtEnd) trip.clear();
    """

    static let fallbackWalkScript = """
    const a = trip.args;
    trip.goto(a.path[0]);
    do { trip.walkPath(a.path, { speed: a.walkSpeed }); } while (a.walkLoop && !trip.cancelled());
    if (a.clearAtEnd) trip.clear();
    """

    // Live state (main thread).
    @Published private(set) var isRunning = false
    @Published private(set) var phase: TripPhase = .idle
    @Published private(set) var title = "Ready"
    @Published private(set) var detail = ""
    @Published private(set) var speedKmh = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var eta: Date?
    @Published private(set) var leaveAt: Date?
    @Published private(set) var position: CLLocationCoordinate2D?
    @Published private(set) var heading: Double = 0
    @Published private(set) var routeLine: [CLLocationCoordinate2D] = []
    @Published private(set) var log: [String] = []

    private let queue = DispatchQueue(label: "com.stik.trip-runner", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { stateLock.withLock { _cancelled } }
        set { stateLock.withLock { _cancelled = newValue } }
    }
    private var current: CLLocationCoordinate2D?
    private var tripName = "Trip"
    private var activity: Activity<TripActivityAttributes>?
    private var lastActivityPush = Date.distantPast
    /// Hand back to the real location when the simulated position comes (inbound) within `radius` of `point`.
    private var handover: (point: CLLocation, radius: Double)?
    private var handoverArmed = false

    private init() {}

    // MARK: - Public API

    /// Fetches `file` from the trips folder (falling back to the cached copy,
    /// then the built-in script) and runs it with `args` exposed as `trip.args`.
    func runRemote(file: String = "default.js", name: String = "Trip", args: [String: Any]) {
        guard !isRunning else { return }
        tripName = name
        isRunning = true
        log = []
        routeLine = []
        update(phase: .idle, title: "Starting \(name)…", detail: "", leaveAt: .some(nil), eta: .some(nil), force: true)
        appendLog("Fetching \(file)…")
        Task.detached {
            // lib.js holds shared helpers (realistic arrivals, drive-thrus, wandering…) and loads before every trip.
            let lib = await Self.fetchScript("lib.js", fallback: "") { self.appendLog($0) }
            let fallback = file == "walk.js" ? Self.fallbackWalkScript : Self.fallbackScript
            let source = await Self.fetchScript(file, fallback: fallback) { self.appendLog($0) }
            self.queue.async { self.execute(source: lib + "\n;\n" + source, args: args) }
        }
    }

    /// Stops any running trip and restores the real location.
    @discardableResult
    func stopAndClear() async -> Bool {
        cancelled = true
        let code: Int32 = await withCheckedContinuation { cont in
            LocationSimulationCommandQueue.shared.async {
                cont.resume(returning: clear_simulated_location())
            }
        }
        await MainActor.run {
            LocationSimulationSession.shared.stop()
            self.isRunning = false
            self.speedKmh = 0
            self.phase = .done
            self.title = code == 0 ? "Back to real location" : "Stopped"
            self.detail = ""
            self.position = nil
            self.routeLine = []
            self.endActivity(immediately: true)
        }
        appendLog(code == 0 ? "Cleared simulated location" : "Stopped (nothing to clear, code \(code))")
        return code == 0
    }

    /// Preset trips listed in `index.json` in the trips folder.
    static func fetchPresets() async -> [TripPreset] {
        guard let url = URL(string: baseURL + "index.json") else { return [] }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let cacheKey = "trip.cached.index"
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let presets = try? JSONDecoder().decode([TripPreset].self, from: data) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            return presets
        }
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let presets = try? JSONDecoder().decode([TripPreset].self, from: data) {
            return presets
        }
        return []
    }

    // MARK: - Script execution

    private static func fetchScript(_ file: String, fallback: String, log: (String) -> Void) async -> String {
        let cachedScriptKey = "trip.cached.\(file)"
        let urlString = file.hasPrefix("http") ? file : baseURL + file
        if let url = URL(string: urlString) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let source = String(data: data, encoding: .utf8), !source.isEmpty {
                UserDefaults.standard.set(source, forKey: cachedScriptKey)
                log("Loaded \(file)")
                return source
            }
        }
        if let cached = UserDefaults.standard.string(forKey: cachedScriptKey) {
            log("Offline: using cached \(file)")
            return cached
        }
        if !fallback.isEmpty { log("Using built-in script") }
        return fallback
    }

    private func execute(source: String, args: [String: Any]) {
        cancelled = false
        current = nil
        handoverArmed = false
        handover = nil
        if let h = args["handover"] as? [String: Any], let lat = h["lat"] as? Double, let lon = h["lon"] as? Double,
           let radius = args["realWithin"] as? Double, radius > 0 {
            handover = (CLLocation(latitude: lat, longitude: lon), radius)
        }
        guard let context = JSContext() else {
            finish("Could not create JS context")
            return
        }
        install(into: context, args: args)
        var ended = false
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            if message == "ended" { ended = true; return }
            if message != "cancelled" { self?.appendLog("Script error: \(message)") }
        }
        context.evaluateScript(source)
        finish(cancelled ? "Stopped" : ended ? "Back to real location" : "Trip finished")
    }

    private func finish(_ message: String) {
        appendLog(message)
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.speedKmh = 0
            self.phase = .done
            self.title = message
            self.detail = ""
            self.endActivity(immediately: false)
        }
    }

    // MARK: - JS bridge

    private func install(into context: JSContext, args: [String: Any]) {
        let trip = JSValue(newObjectIn: context)!

        // Runs a blocking primitive; turns cancellation/errors into JS exceptions.
        func guarded(_ ctx: JSContext?, _ body: () throws -> Void) {
            do { try body() } catch is TripCancelled {
                ctx?.exception = JSValue(object: "cancelled", in: ctx)
            } catch is TripEnded {
                ctx?.exception = JSValue(object: "ended", in: ctx)
            } catch {
                ctx?.exception = JSValue(object: "\(error.localizedDescription)", in: ctx)
            }
        }

        let goto: @convention(block) (JSValue) -> Void = { [unowned self] place in
            guarded(JSContext.current()) {
                let coordinate = try self.resolve(place)
                self.update(phase: .parked, title: "At \(Self.label(place))", detail: "")
                try self.hold(coordinate, seconds: 1)
            }
        }
        let drive: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] place, opts in
            guarded(JSContext.current()) {
                try self.drive(to: try self.resolve(place), label: Self.label(place), options: DriveOptions(opts))
            }
        }
        let stay: @convention(block) (Double, JSValue) -> Void = { [unowned self] seconds, opts in
            guarded(JSContext.current()) {
                guard let here = self.current else { throw TripError("stay() needs a location: call goto() first") }
                let jitter = Self.number(opts, "jitter") ?? 3
                if let message = Self.string(opts, "status") { self.update(detail: message) }
                self.update(speed: 0)
                try self.hold(here, seconds: seconds, jitter: jitter)
            }
        }
        let walk: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] place, opts in
            guarded(JSContext.current()) {
                guard let start = self.current else { throw TripError("walk() needs a start: call goto() first") }
                let target = try self.resolve(place)
                try self.followPath([start, target], speed: Self.number(opts, "speed") ?? 1.3,
                                    jitter: Self.number(opts, "jitter") ?? 2, showLine: false)
            }
        }
        let walkPath: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] points, opts in
            guarded(JSContext.current()) {
                let length = Int(points.forProperty("length")?.toInt32() ?? 0)
                let path = try (0..<length).map { try self.resolve(points.atIndex($0)) }
                guard path.count > 1 else { throw TripError("walkPath() needs at least 2 points") }
                try self.followPath(path, speed: Self.number(opts, "speed") ?? 1.4,
                                    jitter: Self.number(opts, "jitter") ?? 2, showLine: true)
            }
        }
        let wait: @convention(block) (Double) -> Void = { [unowned self] seconds in
            guarded(JSContext.current()) { try self.sleep(seconds) }
        }
        let clear: @convention(block) () -> Void = { [unowned self] in
            guarded(JSContext.current()) { try self.clear() }
        }
        let find: @convention(block) (String) -> Any? = { [unowned self] query in
            guard let c = try? self.geocode(query) else { return nil }
            return ["lat": c.latitude, "lon": c.longitude, "name": query]
        }
        // trip.activity({phase, title, detail, leaveAt (ms since epoch or null)}): what the app and Live Activity show.
        let activity: @convention(block) (JSValue) -> Void = { [unowned self] info in
            let phase = Self.string(info, "phase").flatMap(TripPhase.init(rawValue:))
            var leave: Date??
            if info.isObject, let value = info.forProperty("leaveAt"), !value.isUndefined {
                leave = value.isNumber ? .some(Date(timeIntervalSince1970: value.toDouble() / 1000)) : .some(nil)
            }
            self.update(phase: phase, title: Self.string(info, "title"), detail: Self.string(info, "detail"),
                        leaveAt: leave, speed: phase == nil || phase == .driving ? nil : 0, force: true)
        }
        let log: @convention(block) (String) -> Void = { [unowned self] message in self.appendLog(message) }
        let status: @convention(block) (String) -> Void = { [unowned self] message in self.update(detail: message) }
        let random: @convention(block) (Double, Double) -> Double = { lo, hi in Double.random(in: min(lo, hi)...max(lo, hi)) }
        let hour: @convention(block) () -> Int = { Calendar.current.component(.hour, from: Date()) }
        let isCancelled: @convention(block) () -> Bool = { [unowned self] in self.cancelled }
        let here: @convention(block) () -> Any? = { [unowned self] in
            self.current.map { ["lat": $0.latitude, "lon": $0.longitude] }
        }

        trip.setObject(goto, forKeyedSubscript: "goto" as NSString)
        trip.setObject(drive, forKeyedSubscript: "drive" as NSString)
        trip.setObject(stay, forKeyedSubscript: "stay" as NSString)
        trip.setObject(walk, forKeyedSubscript: "walk" as NSString)
        trip.setObject(walkPath, forKeyedSubscript: "walkPath" as NSString)
        trip.setObject(wait, forKeyedSubscript: "wait" as NSString)
        trip.setObject(clear, forKeyedSubscript: "clear" as NSString)
        trip.setObject(find, forKeyedSubscript: "find" as NSString)
        trip.setObject(activity, forKeyedSubscript: "activity" as NSString)
        trip.setObject(log, forKeyedSubscript: "log" as NSString)
        trip.setObject(status, forKeyedSubscript: "status" as NSString)
        trip.setObject(random, forKeyedSubscript: "random" as NSString)
        trip.setObject(hour, forKeyedSubscript: "hour" as NSString)
        trip.setObject(here, forKeyedSubscript: "here" as NSString)
        trip.setObject(isCancelled, forKeyedSubscript: "cancelled" as NSString)
        trip.setObject(args, forKeyedSubscript: "args" as NSString)
        context.setObject(trip, forKeyedSubscript: "trip" as NSString)
        context.evaluateScript("var console = { log: function() { trip.log(Array.prototype.join.call(arguments, ' ')); } };")
    }

    private static func number(_ value: JSValue, _ key: String) -> Double? {
        guard value.isObject, let v = value.forProperty(key), v.isNumber else { return nil }
        let d = v.toDouble()
        return d.isNaN ? nil : d
    }

    private static func string(_ value: JSValue, _ key: String) -> String? {
        guard value.isObject, let v = value.forProperty(key), v.isString else { return nil }
        return v.toString()
    }

    // MARK: - Primitives (run on `queue`, blocking)

    private func resolve(_ place: JSValue) throws -> CLLocationCoordinate2D {
        if place.isString { return try geocode(place.toString()) }
        if let lat = Self.number(place, "lat"), let lon = Self.number(place, "lon") {
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if CLLocationCoordinate2DIsValid(c) { return c }
        }
        throw TripError("Invalid place: expected \"address\" or {lat, lon}")
    }

    private static func label(_ place: JSValue) -> String {
        if place.isString { return place.toString() }
        return string(place, "name") ?? "pin"
    }

    private func geocode(_ query: String) throws -> CLLocationCoordinate2D {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let current {
            request.region = MKCoordinateRegion(center: current, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let item: MKMapItem? = try blocking { done in
            MKLocalSearch(request: request).start { response, error in
                done(response?.mapItems.first, error)
            }
        }
        guard let item else { throw TripError("No place found for \"\(query)\"") }
        return item.placemark.coordinate
    }

    private func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .automobile
        request.departureDate = Date() // lets Apple factor in predicted traffic
        let route: MKRoute? = try blocking { done in
            MKDirections(request: request).calculate { response, error in
                done(response?.routes.first, error)
            }
        }
        guard let route else { throw TripError("No drivable route found") }
        return route
    }

    private func drive(to destination: CLLocationCoordinate2D, label: String, options: DriveOptions) throws {
        guard let start = current else { throw TripError("drive() needs a start: call goto() first") }
        update(phase: .driving, title: "Driving to \(label)", detail: "Finding route…", leaveAt: .some(nil), force: true)
        let route = try route(from: start, to: destination)
        let controls = options.realSignals ? fetchTrafficControls(along: route.polyline) : nil
        let plan = DrivePlan(route: route, controls: controls, options: options)
        appendLog(String(format: "Drive to %@: %.1f km, ETA %@, %d lights/stops%@",
                         label, plan.length / 1000, Self.duration(plan.totalTime), plan.events.count,
                         controls == nil ? " (estimated)" : ""))
        DispatchQueue.main.async { self.routeLine = plan.points }

        let tick: TimeInterval = 1
        var s: CLLocationDistance = 0
        var nextEvent = 0
        var noise = 1.0
        let averageSpeed = plan.length / max(plan.totalTime, 1)

        while s < plan.length {
            try checkCancelled()
            noise = min(1.08, max(0.9, noise + Double.random(in: -0.03...0.03)))
            let speed = min(plan.allowedSpeed(at: s), plan.cruise * noise)
            var nextS = min(plan.length, s + speed * tick)

            if nextEvent < plan.events.count, nextS >= plan.events[nextEvent].s {
                let event = plan.events[nextEvent]
                nextEvent += 1
                nextS = event.s
                let point = plan.coordinate(at: nextS)
                try send(point, heading: plan.heading(at: nextS))
                s = nextS
                update(phase: .stopped, detail: event.label, speed: 0, progress: s / plan.length,
                       eta: .some(Date().addingTimeInterval(event.seconds + (plan.length - s) / averageSpeed)))
                try hold(point, seconds: event.seconds, jitter: 0)
                update(phase: .driving, detail: plan.roadName(at: s))
                continue
            }

            s = nextS
            try send(plan.coordinate(at: s), heading: plan.heading(at: s))
            update(phase: .driving, detail: plan.roadName(at: s), speed: Int((speed * 3.6).rounded()),
                   progress: s / plan.length, eta: .some(Date().addingTimeInterval((plan.length - s) / averageSpeed)))
            try sleep(tick)
        }
        try send(destination, heading: nil)
        update(phase: .parked, title: "Arrived at \(label)", detail: "", speed: 0, progress: 1, eta: .some(nil), force: true)
        appendLog("Arrived at \(label)")
    }

    /// Follows a path at `speed` m/s (walking, drive-thru lanes, parking lots).
    private func followPath(_ path: [CLLocationCoordinate2D], speed: Double, jitter: Double, showLine: Bool) throws {
        let line = PathLine(path)
        guard line.length > 0 else { return }
        if showLine { DispatchQueue.main.async { self.routeLine = path } }
        let speed = max(0.2, speed)
        var s = 0.0
        while s < line.length {
            try checkCancelled()
            s = min(line.length, s + speed * Double.random(in: 0.85...1.15))
            let point = line.coordinate(at: s)
            try send(jitter > 0 ? Self.jittered(point, meters: jitter) : point, heading: line.heading(at: s))
            current = point
            update(speed: Int((speed * 3.6).rounded()), progress: s / line.length)
            try sleep(1)
        }
        update(speed: 0)
    }

    /// Keeps re-sending a location (with small GPS-like jitter) for `seconds`.
    private func hold(_ coordinate: CLLocationCoordinate2D, seconds: TimeInterval, jitter: Double = 3) throws {
        let end = Date().addingTimeInterval(max(0, seconds))
        repeat {
            try send(jitter > 0 ? Self.jittered(coordinate, meters: jitter) : coordinate, heading: nil)
            current = coordinate
            try sleep(min(4, max(0, end.timeIntervalSinceNow)))
        } while Date() < end
    }

    private func send(_ coordinate: CLLocationCoordinate2D, heading: Double?) throws {
        let ip = DeviceConnectionContext.targetIPAddress
        let pairing = PairingFileStore.prepareURL().path
        for attempt in 0..<3 {
            try checkCancelled()
            let code: Int32 = LocationSimulationCommandQueue.shared.sync {
                self.cancelled ? 0 : simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing)
            }
            if code == 0 {
                current = coordinate
                try checkHandover(coordinate)
                DispatchQueue.main.async {
                    self.position = coordinate
                    if let heading { self.heading = heading }
                    if attempt == 0, !LocationSimulationSession.shared.isActive {
                        LocationSimulationSession.shared.start(at: coordinate)
                    }
                }
                return
            }
            appendLog("Location update failed (code \(code)), retrying…")
            try sleep(2)
        }
        throw TripError("Lost connection: is LocalDevVPN on?")
    }

    /// Armed once we've been outside the radius; fires when we come back inside it.
    private func checkHandover(_ coordinate: CLLocationCoordinate2D) throws {
        guard let handover else { return }
        let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: handover.point)
        if !handoverArmed {
            if distance > handover.radius + 50 { handoverArmed = true }
            return
        }
        guard distance <= handover.radius else { return }
        self.handover = nil
        appendLog(String(format: "Within %.0f m of the handover point: switching to real location", handover.radius))
        try clear()
        throw TripEnded()
    }

    private func clear() throws {
        let code: Int32 = LocationSimulationCommandQueue.shared.sync { clear_simulated_location() }
        DispatchQueue.main.async {
            LocationSimulationSession.shared.stop()
            self.position = nil
            self.routeLine = []
        }
        current = nil
        update(phase: .done, title: "Back to real location", detail: "", speed: 0, force: true)
        appendLog(code == 0 ? "Back to real location" : "Clear returned code \(code)")
    }

    private func sleep(_ seconds: TimeInterval) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try checkCancelled()
            Thread.sleep(forTimeInterval: min(0.25, max(0, end.timeIntervalSinceNow)))
        }
    }

    private func checkCancelled() throws {
        if cancelled { throw TripCancelled() }
    }

    /// Bridges a completion-handler API into a blocking call on the trip queue.
    private func blocking<T>(_ start: @escaping (@escaping (T?, Error?) -> Void) -> Void) throws -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        var failure: Error?
        DispatchQueue.main.async {
            start { value, error in
                result = value
                failure = error
                semaphore.signal()
            }
        }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            try checkCancelled()
        }
        if let failure { throw failure }
        return result
    }

    // MARK: - Real traffic lights, stop signs and yields (OpenStreetMap)

    private func fetchTrafficControls(along polyline: MKPolyline) -> [TrafficControl]? {
        let rect = polyline.boundingMapRect
        let sw = MKMapPoint(x: rect.minX, y: rect.maxY).coordinate
        let ne = MKMapPoint(x: rect.maxX, y: rect.minY).coordinate
        guard ne.latitude - sw.latitude < 0.6, ne.longitude - sw.longitude < 0.6 else { return nil } // too long a drive
        // Snap the box outward to a ~2 km grid so the request doesn't reveal exact start/end points.
        let grid = 0.02
        let south = (sw.latitude / grid).rounded(.down) * grid, west = (sw.longitude / grid).rounded(.down) * grid
        let north = (ne.latitude / grid).rounded(.up) * grid, east = (ne.longitude / grid).rounded(.up) * grid
        let query = """
        [out:json][timeout:15];node["highway"~"^(traffic_signals|stop|give_way)$"](\(south),\(west),\(north),\(east));out;
        """
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
        let data: Data? = try? blocking { done in
            URLSession.shared.dataTask(with: request) { data, _, error in done(data, error) }.resume()
        }
        struct Response: Decodable {
            struct Element: Decodable { let lat: Double?; let lon: Double?; let tags: [String: String]? }
            let elements: [Element]
        }
        guard let data, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            appendLog("Couldn't load traffic lights; estimating them")
            return nil
        }
        return response.elements.compactMap { element in
            guard let lat = element.lat, let lon = element.lon,
                  let kind = element.tags?["highway"].flatMap(TrafficControl.Kind.init(rawValue:)) else { return nil }
            return TrafficControl(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), kind: kind)
        }
    }

    // MARK: - Live state + Live Activity

    /// Updates the published state (and the Live Activity) from any thread.
    private func update(phase: TripPhase? = nil, title: String? = nil, detail: String? = nil,
                        leaveAt: Date?? = nil, speed: Int? = nil, progress: Double? = nil,
                        eta: Date?? = nil, force: Bool = false) {
        DispatchQueue.main.async {
            let phaseChanged = phase != nil && phase != self.phase
            if let phase { self.phase = phase }
            if let title { self.title = title }
            if let detail { self.detail = detail }
            if let leaveAt { self.leaveAt = leaveAt }
            if let speed { self.speedKmh = speed }
            if let progress { self.progress = progress }
            if let eta { self.eta = eta }
            self.pushActivity(force: force || phaseChanged || title != nil)
        }
    }

    private var activityState: TripActivityAttributes.ContentState {
        .init(phase: phase, title: title, detail: detail, speedKmh: speedKmh,
              progress: progress, eta: eta, leaveAt: leaveAt)
    }

    private func pushActivity(force: Bool) {
        guard isRunning, force || Date().timeIntervalSince(lastActivityPush) >= 2 else { return }
        lastActivityPush = Date()
        let content = ActivityContent(state: activityState, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: TripActivityAttributes(tripName: tripName), content: content)
        }
    }

    private func endActivity(immediately: Bool) {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task {
            await activity.end(content, dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(120)))
        }
    }

    // MARK: - Helpers

    private func appendLog(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        DispatchQueue.main.async {
            self.log.append("\(stamp)  \(message)")
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? "\(total / 3600)h \(total % 3600 / 60)m" : total >= 60 ? "\(total / 60)m" : "\(total)s"
    }

    private static func jittered(_ c: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
        let dLat = Double.random(in: -meters...meters) / 111_111
        let dLon = Double.random(in: -meters...meters) / (111_111 * max(0.1, cos(c.latitude * .pi / 180)))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}

struct TripPreset: Decodable, Identifiable, Hashable {
    let name: String
    let file: String
    let description: String?
    /// Whether the preset uses the destination picked in the app (`trip.args.dest`).
    let needsDestination: Bool?
    let icon: String?
    var id: String { file + name }
}

private struct TripError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct TrafficControl {
    enum Kind: String { case signal = "traffic_signals", stop, yield = "give_way" }
    let coordinate: CLLocationCoordinate2D
    let kind: Kind
}

/// Knobs a script can pass as the second argument to `trip.drive(place, opts)`.
private struct DriveOptions {
    var redLightChance = 0.45     // chance a real traffic light is red
    var redMin = 15.0, redMax = 75.0
    var timeScale = 1.0           // >1 = slower than Apple's traffic-aware ETA
    var maxSpeed = 30.0           // m/s (~108 km/h)
    var traffic = true            // stop-and-go slowdowns (more at rush hour)
    var realSignals = true        // use real lights/stop signs from OpenStreetMap

    init(_ opts: JSValue) {
        guard opts.isObject else { return }
        func read(_ key: String, _ target: inout Double) {
            if let v = opts.forProperty(key), v.isNumber { target = v.toDouble() }
        }
        func read(_ key: String, _ target: inout Bool) {
            if let v = opts.forProperty(key), v.isBoolean { target = v.toBool() }
        }
        read("redLightChance", &redLightChance)
        read("redMin", &redMin)
        read("redMax", &redMax)
        read("timeScale", &timeScale)
        read("maxSpeed", &maxSpeed)
        read("traffic", &traffic)
        read("realSignals", &realSignals)
    }
}

/// Local flat-earth projection (metres) around a reference point; fine at city scale.
private struct LocalProjection {
    let origin: CLLocationCoordinate2D
    let metersPerDegLon: Double
    init(_ origin: CLLocationCoordinate2D) {
        self.origin = origin
        metersPerDegLon = 111_320 * cos(origin.latitude * .pi / 180)
    }
    func point(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2((c.longitude - origin.longitude) * metersPerDegLon, (c.latitude - origin.latitude) * 110_540)
    }
    func coordinate(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + p.y / 110_540, longitude: origin.longitude + p.x / metersPerDegLon)
    }
}

private func vectorLength(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }

/// A polyline with distance lookup.
private struct PathLine {
    let points: [CLLocationCoordinate2D]
    let cumulative: [CLLocationDistance]
    var length: CLLocationDistance { cumulative.last ?? 0 }

    init(_ points: [CLLocationCoordinate2D]) {
        self.points = points
        var cumulative: [CLLocationDistance] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative.last! + CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)))
        }
        self.cumulative = cumulative
    }

    func index(at s: CLLocationDistance) -> Int {
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        return lo
    }

    func coordinate(at s: CLLocationDistance) -> CLLocationCoordinate2D {
        guard points.count > 1 else { return points.first ?? kCLLocationCoordinate2DInvalid }
        let lo = index(at: s), hi = min(lo + 1, points.count - 1)
        let span = cumulative[hi] - cumulative[lo]
        let t = span > 0 ? min(1, max(0, (s - cumulative[lo]) / span)) : 0
        let a = points[lo], b = points[hi]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Compass heading (degrees) of travel at distance `s`.
    func heading(at s: CLLocationDistance) -> Double {
        guard points.count > 1 else { return 0 }
        let lo = min(index(at: s), points.count - 2)
        let a = points[lo], b = points[lo + 1]
        let dx = (b.longitude - a.longitude) * cos(a.latitude * .pi / 180)
        let dy = b.latitude - a.latitude
        let degrees = atan2(dx, dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// Precomputed geometry and pacing for one drive.
private struct DrivePlan {
    struct Event { let s: CLLocationDistance; let seconds: TimeInterval; let label: String }
    struct Zone { let s: CLLocationDistance; let vmax: Double; let length: CLLocationDistance }

    static let decel = 2.2, accel = 1.6, crawl = 1.2

    let line: PathLine
    let events: [Event]
    let zones: [Zone]
    let cruise: Double
    let totalTime: TimeInterval
    let steps: [(s: CLLocationDistance, name: String)]
    var points: [CLLocationCoordinate2D] { line.points }
    var length: CLLocationDistance { line.length }

    init(route: MKRoute, controls: [TrafficControl]?, options: DriveOptions) {
        var raw = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: route.polyline.pointCount)
        route.polyline.getCoordinates(&raw, range: NSRange(location: 0, length: raw.count))
        let projection = LocalProjection(raw.first ?? kCLLocationCoordinate2DInvalid)

        // 1. Round off corners so turns follow an arc instead of snapping 90°; remember how sharp each was.
        var smoothed: [CLLocationCoordinate2D] = []
        var turns: [(index: Int, angle: Double)] = []
        if raw.count > 2 {
            smoothed.append(raw[0])
            for i in 1..<(raw.count - 1) {
                let a = projection.point(raw[i - 1]), b = projection.point(raw[i]), c = projection.point(raw[i + 1])
                let inVec = b - a, outVec = c - b
                let inLen = vectorLength(inVec), outLen = vectorLength(outVec)
                guard inLen > 0.5, outLen > 0.5 else { smoothed.append(raw[i]); continue }
                let uIn = inVec / inLen, uOut = outVec / outLen
                let angle = acos(max(-1, min(1, (uIn * uOut).sum()))) * 180 / .pi
                guard angle > 20 else { smoothed.append(raw[i]); continue }
                let r = min(12, inLen * 0.45, outLen * 0.45)
                let p0 = b - uIn * r, p2 = b + uOut * r
                for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                    let p = (1 - t) * (1 - t) * p0 + 2 * t * (1 - t) * b + t * t * p2
                    smoothed.append(projection.coordinate(p))
                }
                turns.append((smoothed.count - 3, angle))
            }
            smoothed.append(raw[raw.count - 1])
        } else {
            smoothed = raw
        }
        let line = PathLine(smoothed)
        self.line = line
        func distance(atIndex i: Int) -> CLLocationDistance {
            line.cumulative[max(0, min(i, line.cumulative.count - 1))]
        }

        // 2. Slow zones: pull away from the start, brake into turns, stop at the end.
        var zones: [Zone] = [Zone(s: 0, vmax: 0, length: 0), Zone(s: line.length, vmax: 0, length: 0)]
        for turn in turns {
            let vmax = turn.angle >= 70 ? 4.5 : turn.angle >= 40 ? 7.5 : 11
            zones.append(Zone(s: distance(atIndex: turn.index), vmax: vmax, length: 0))
        }

        // 3. Traffic lights, stop signs, yields: real ones from OpenStreetMap when available.
        var events: [Event] = []
        func redLight(at s: CLLocationDistance) {
            events.append(Event(s: s, seconds: Double.random(in: options.redMin...max(options.redMin, options.redMax)), label: "Red light"))
            zones.append(Zone(s: s, vmax: 0, length: 0))
        }
        if let controls {
            let planar = smoothed.map(projection.point)
            var matched: [(s: CLLocationDistance, kind: TrafficControl.Kind)] = []
            for control in controls {
                let p = projection.point(control.coordinate)
                let threshold = control.kind == .signal ? 10.0 : 6.0
                var bestDistance = Double.infinity
                var bestS = 0.0
                for i in 0..<max(0, planar.count - 1) {
                    let a = planar[i], ab = planar[i + 1] - a
                    let lenSq = (ab * ab).sum()
                    let t = lenSq > 0 ? max(0, min(1, ((p - a) * ab).sum() / lenSq)) : 0
                    let d = vectorLength(p - (a + t * ab))
                    if d < bestDistance {
                        bestDistance = d
                        bestS = line.cumulative[i] + t * lenSq.squareRoot()
                    }
                }
                if bestDistance <= threshold, bestS > 15, bestS < line.length - 15 {
                    matched.append((bestS, control.kind))
                }
            }
            // One control per intersection (OSM often tags each approach).
            func rank(_ kind: TrafficControl.Kind) -> Int { kind == .signal ? 3 : kind == .stop ? 2 : 1 }
            var merged: [(s: CLLocationDistance, kind: TrafficControl.Kind)] = []
            for item in matched.sorted(by: { $0.s < $1.s }) {
                if let last = merged.last, item.s - last.s < 30 {
                    if rank(item.kind) > rank(last.kind) { merged[merged.count - 1] = item }
                } else {
                    merged.append(item)
                }
            }
            for item in merged {
                switch item.kind {
                case .signal:
                    if Double.random(in: 0...1) < options.redLightChance { redLight(at: item.s) }
                case .stop:
                    events.append(Event(s: item.s, seconds: Double.random(in: 2...5), label: "Stop sign"))
                    zones.append(Zone(s: item.s, vmax: 0, length: 0))
                case .yield:
                    if Double.random(in: 0...1) < 0.3 {
                        events.append(Event(s: item.s, seconds: Double.random(in: 1...3), label: "Yielding"))
                        zones.append(Zone(s: item.s, vmax: 0, length: 0))
                    } else {
                        zones.append(Zone(s: item.s, vmax: 4, length: 0))
                    }
                }
            }
        } else {
            // No map data: guess that some sharp turns are at lights.
            for turn in turns where turn.angle >= 70 && Double.random(in: 0...1) < 0.35 {
                redLight(at: distance(atIndex: turn.index))
            }
        }

        // 4. Stop-and-go traffic sections (more at rush hour).
        if options.traffic, line.length > 1500 {
            let hour = Calendar.current.component(.hour, from: Date())
            let rush = (7...9).contains(hour) || (16...18).contains(hour)
            let count = Int(line.length / (rush ? 2500 : 6000)) + (rush ? 1 : 0)
            for _ in 0..<count {
                let s = Double.random(in: 300...(line.length - 300))
                zones.append(Zone(s: s, vmax: Double.random(in: 1.5...5), length: Double.random(in: 100...400)))
            }
        }
        let sortedEvents = events.sorted { $0.s < $1.s }
        let sortedZones = zones.sorted { $0.s < $1.s }
        self.events = sortedEvents
        self.zones = sortedZones

        // 5. Road names for the status line.
        var steps: [(s: CLLocationDistance, name: String)] = []
        var travelled = 0.0
        for step in route.steps {
            if !step.instructions.isEmpty { steps.append((travelled, step.instructions)) }
            travelled += step.distance
        }
        self.steps = steps

        // 6. Pick a cruise speed so the whole drive (braking, stops, traffic) matches Apple's traffic-aware ETA.
        let stopTime = sortedEvents.reduce(0) { $0 + $1.seconds }
        let target = max(route.expectedTravelTime * options.timeScale - stopTime, line.length / options.maxSpeed, 1)
        var cruise = min(options.maxSpeed, line.length / target)
        for _ in 0..<4 {
            let simulated = Self.simulate(length: line.length, zones: sortedZones, cruise: cruise)
            cruise = min(options.maxSpeed, max(3, cruise * simulated / target))
        }
        self.cruise = cruise
        totalTime = Self.simulate(length: line.length, zones: sortedZones, cruise: cruise) + stopTime
    }

    func allowedSpeed(at s: CLLocationDistance) -> Double {
        Self.allowed(at: s, zones: zones, cruise: cruise)
    }

    private static func allowed(at s: CLLocationDistance, zones: [Zone], cruise: Double) -> Double {
        var v = cruise
        for zone in zones {
            let start = zone.s, end = zone.s + zone.length
            let gap = s < start ? start - s : s > end ? s - end : 0
            guard gap < 250 else { continue }
            let a = s < start ? decel : accel
            v = min(v, (zone.vmax * zone.vmax + 2 * a * gap).squareRoot())
        }
        return max(v, crawl)
    }

    private static func simulate(length: CLLocationDistance, zones: [Zone], cruise: Double) -> TimeInterval {
        var s = 0.0, t = 0.0
        while s < length {
            s += allowed(at: s, zones: zones, cruise: cruise)
            t += 1
        }
        return t
    }

    func coordinate(at s: CLLocationDistance) -> CLLocationCoordinate2D { line.coordinate(at: s) }
    func heading(at s: CLLocationDistance) -> Double { line.heading(at: s) }

    func roadName(at s: CLLocationDistance) -> String {
        steps.last(where: { $0.s <= s })?.name ?? ""
    }
}
