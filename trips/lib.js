// Shared helpers, loaded before every trip script.
// Edit on GitHub and the app picks it up on the next run: no reinstall needed.
//
// Native API (from the app):
//   trip.goto(place)                      jump there (place = "address" or {lat, lon, name})
//   trip.drive(place, opts)               realistic drive. opts: {redLightChance, redMin, redMax, timeScale,
//                                         maxSpeed, traffic, realSignals}
//   trip.walk(place, {speed, jitter})     straight line at speed m/s
//   trip.walkPath([places], {speed})      follow a drawn path
//   trip.stay(seconds, {jitter, status})  stay put with GPS wobble (metres)
//   trip.activity({phase, title, detail, leaveAt})   what the app + Live Activity show
//        phase: driving | stopped | parked | inside | walking | drivethru | done ; leaveAt: ms epoch or null
//   trip.wait(s) trip.clear() trip.find("query") trip.here() trip.random(a, b) trip.hour() trip.log(m) trip.args

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

function name(p) { return (p && p.name) || "destination"; }
function minutes(m) { return m * 60; }
function secondsUntil(endMs) { return Math.max(0, (endMs - Date.now()) / 1000); }

function phase(ph, title, detail, leaveAtMs) {
  trip.activity({ phase: ph, title: title, detail: detail || "", leaveAt: leaveAtMs === undefined ? null : leaveAtMs });
}

// Heavier traffic at rush hour (Apple's ETA already includes predicted traffic; this adds a bit on top).
function trafficScale() {
  const h = trip.hour();
  if ((h >= 7 && h <= 9) || (h >= 16 && h <= 18)) return trip.random(1.05, 1.2);
  if (h >= 22 || h <= 5) return trip.random(0.92, 1.0);
  return trip.random(1.0, 1.08);
}

function driveOpts(extra) {
  const a = trip.args;
  const o = { timeScale: trafficScale(), traffic: a.traffic !== false, realSignals: a.realSignals !== false };
  for (const k in (extra || {})) o[k] = extra[k];
  return o;
}

// ---- Leaving / arriving -------------------------------------------------------

// Leave a place: walk out of the building to the car (if inside), get in, settle, pull out.
function depart(place, fromInside) {
  const car = randomNear(place, 15, 45);
  if (fromInside) {
    phase("inside", "Leaving " + name(place), "Heading to the exit");
    trip.walk(randomNear(place, 0, 6), { speed: 1.0, jitter: 6 });
    phase("walking", "Walking to the car", name(place));
    trip.walk(car, { speed: 1.35 });
  } else {
    trip.goto(car);
  }
  phase("parked", "Getting in the car", name(place));
  trip.stay(trip.random(25, 75), { jitter: 2 });
  return car;
}

// After a drive ends at the place: roll into a parking spot and switch off.
function park(place, minM, maxM) {
  const spot = randomNear(place, minM || 25, maxM || 65);
  phase("driving", "Parking", name(place));
  trip.walk(spot, { speed: 2.5, jitter: 1 });
  phase("parked", "Parked at " + name(place), "");
  trip.stay(trip.random(20, 60), { jitter: 2 });
  return spot;
}

// Inside: short walks between spots, long stays, indoor GPS wobble. Ends near the entrance.
function goInside(place, totalMinutes, radius) {
  radius = radius || 25;
  const end = Date.now() + minutes(totalMinutes) * 1000;
  phase("walking", "Walking in", name(place), end);
  trip.walk(place, { speed: 1.3 });
  while (secondsUntil(end) > 90) {
    phase("inside", "At " + name(place), "Moving around inside", end);
    trip.walk(randomNear(place, 0, radius), { speed: trip.random(0.6, 1.0), jitter: trip.random(5, 10) });
    trip.stay(Math.min(secondsUntil(end) - 60, trip.random(minutes(3), minutes(15))), { jitter: trip.random(6, 15) });
  }
  phase("inside", "Leaving " + name(place), "Heading out", end);
  trip.walk(place, { speed: 1.1, jitter: 6 });
}

function waitInCar(place, totalMinutes) {
  const end = Date.now() + minutes(totalMinutes) * 1000;
  phase("parked", "Waiting at " + name(place), "In the car", end);
  trip.stay(minutes(totalMinutes), { jitter: 2 });
}

function backToCar(place, car) {
  phase("walking", "Walking to the car", name(place));
  trip.walk(car, { speed: 1.35 });
  phase("parked", "Getting in the car", name(place));
  trip.stay(trip.random(20, 60), { jitter: 2 });
}

// ---- Stops ----------------------------------------------------------------------

// Drive there, park, go inside (or wait in the car), come back out to the car.
function visit(place, stayMinutes, inside, radius) {
  trip.drive(place, driveOpts());
  const car = park(place);
  if (inside) {
    goInside(place, stayMinutes, radius);
    backToCar(place, car);
  } else {
    waitInCar(place, stayMinutes);
  }
  return car;
}

// Drive-thru: queue around the building, order at the speaker, pay/pick up at the window, pull out.
function driveThru(place, totalMinutes) {
  trip.drive(place, driveOpts());
  const budget = minutes(totalMinutes);
  const end = Date.now() + budget * 1000;
  const a0 = trip.random(0, 2 * Math.PI);
  const lane = [];
  for (let i = 0; i <= 10; i++) {
    const ang = a0 + i * Math.PI * 1.4 / 10;
    lane.push(offset(place, 18 * Math.cos(ang), 18 * Math.sin(ang)));
  }
  phase("drivethru", "Drive-thru: " + name(place), "In line", end);
  for (let i = 1; i <= 4; i++) {
    trip.walk(lane[i], { speed: 1.5, jitter: 1 });
    trip.stay(budget * 0.35 / 4, { jitter: 1 });
  }
  phase("drivethru", "Drive-thru: " + name(place), "Ordering", end);
  trip.walk(lane[5], { speed: 1.5, jitter: 1 });
  trip.stay(Math.max(30, budget * 0.15), { jitter: 1 });
  phase("drivethru", "Drive-thru: " + name(place), "Pulling up to the window", end);
  trip.walk(lane[7], { speed: 2, jitter: 1 });
  phase("drivethru", "Drive-thru: " + name(place), "At the window", end);
  trip.stay(Math.max(30, secondsUntil(end) - 20), { jitter: 1 });
  phase("driving", "Leaving " + name(place), "");
  trip.walk(lane[10], { speed: 3.5, jitter: 1 });
}

function gas(place, totalMinutes) {
  trip.drive(place, driveOpts());
  const end = Date.now() + minutes(totalMinutes) * 1000;
  phase("driving", "Pulling up to a pump", name(place));
  trip.walk(randomNear(place, 8, 25), { speed: 2, jitter: 1 });
  phase("parked", "Getting gas", name(place), end);
  trip.stay(minutes(totalMinutes), { jitter: 2 });
}

// A stop from the app: {lat, lon, name, kind: driveThru|quick|inside|gas, minutes}
function doStop(stop) {
  const m = stop.minutes || 5;
  if (stop.kind === "driveThru") driveThru(stop, m);
  else if (stop.kind === "gas") gas(stop, m);
  else visit(stop, m, stop.kind === "inside", 20);
}

// ---- Whole trips --------------------------------------------------------------

function leaveStart() {
  const a = trip.args;
  trip.goto(a.start);
  depart(a.start, a.startInside !== false);
}

function doStops() {
  (trip.args.stops || []).forEach(doStop);
}

// Drive back to the start (the app hands over to the real location near the handover point by itself).
function returnHome() {
  const a = trip.args;
  if (a.driveBack === false) return;
  trip.drive(a.start, driveOpts());
  park(a.start, 5, 15);
  phase("walking", "Walking inside", name(a.start));
  trip.walk(a.start, { speed: 1.2 });
  phase("parked", "Home", "");
  trip.stay(30, { jitter: 4 });
}

function finish() {
  if (trip.args.clearAtEnd) trip.clear();
}

// Nearest place matching a search near where we are, e.g. nearest("Cineplex").
function nearest(query) {
  const p = trip.find(query);
  if (!p) throw "Couldn't find " + query;
  trip.log("Picked " + query + " at " + p.lat.toFixed(4) + ", " + p.lon.toFixed(4));
  return p;
}

// Standard trip: leave start, user's stops, visit `dest`, come back.
function standardTrip(dest, stayMinutes, radius) {
  doStops();
  visit(dest, stayMinutes, trip.args.enterBuilding !== false, radius);
  returnHome();
  finish();
}
