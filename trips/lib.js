// Shared helpers, loaded before every trip script.
// Edit on GitHub and the app picks it up on the next run: no reinstall needed.
//
// Native API (from the app):
//   trip.goto(place)               jump there (place = "address" or {lat, lon, name})
//   trip.drive(place, opts)        realistic drive; opts: {redLightChance, redMin, redMax, briefMax, timeScale, maxSpeed}
//   trip.walk(place, {speed})      straight-line walk, speed in m/s (default 1.3)
//   trip.stay(seconds, {jitter, status})   stay put with GPS wobble (metres)
//   trip.wait(seconds)  trip.clear()  trip.find("query") -> {lat, lon, name}
//   trip.here()  trip.random(a, b)  trip.hour()  trip.log(msg)  trip.status(msg)  trip.args

function offset(p, north, east) {
  const lat = p.lat + north / 111111;
  const lon = p.lon + east / (111111 * Math.cos(p.lat * Math.PI / 180));
  return { lat: lat, lon: lon, name: p.name };
}

function randomNear(p, minMeters, maxMeters) {
  const d = trip.random(minMeters, maxMeters);
  const angle = trip.random(0, 2 * Math.PI);
  return offset(p, d * Math.cos(angle), d * Math.sin(angle));
}

// Heavier traffic at rush hour (Apple's ETA already includes predicted traffic; this adds a bit on top).
function trafficScale() {
  const h = trip.hour();
  if ((h >= 7 && h <= 9) || (h >= 16 && h <= 18)) return trip.random(1.1, 1.3);
  if (h >= 22 || h <= 5) return trip.random(0.9, 1.0);
  return trip.random(1.0, 1.1);
}

function minutes(m) { return m * 60; }

// Pull into a parking spot near the place, sit in the car, walk to the door.
function arrive(place) {
  const spot = randomNear(place, 30, 70);
  trip.walk(spot, { speed: 3 });                     // rolling through the lot
  trip.stay(trip.random(30, 90), { jitter: 3, status: "Parked" });
  trip.walk(place, { speed: 1.3 });                  // walk in
  return spot;
}

// Move around inside: short walks between spots, longer stays, indoor GPS wobble.
function hangOut(place, totalMinutes, radius) {
  radius = radius || 25;
  const end = Date.now() + minutes(totalMinutes) * 1000;
  while (Date.now() < end - 60000) {
    const left = (end - Date.now()) / 1000;
    trip.walk(randomNear(place, 0, radius), { speed: 0.8 });
    trip.stay(Math.min(left, trip.random(minutes(3), minutes(15))), {
      jitter: trip.random(6, 15),
      status: "At " + (place.name || "destination") + " (" + Math.round(left / 60) + " min left)",
    });
  }
  trip.walk(place, { speed: 1.0 });                  // head back to the exit
}

function leave(spot) {
  trip.walk(spot, { speed: 1.3 });
  trip.stay(trip.random(20, 60), { jitter: 3, status: "Back in the car" });
}

// Full visit: drive there, park, go inside, wander, come back out.
function visit(place, stayMinutes, radius) {
  trip.drive(place, { timeScale: trafficScale() });
  const spot = arrive(place);
  hangOut(place, stayMinutes, radius);
  leave(spot);
}

function startAtHome(home) {
  trip.goto(home);
  trip.stay(trip.random(20, 60), { jitter: 4, status: "Leaving home" });
}

function driveHome(home) {
  trip.drive(home, { timeScale: trafficScale() });
  trip.walk(randomNear(home, 5, 15), { speed: 1.2 }); // driveway -> door
  trip.stay(30, { jitter: 4, status: "Home" });
}

function finish(a) {
  if (a.clearAtEnd) trip.clear();
}

// Nearest place matching a search near home, e.g. nearest("Cineplex").
function nearest(query) {
  const p = trip.find(query);
  if (!p) throw "Couldn't find " + query;
  trip.log("Picked " + query + " at " + p.lat.toFixed(4) + ", " + p.lon.toFixed(4));
  return p;
}
