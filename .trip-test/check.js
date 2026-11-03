// Runs every preset against a mock `trip` with a fake clock; fails on any script error.
const fs = require('fs'), dir = process.argv[2];
let now = 0; Date.now = () => now;
for (const { file } of JSON.parse(fs.readFileSync(dir + '/index.json'))) {
  now = 0; const calls = [];
  const trip = {
    args: { home: { lat: 43.7, lon: -79.7, name: 'Home' }, dest: { lat: 43.65, lon: -79.38, name: 'Dest' },
            stayMinutes: 120, driveBack: true, clearAtEnd: true },
    goto: p => calls.push('goto'), drive: p => { calls.push('drive'); now += 900e3; },
    walk: p => { if (isNaN(p.lat)) throw 'bad walk'; now += 30e3; },
    stay: s => { if (!(s >= 0)) throw 'bad stay ' + s; now += s * 1000; },
    wait: s => now += s * 1000, clear: () => calls.push('clear'),
    find: q => ({ lat: 43.6, lon: -79.6, name: q }), here: () => null,
    random: (a, b) => a + Math.random() * (b - a), hour: () => 17, log() {}, status() {},
  };
  new Function('trip', fs.readFileSync(dir + '/lib.js', 'utf8') + '\n;\n' + fs.readFileSync(dir + '/' + file, 'utf8'))(trip);
  if (calls.at(-1) !== 'clear' || !calls.includes('drive')) throw file + ': bad sequence ' + calls;
  console.log('ok', file, Math.round(now / 60000) + ' min simulated', calls.join(' '));
}
