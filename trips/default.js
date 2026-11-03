// Quick Trip: Home -> picked destination -> stay -> (drive back) -> (real location).
const a = trip.args;
startAtHome(a.home);
visit(a.dest, a.stayMinutes);
if (a.driveBack) driveHome(a.home);
finish(a);
