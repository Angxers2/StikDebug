// Gym Session: nearest gym, ~1h-1h30.
const a = trip.args;
startAtHome(a.home);
visit(nearest("gym"), trip.random(60, 90), 20);
driveHome(a.home);
finish(a);
