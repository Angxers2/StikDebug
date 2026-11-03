// Errands Loop: gas -> coffee -> pharmacy -> home.
const a = trip.args;
startAtHome(a.home);
visit(nearest("gas station"), trip.random(6, 10), 10);
visit(nearest("Tim Hortons"), trip.random(10, 20), 10);
visit(nearest("pharmacy"), trip.random(10, 20), 20);
driveHome(a.home);
finish(a);
