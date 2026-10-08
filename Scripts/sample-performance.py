#!/usr/bin/env python3
"""Read-only process CPU/RSS sampling. No screen capture and no input events."""
import datetime, json, statistics, subprocess, sys, time
from pathlib import Path

label = sys.argv[1] if len(sys.argv) > 1 else 'idle'
duration = max(5, min(60, int(sys.argv[2]) if len(sys.argv) > 2 else 30))
root = Path(__file__).resolve().parent.parent / 'Verification'
names = {'WindowPin', 'WindowServer', 'replayd', 'VideoCaptureService', 'ControlCenter', 'Fixture', 'SkyComputerUseService'}

def cpu_seconds(value):
    day = 0
    if '-' in value:
        days, value = value.split('-', 1); day = int(days) * 86400
    parts = list(map(float, value.split(':')))
    total = 0
    for part in parts: total = total * 60 + part
    return day + total

def sample():
    data = subprocess.check_output(['ps', '-axo', 'pid=,time=,rss=,comm='], text=True)
    rows = {}
    for line in data.splitlines():
        values = line.strip().split(None, 3)
        if len(values) != 4: continue
        pid, cpu, rss, path = values
        name = Path(path).name
        if name in names:
            rows[int(pid)] = {'name': name, 'path': path, 'cpuSeconds': cpu_seconds(cpu), 'rssKiB': int(rss)}
    return {'time': time.monotonic(), 'processes': rows}

samples = [sample()]
for _ in range(duration):
    time.sleep(1)
    samples.append(sample())
summary = []
for pid, row in samples[-1]['processes'].items():
    intervals = []
    for previous, current in zip(samples, samples[1:]):
        if pid not in previous['processes'] or pid not in current['processes']: continue
        delta = current['processes'][pid]['cpuSeconds'] - previous['processes'][pid]['cpuSeconds']
        intervals.append(max(0, delta) * 100 / (current['time'] - previous['time']))
    if intervals:
        summary.append({'pid': pid, 'name': row['name'], 'cpuMeanPercentOneCore': round(statistics.mean(intervals), 2),
                        'cpuPeakPercentOneCore': round(max(intervals), 2), 'finalRssMiB': round(row['rssKiB']/1024, 2)})
result = {'label': label, 'date': datetime.datetime.now().astimezone().isoformat(), 'seconds': duration,
          'cpuBasis': 'CPU-time delta over wall time; 100 percent = one core',
          'note': 'Other desktop workloads are uncontrolled; system process cost is not solely attributable to WindowPin.',
          'summary': summary, 'samples': samples}
output = root / f'performance-{label}-{datetime.datetime.now():%Y%m%d-%H%M%S}.json'
output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps({'file': str(output), 'summary': summary}, ensure_ascii=False, indent=2))
