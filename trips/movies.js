// Movie Night: nearest Cineplex, ads + movie ~2.5h, then home.
const a = trip.args;
startAtHome(a.home);
const theatre = nearest("Cineplex");
visit(theatre, trip.random(140, 165), 15);
driveHome(a.home);
finish(a);
