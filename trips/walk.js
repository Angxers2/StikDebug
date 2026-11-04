// Walk a path drawn in the app (loops if "Loop" is on).
const a = trip.args;
trip.goto(a.path[0]);
const labels = { 0.9: "Strolling", 1.4: "Walking", 2.8: "Jogging", 5.5: "Biking" };
do {
  phase("walking", labels[a.walkSpeed] || "Walking", "Following your path");
  trip.walkPath(a.path, { speed: a.walkSpeed * trip.random(0.92, 1.08), jitter: 2 });
} while (a.walkLoop && !trip.cancelled());
phase("parked", "Done walking", "");
finish();
