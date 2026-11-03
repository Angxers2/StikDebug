// Mall Hangout: nearest shopping mall, 2-3h, wanders a lot.
const a = trip.args;
startAtHome(a.home);
visit(nearest("shopping mall"), trip.random(120, 180), 120);
driveHome(a.home);
finish(a);
