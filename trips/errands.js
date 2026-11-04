// Errands Loop: gas -> Tim Hortons drive-thru -> pharmacy -> home.
leaveStart();
gas(nearest("gas station"), trip.random(5, 9));
driveThru(nearest("Tim Hortons"), trip.random(5, 10));
visit(nearest("pharmacy"), trip.random(10, 20), true, 20);
returnHome();
finish();
