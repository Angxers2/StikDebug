// Runs every preset (+ walk.js) against a mock `trip` with a fake clock; fails on any script error.
const fs = require('fs'), dir = process.argv[2];
let now = 0; Date.now = () => now;
const files = JSON.parse(fs.readFileSync(dir + '/index.json')).map(p => p.file).concat(['walk.js']);
for (const file of files) {
  now = 0; const calls = [];
  const P = (lat, lon, name) => ({ lat, lon, name });
  const check = p => { if (!p || isNaN(p.lat) || isNaN(p.lon)) throw file + ': bad place ' + JSON.stringify(p); };
  const trip = {
    args: { start: P(43.7, -79.7, 'Home'), home: P(43.7, -79.7, 'Home'), dest: P(43.65, -79.38, 'Dest'),
            stops: [{ ...P(43.68, -79.5, 'Tims'), kind: 'driveThru', minutes: 8 }, { ...P(43.67, -79.45, 'Esso'), kind: 'gas', minutes: 6 },
                    { ...P(43.66, -79.42, 'Store'), kind: 'inside', minutes: 15 }, { ...P(43.66, -79.41, 'Pickup'), kind: 'quick', minutes: 4 }],
            stayMinutes: 120, startInside: true, enterBuilding: true, driveBack: true, clearAtEnd: true, realWithin: 300,
            path: [P(43.7, -79.7), P(43.701, -79.701), P(43.702, -79.7)], walkSpeed: 1.4, walkLoop: false },
    goto: p => { check(p); calls.push('goto'); }, drive: (p, o) => { check(p); calls.push('drive'); now += 900e3; },
    walk: p => { check(p); now += 30e3; }, walkPath: ps => { ps.forEach(check); calls.push('walkPath'); now += 120e3; },
    stay: s => { if (!(s >= 0)) throw file + ': bad stay ' + s; now += s * 1000; },
    activity: o => { if (!o.phase) throw file + ': activity without phase'; },
    wait: s => now += s * 1000, clear: () => calls.push('clear'),
    find: q => P(43.6, -79.6, q), here: () => null, cancelled: () => false,
    random: (a, b) => a + Math.random() * (b - a), hour: () => 17, log() {}, status() {},
  };
  new Function('trip', fs.readFileSync(dir + '/lib.js', 'utf8') + '\n;\n' + fs.readFileSync(dir + '/' + file, 'utf8'))(trip);
  if (calls.at(-1) !== 'clear') throw file + ': does not end with clear: ' + calls;
  console.log('ok', file.padEnd(14), String(Math.round(now / 60000)).padStart(4) + ' min', calls.join(' '));
}
