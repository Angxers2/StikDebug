// Grocery Run: nearest grocery store, 25-40 min of aisles.
const a = trip.args;
startAtHome(a.home);
visit(nearest("grocery store"), trip.random(25, 40), 35);
driveHome(a.home);
finish(a);
