//
//  TripRunner.swift
//  StikDebug
//
//  Runs trip scripts (JavaScript) that drive the simulated location:
//  realistic drives with traffic-paced speed and stops at lights/turns,
//  stays, teleports and clearing. Scripts are fetched from a URL on every
//  run, so trip behaviour can change without rebuilding the app.
//

import Foundation
import CoreLocation
import MapKit
import JavaScriptCore

private struct TripCancelled: Error {}

final class TripRunner: ObservableObject {
    static let shared = TripRunner()

    /// Folder holding `index.json` (presets) and the trip scripts.
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
    trip.goto(a.home);
    trip.drive(a.dest);
    trip.stay(a.stayMinutes * 60);
    if (a.driveBack) trip.drive(a.home);
    if (a.clearAtEnd) trip.clear();
    """

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle"
    @Published private(set) var log: [String] = []

    private let queue = DispatchQueue(label: "com.stik.trip-runner", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { stateLock.withLock { _cancelled } }
        set { stateLock.withLock { _cancelled = newValue } }
    }
    private var current: CLLocationCoordinate2D?

    private init() {}

    // MARK: - Public API

    /// Fetches `file` from the trips folder (falling back to the cached copy,
    /// then the built-in script) and runs it with `args` exposed as `trip.args`.
    func runRemote(file: String = "default.js", args: [String: Any]) {
        guard !isRunning else { return }
        setRunning(true)
        appendLog("Fetching \(file)…")
        Task.detached {
            // lib.js holds shared helpers (realistic arrivals, wandering…) and loads before every trip.
            let lib = await Self.fetchScript("lib.js", fallback: "") { self.appendLog($0) }
            let source = await Self.fetchScript(file, fallback: Self.fallbackScript) { self.appendLog($0) }
            self.queue.async { self.execute(source: lib + "\n;\n" + source, args: args) }
        }
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
            self.status = code == 0 ? "Real location restored" : "Stopped"
        }
        appendLog(code == 0 ? "Cleared simulated location" : "Stopped (nothing to clear, code \(code))")
        return code == 0
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
        guard let context = JSContext() else {
            finish("Could not create JS context")
            return
        }
        install(into: context, args: args)
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "unknown error"
            if message != "cancelled" { self?.appendLog("Script error: \(message)") }
        }
        context.evaluateScript(source)
        finish(cancelled ? "Stopped" : "Trip finished")
    }

    private func finish(_ message: String) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.status = message
        }
        appendLog(message)
    }

    // MARK: - JS bridge

    private func install(into context: JSContext, args: [String: Any]) {
        let trip = JSValue(newObjectIn: context)!

        // Runs a blocking primitive; turns cancellation/errors into JS exceptions.
        func guarded(_ ctx: JSContext?, _ body: () throws -> Void) {
            do { try body() } catch is TripCancelled {
                ctx?.exception = JSValue(object: "cancelled", in: ctx)
            } catch {
                ctx?.exception = JSValue(object: "\(error.localizedDescription)", in: ctx)
            }
        }

        let goto: @convention(block) (JSValue) -> Void = { [unowned self] place in
            guarded(JSContext.current()) {
                let coordinate = try self.resolve(place)
                self.setStatus("At \(Self.label(place))")
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
                let jitter = opts.isObject ? (opts.forProperty("jitter")?.toDouble() ?? 3) : 3
                if let message = opts.isObject ? opts.forProperty("status") : nil, message.isString {
                    self.setStatus(message.toString())
                } else {
                    self.setStatus("Staying \(Self.duration(seconds))")
                }
                try self.hold(here, seconds: seconds, jitter: jitter.isNaN ? 3 : jitter)
            }
        }
        let walk: @convention(block) (JSValue, JSValue) -> Void = { [unowned self] place, opts in
            guarded(JSContext.current()) {
                let speed = opts.isObject ? (opts.forProperty("speed")?.toDouble() ?? 1.3) : 1.3
                try self.walk(to: try self.resolve(place), speed: speed.isNaN || speed <= 0 ? 1.3 : speed)
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
        let log: @convention(block) (String) -> Void = { [unowned self] message in self.appendLog(message) }
        let status: @convention(block) (String) -> Void = { [unowned self] message in self.setStatus(message) }
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
        trip.setObject(wait, forKeyedSubscript: "wait" as NSString)
        trip.setObject(clear, forKeyedSubscript: "clear" as NSString)
        trip.setObject(find, forKeyedSubscript: "find" as NSString)
        trip.setObject(log, forKeyedSubscript: "log" as NSString)
        trip.setObject(status, forKeyedSubscript: "status" as NSString)
        trip.setObject(random, forKeyedSubscript: "random" as NSString)
        trip.setObject(hour, forKeyedSubscript: "hour" as NSString)
        trip.setObject(isCancelled, forKeyedSubscript: "cancelled" as NSString)
        trip.setObject(here, forKeyedSubscript: "here" as NSString)
        trip.setObject(args, forKeyedSubscript: "args" as NSString)
        context.setObject(trip, forKeyedSubscript: "trip" as NSString)
        context.evaluateScript("var console = { log: function() { trip.log(Array.prototype.join.call(arguments, ' ')); } };")
    }

    // MARK: - Primitives (run on `queue`, blocking)

    private func resolve(_ place: JSValue) throws -> CLLocationCoordinate2D {
        if place.isString { return try geocode(place.toString()) }
        if place.isObject,
           let lat = place.forProperty("lat")?.toDouble(),
           let lon = place.forProperty("lon")?.toDouble(),
           !lat.isNaN, !lon.isNaN {
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if CLLocationCoordinate2DIsValid(c) { return c }
        }
        throw TripError("Invalid place: expected \"address\" or {lat, lon}")
    }

    private static func label(_ place: JSValue) -> String {
        if place.isString { return place.toString() }
        if let name = place.forProperty("name"), name.isString { return name.toString() }
        return "pin"
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
        setStatus("Routing to \(label)…")
        let route = try route(from: start, to: destination)
        let plan = DrivePlan(route: route, options: options)
        appendLog(String(format: "Drive to %@: %.1f km, ETA %@, %d stops",
                         label, route.distance / 1000, Self.duration(plan.totalTime), plan.stops.filter { $0.seconds > 0 }.count))

        let tick: TimeInterval = 1
        var s: CLLocationDistance = 0
        var nextStop = 0
        var noise = 1.0
        let startedAt = Date()

        while s < plan.length {
            try checkCancelled()
            noise = min(1.2, max(0.8, noise + Double.random(in: -0.05...0.05)))
            let speed = min(options.maxSpeed, plan.baseSpeed * noise * plan.rampFactor(at: s))
            s = min(plan.length, s + speed * tick)

            if nextStop < plan.stops.count, s >= plan.stops[nextStop].distance {
                let stop = plan.stops[nextStop]
                nextStop += 1
                s = stop.distance
                if stop.seconds > 0 {
                    try send(plan.coordinate(at: s))
                    setStatus(String(format: "Stopped (%@), %.0f%% there", stop.seconds > 10 ? "red light" : "stop sign",
                                     100 * s / plan.length))
                    try hold(plan.coordinate(at: s), seconds: stop.seconds, jitter: 0)
                    continue
                }
            }

            try send(plan.coordinate(at: s))
            let remaining = max(0, plan.totalTime - Date().timeIntervalSince(startedAt))
            setStatus(String(format: "Driving to %@: %.0f%%, ~%@ left", label, 100 * s / plan.length, Self.duration(remaining)))
            try sleep(tick)
        }
        try send(destination)
        appendLog("Arrived at \(label)")
    }

    /// Straight-line walk at `speed` m/s (parking lot → door, wandering inside).
    private func walk(to destination: CLLocationCoordinate2D, speed: Double) throws {
        guard let start = current else { throw TripError("walk() needs a start: call goto() first") }
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        let steps = max(1, Int(distance / speed / 2))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let point = CLLocationCoordinate2D(latitude: start.latitude + (destination.latitude - start.latitude) * t,
                                               longitude: start.longitude + (destination.longitude - start.longitude) * t)
            try send(Self.jittered(point, meters: 2))
            current = point
            try sleep(2)
        }
    }

    /// Keeps re-sending a location (with small GPS-like jitter) for `seconds`.
    private func hold(_ coordinate: CLLocationCoordinate2D, seconds: TimeInterval, jitter: Double = 3) throws {
        let end = Date().addingTimeInterval(max(0, seconds))
        repeat {
            try send(jitter > 0 ? Self.jittered(coordinate, meters: jitter) : coordinate)
            current = coordinate
            try sleep(min(4, max(0, end.timeIntervalSinceNow)))
        } while Date() < end
    }

    private func send(_ coordinate: CLLocationCoordinate2D) throws {
        let ip = DeviceConnectionContext.targetIPAddress
        let pairing = PairingFileStore.prepareURL().path
        for attempt in 0..<3 {
            try checkCancelled()
            let code: Int32 = LocationSimulationCommandQueue.shared.sync {
                self.cancelled ? 0 : simulate_location(ip, coordinate.latitude, coordinate.longitude, pairing)
            }
            if code == 0 {
                current = coordinate
                if attempt == 0, !LocationSimulationSession.shared.isActive {
                    DispatchQueue.main.async { LocationSimulationSession.shared.start(at: coordinate) }
                }
                return
            }
            appendLog("Location update failed (code \(code)), retrying…")
            try sleep(2)
        }
        throw TripError("Lost connection: is LocalDevVPN on?")
    }

    private func clear() throws {
        let code: Int32 = LocationSimulationCommandQueue.shared.sync { clear_simulated_location() }
        DispatchQueue.main.async { LocationSimulationSession.shared.stop() }
        current = nil
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
    private func blocking<T>(_ start: (@escaping (T?, Error?) -> Void) -> Void) throws -> T? {
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

    // MARK: - Helpers

    private func setRunning(_ running: Bool) {
        DispatchQueue.main.async {
            self.isRunning = running
            if running { self.log = [] }
        }
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async { self.status = message }
    }

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
    var id: String { file + name }
}

private struct TripError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Knobs a script can pass as the second argument to `trip.drive(place, opts)`.
private struct DriveOptions {
    var redLightChance = 0.45     // chance a turn/intersection is a red light
    var redMin = 15.0, redMax = 70.0
    var briefMax = 4.0            // stop sign / yield pause
    var timeScale = 1.0           // >1 = heavier traffic than Apple predicts
    var maxSpeed = 30.0           // m/s (~108 km/h)

    init(_ opts: JSValue) {
        guard opts.isObject else { return }
        func read(_ key: String, _ target: inout Double) {
            if let v = opts.forProperty(key), v.isNumber { target = v.toDouble() }
        }
        read("redLightChance", &redLightChance)
        read("redMin", &redMin)
        read("redMax", &redMax)
        read("briefMax", &briefMax)
        read("timeScale", &timeScale)
        read("maxSpeed", &maxSpeed)
    }
}

/// Precomputed geometry and pacing for one drive.
private struct DrivePlan {
    struct Stop { let distance: CLLocationDistance; let seconds: TimeInterval }

    let points: [CLLocationCoordinate2D]
    let cumulative: [CLLocationDistance]
    let stops: [Stop]
    let baseSpeed: Double
    let totalTime: TimeInterval
    var length: CLLocationDistance { cumulative.last ?? 0 }

    init(route: MKRoute, options: DriveOptions) {
        var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: route.polyline.pointCount)
        route.polyline.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
        var cumulative: [CLLocationDistance] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative.last! + CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)))
        }
        self.points = points
        self.cumulative = cumulative

        // Every manoeuvre (turn, merge, intersection) ends a route step: stop there sometimes.
        var stops: [Stop] = []
        var searchFrom = 0
        for step in route.steps.dropLast() where step.distance > 0 {
            let count = step.polyline.pointCount
            guard count > 0 else { continue }
            var end = kCLLocationCoordinate2DInvalid
            step.polyline.getCoordinates(&end, range: NSRange(location: count - 1, length: 1))
            let endLocation = CLLocation(latitude: end.latitude, longitude: end.longitude)
            var best = searchFrom
            var bestDistance = CLLocationDistance.greatestFiniteMagnitude
            for i in searchFrom..<points.count {
                let d = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude).distance(from: endLocation)
                if d < bestDistance { bestDistance = d; best = i }
            }
            searchFrom = best
            let seconds = Double.random(in: 0...1) < options.redLightChance
                ? Double.random(in: options.redMin...max(options.redMin, options.redMax))
                : Double.random(in: 0...max(0, options.briefMax))
            stops.append(Stop(distance: cumulative[best], seconds: seconds < 1 ? 0 : seconds))
        }
        self.stops = stops

        let length = cumulative.last ?? 0
        let eta = max(route.expectedTravelTime, 1) * options.timeScale
        let stopTime = stops.reduce(0) { $0 + $1.seconds }
        let moving = max(eta - stopTime, length / options.maxSpeed, 1)
        baseSpeed = length / moving
        totalTime = moving + stopTime
    }

    /// Slow down approaching and leaving stops (~60 m ramp).
    func rampFactor(at s: CLLocationDistance) -> Double {
        let nearest = stops.lazy.filter { $0.seconds > 0 }.map { abs($0.distance - s) }.min() ?? .infinity
        return max(0.3, min(1, nearest / 60))
    }

    func coordinate(at s: CLLocationDistance) -> CLLocationCoordinate2D {
        guard points.count > 1 else { return points.first ?? kCLLocationCoordinate2DInvalid }
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        let t = span > 0 ? (s - cumulative[lo]) / span : 0
        let a = points[lo], b = points[hi]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}
