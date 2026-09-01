#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
from __future__ import annotations
import argparse
import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path
OLLAMA = os.environ.get('OLLAMA_URL', 'http://127.0.0.1:11434').rstrip('/')
WEBUI = os.environ.get('WEBUI_URL', 'http://127.0.0.1:3000').rstrip('/')
DEFAULT_MODEL = os.environ.get('LOCAL_AI_MODEL', 'huihui_ai/Qwen3.8-abliterated')
DB = Path.home() / '.open-webui' / 'webui.db'
STATE = Path.home() / '.local' / 'state' / 'local-ai'
BENCH = STATE / 'benchmarks.jsonl'
STATE.mkdir(parents=True, exist_ok=True)
C_RESET = '\x1b[0m'
C_GREEN = '\x1b[32m'
C_RED = '\x1b[31m'
C_YELLOW = '\x1b[33m'
C_CYAN = '\x1b[36m'
C_DIM = '\x1b[2m'

def c(text, color):
    return f'{color}{text}{C_RESET}' if sys.stdout.isatty() else text

def human_bytes(n):
    if n is None:
        return 'n/a'
    try:
        n = float(n)
    except Exception:
        return 'n/a'
    units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
    idx = 0
    while abs(n) >= 1024 and idx < len(units) - 1:
        n /= 1024.0
        idx += 1
    return f'{n:.1f} {units[idx]}'

def fmt_rate(value, unit='tok/s'):
    if value is None:
        return 'n/a'
    return f'{value:.2f} {unit}'

def normalize_model_name(name):
    name = (name or '').strip()
    if name.endswith(':latest'):
        name = name[:-7]
    return name

def same_model(a, b):
    return normalize_model_name(a) == normalize_model_name(b)

def api(path, method='GET', payload=None, timeout=10):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(OLLAMA + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read()
    return json.loads(body.decode()) if body else {}

def webui_status(timeout=3):
    try:
        with urllib.request.urlopen(WEBUI + '/health', timeout=min(timeout, 1.5)) as r:
            if 200 <= r.status < 300:
                return (True, f'/health={r.status}')
    except Exception:
        pass
    try:
        with urllib.request.urlopen(WEBUI + '/', timeout=timeout) as r:
            if 200 <= r.status < 400:
                return (True, f'/={r.status} (health endpoint unavailable)')
            return (False, f'/={r.status}')
    except Exception:
        return (False, 'unreachable')

def webui_health(timeout=3):
    return webui_status(timeout)[0]

def service_state(name):
    try:
        p = subprocess.run(['systemctl', 'is-active', name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
        return p.stdout.strip() or 'unknown'
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown'

def find_nvidia_smi():
    candidates = [shutil.which('nvidia-smi'), '/usr/lib/wsl/lib/nvidia-smi', '/usr/bin/nvidia-smi', '/usr/local/bin/nvidia-smi']
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None

def nvidia_row():
    exe = find_nvidia_smi()
    if exe is None:
        return None
    p = subprocess.run([exe, '--query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total,temperature.gpu', '--format=csv,noheader,nounits'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    vals = [v.strip() for v in p.stdout.splitlines()[0].split(',')]
    if len(vals) < 6:
        return None
    power = 'n/a'
    power_result = subprocess.run([exe, '--query-gpu=power.draw', '--format=csv,noheader,nounits'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if power_result.returncode == 0 and power_result.stdout.strip():
        power = power_result.stdout.splitlines()[0].strip()
    return {'name': vals[0], 'driver': vals[1], 'util': vals[2], 'vram_used': vals[3], 'vram_total': vals[4], 'temp': vals[5], 'power': power}

def meminfo():
    vals = {}
    try:
        with open('/proc/meminfo', 'r', encoding='utf-8') as fh:
            for line in fh:
                key, rest = line.split(':', 1)
                vals[key] = int(rest.strip().split()[0]) * 1024
    except Exception:
        return {}
    total = vals.get('MemTotal', 0)
    avail = vals.get('MemAvailable', 0)
    swap_total = vals.get('SwapTotal', 0)
    swap_free = vals.get('SwapFree', 0)
    return {'total': total, 'available': avail, 'used': max(0, total - avail), 'swap_total': swap_total, 'swap_used': max(0, swap_total - swap_free)}

def get_models():
    try:
        return api('/api/tags', timeout=5).get('models', [])
    except Exception:
        return []

def get_running():
    try:
        return api('/api/ps', timeout=5).get('models', [])
    except Exception:
        return []

def get_capabilities(model):
    """Return Ollama-reported capabilities for a model without failing the listing."""
    try:
        details = api('/api/show', method='POST', payload={'name': model}, timeout=8)
        caps = details.get('capabilities', [])
        return {str(x).strip().lower() for x in caps if str(x).strip()}
    except Exception:
        return set()

def health():
    print(c('JYNERATION // HEALTH CHECK', C_CYAN))
    print('=' * 64)
    checks = []
    advisories = []
    webui_enabled = os.environ.get('LOCAL_AI_OPEN_WEBUI_ENABLED', '1').strip().lower() not in {'0', 'false', 'no', 'off'}
    ollama_state = service_state('ollama.service')
    webui_state = service_state('open-webui.service') if webui_enabled else 'disabled'
    checks.append(('Ollama systemd', ollama_state == 'active', ollama_state))
    if webui_enabled:
        checks.append(('Open WebUI systemd', webui_state == 'active', webui_state))
    else:
        advisories.append(('Open WebUI systemd', True, 'disabled in profile'))
    try:
        tags = api('/api/tags', timeout=3)
        ollama_ok = True
        model_count = len(tags.get('models', []))
    except Exception:
        ollama_ok = False
        model_count = 0
    checks.append(('Ollama API :11434', ollama_ok, f'{model_count} model(s)' if ollama_ok else 'unreachable'))
    if webui_enabled:
        ow_ok, ow_detail = webui_status()
        checks.append(('Open WebUI :3000', ow_ok, ow_detail))
    else:
        ow_ok = False
        advisories.append(('Open WebUI :3000', True, 'disabled in profile'))
    gpu = nvidia_row()
    advisories.append(('NVIDIA GPU', gpu is not None, gpu['name'] if gpu else 'not detected (optional)'))
    mem = meminfo()
    if mem:
        free_gib = mem['available'] / 1024 ** 3
        checks.append(('WSL available RAM', free_gib >= 6, f'{free_gib:.1f} GiB available'))
    running = get_running()
    for m in running:
        name = m.get('name') or m.get('model') or '(unknown)'
        size = m.get('size') or 0
        size_vram = m.get('size_vram') or 0
        pct = size_vram / size * 100 if size else None
        detail = f'{human_bytes(size_vram)} VRAM' + (f' ({pct:.0f}% GPU-resident)' if pct is not None else '') + f", ctx {m.get('context_length', 'n/a')}"
        advisories.append((f'Model: {name}', pct is None or pct >= 90, detail))
    for label, ok, detail in checks + advisories:
        mark = c('PASS', C_GREEN) if ok else c('WARN', C_YELLOW)
        print(f'{mark:>13}  {label:<24} {detail}')
    print()
    if gpu:
        print(f"GPU: {gpu['util']}% util | {gpu['vram_used']} / {gpu['vram_total']} MiB VRAM | {gpu['temp']} C | {gpu['power']} W")
    if mem:
        print(f"RAM: {human_bytes(mem['used'])} used / {human_bytes(mem['total'])} | {human_bytes(mem['available'])} available | swap {human_bytes(mem['swap_used'])}")
    failed = [x for x in checks if not x[1]]
    if failed:
        print()
        print(c('Suggested next checks:', C_YELLOW))
        if ollama_state != 'active':
            print('  journalctl -u ollama.service -n 100 --no-pager')
        if webui_enabled and (webui_state != 'active' or not ow_ok):
            print('  journalctl -u open-webui.service -n 150 --no-pager')
        if mem and mem['available'] < 6 * 1024 ** 3:
            print('  Stop unused models/services or use Stop-Local-AI.bat to terminate WSL.')
        return 1
    print()
    print(c('Everything important is healthy.', C_GREEN))
    return 0

def models():
    installed = get_models()
    running = {normalize_model_name(m.get('name') or m.get('model')): m for m in get_running()}
    print(c('INSTALLED OLLAMA MODELS', C_CYAN))
    print('=' * 88)
    if not installed:
        print('No models returned by Ollama.')
        return
    print(f"{'MODEL':40} {'SIZE':>10} {'PARAMS':>9} {'QUANT':>10} {'CAPABILITIES':20} {'STATE':>10}")
    print('-' * 106)
    for m in installed:
        name = m.get('name') or m.get('model') or '(unknown)'
        d = m.get('details') or {}
        state = 'LOADED' if normalize_model_name(name) in running else ''
        caps = get_capabilities(name)
        cap_text = ','.join(x for x in ('tools', 'vision', 'completion') if x in caps) or 'unknown'
        print(f"{name[:40]:40} {human_bytes(m.get('size')):>10} {str(d.get('parameter_size', '')):>9} {str(d.get('quantization_level', '')):>10} {cap_text[:20]:20} {state:>10}")
        if caps and 'tools' not in caps:
            print('  WARN: Pi tool workflow may be unavailable for this model (Ollama did not report tools support).')
    if running:
        print()
        print(c('RUNNING / RESIDENT', C_CYAN))
        for name, m in running.items():
            size = m.get('size') or 0
            vram = m.get('size_vram') or 0
            pct = vram / size * 100 if size else 0
            print(f"{name}: {human_bytes(vram)} VRAM, {pct:.0f}% GPU-resident, context {m.get('context_length', 'n/a')}")

def manage_models():
    while True:
        print('\x1b[2J\x1b[H', end='')
        models()
        print()
        print('[P] Pull model   [D] Delete model   [S] Stop/unload model   [Q] Quit')
        choice = input('Choose: ').strip().lower()
        if choice == 'q':
            return
        if choice not in {'p', 'd', 's'}:
            continue
        name = input('Model name: ').strip()
        if not name:
            continue
        if choice == 'p':
            subprocess.run(['ollama', 'pull', name])
            input('\nPress Enter...')
        elif choice == 's':
            subprocess.run(['ollama', 'stop', name])
            input('\nPress Enter...')
        elif choice == 'd':
            confirm = input(f'Type DELETE to remove {name}: ').strip()
            if confirm == 'DELETE':
                subprocess.run(['ollama', 'rm', name])
            input('\nPress Enter...')

def usage_obj(raw):
    if raw is None:
        return {}
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8', 'replace')
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            return {}
    return raw if isinstance(raw, dict) else {}

def as_int(value):
    try:
        return int(value or 0)
    except Exception:
        return 0

def as_float(value):
    try:
        return float(value)
    except Exception:
        return 0.0

def token_pair(u):
    inp = as_int(u.get('input_tokens', u.get('prompt_tokens', u.get('prompt_eval_count', 0))))
    out = as_int(u.get('output_tokens', u.get('completion_tokens', u.get('eval_count', 0))))
    reasoning = as_int(u.get('reasoning_tokens'))
    for key in ('output_tokens_details', 'completion_tokens_details'):
        details = u.get(key)
        if isinstance(details, dict):
            reasoning = max(reasoning, as_int(details.get('reasoning_tokens')))
    return (inp, out, reasoning)

def norm_ts(value):
    if isinstance(value, dt.datetime):
        return value.timestamp()
    if isinstance(value, str):
        text = value.strip()
        if text:
            try:
                parsed = dt.datetime.fromisoformat(text.replace('Z', '+00:00'))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=dt.datetime.now().astimezone().tzinfo)
                return parsed.timestamp()
            except ValueError:
                pass
    try:
        value = float(value)
    except Exception:
        return None
    if value > 100000000000000.0:
        value /= 1000000
    elif value > 100000000000.0:
        value /= 1000
    return value

def load_usage_rows(retries=3, retry_delay=0.4):
    if not DB.exists():
        raise FileNotFoundError(f'Open WebUI database not found: {DB}')
    last_exc = None
    for attempt in range(retries):
        con = None
        try:
            con = sqlite3.connect(f'file:{DB}?mode=ro', uri=True, timeout=5)
            con.row_factory = sqlite3.Row
            tables = {r['name'] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if 'chat_message' not in tables:
                raise RuntimeError('chat_message table does not exist yet.')
            rows = list(con.execute("\n                    SELECT model_id, usage, created_at\n                    FROM chat_message\n                    WHERE role='assistant' AND usage IS NOT NULL\n                    ORDER BY created_at\n                    "))
            return rows
        except sqlite3.OperationalError as exc:
            last_exc = exc
            if 'locked' in str(exc).lower() and attempt < retries - 1:
                time.sleep(retry_delay)
                continue
            raise
        finally:
            if con is not None:
                con.close()
    raise last_exc

def agg(rows, cutoff=None):
    total = {'in': 0, 'out': 0, 'reasoning': 0, 'count': 0, 'metered': 0, 'unmetered': 0, 'eval_ns': 0.0}
    by_model = defaultdict(lambda: {'in': 0, 'out': 0, 'reasoning': 0, 'count': 0, 'metered': 0, 'unmetered': 0, 'eval_ns': 0.0})
    last = None
    for r in rows:
        ts = norm_ts(r['created_at'])
        if cutoff is not None and (ts is None or ts < cutoff):
            continue
        u = usage_obj(r['usage'])
        inp, out, reasoning = token_pair(u)
        model = r['model_id'] or '(unknown)'
        eval_ns = as_float(u.get('eval_duration'))
        metered = bool(u) and (inp > 0 or out > 0 or reasoning > 0)
        for obj in (total, by_model[model]):
            obj['in'] += inp
            obj['out'] += out
            obj['reasoning'] += reasoning
            obj['count'] += 1
            obj['metered' if metered else 'unmetered'] += 1
            obj['eval_ns'] += eval_ns
        last = (model, inp, out, reasoning, u, ts)
    return (total, by_model, last)

def tps(out, ns):
    return out / (ns / 1000000000.0) if ns else None

def print_latest(last):
    model, inp, out, reasoning, u, _ts = last
    print()
    print('Latest response')
    print('-' * 84)
    print(f'model: {model}')
    if not u or (inp == 0 and out == 0 and reasoning == 0):
        print('usage: unavailable (the provider did not return token metadata)')
        return
    print(f'input: {inp:,} | output: {out:,} | reasoning: {reasoning:,}')
    prompt_dur = as_float(u.get('prompt_eval_duration'))
    prompt_rate = inp / (prompt_dur / 1000000000.0) if prompt_dur else None
    if prompt_rate is not None:
        print(f'prompt speed: {fmt_rate(prompt_rate)}')
    eval_dur = as_float(u.get('eval_duration'))
    gen_rate = out / (eval_dur / 1000000000.0) if eval_dur else None
    if gen_rate is not None:
        print(f'generation: {fmt_rate(gen_rate)}')

def tokens(days=7, live=False, interval=2):
    while True:
        if live:
            print('\x1b[2J\x1b[H', end='')
        try:
            rows = load_usage_rows()
            now = time.time()
            print(c('OPEN WEBUI TOKEN USAGE', C_CYAN))
            print('=' * 84)
            for label, cutoff in [('24 hours', now - 86400), ('7 days', now - 7 * 86400), ('30 days', now - 30 * 86400), ('All time', None)]:
                a, _, _ = agg(rows, cutoff)
                rate = tps(a['out'], a['eval_ns'])
                meter = f"metered {a['metered']:,}"
                if a['unmetered']:
                    meter += f" / unavailable {a['unmetered']:,}"
                print(f"{label:<10} in {a['in']:>11,} | out {a['out']:>11,} | total {a['in'] + a['out']:>11,} | responses {a['count']:>6,} | {meter} | {fmt_rate(rate)}")
            cutoff = now - days * 86400 if days > 0 else None
            _a, by_model, last = agg(rows, cutoff)
            print()
            print(f'Per model, last {days:g} day(s)')
            print('-' * 84)
            for model, x in sorted(by_model.items(), key=lambda kv: kv[1]['in'] + kv[1]['out'], reverse=True):
                rate = tps(x['out'], x['eval_ns'])
                meter = f"metered {x['metered']:,}"
                if x['unmetered']:
                    meter += f" / unavailable {x['unmetered']:,}"
                print(f"{model}\n  input {x['in']:,} | output {x['out']:,} | total {x['in'] + x['out']:,} | reasoning {x['reasoning']:,} | responses {x['count']:,} | {meter} | {fmt_rate(rate)}")
            if last:
                print_latest(last)
        except FileNotFoundError as exc:
            print(c(str(exc), C_YELLOW))
        except Exception as exc:
            print(c(f'Token report error: {exc}', C_RED))
        if not live:
            return
        time.sleep(max(0.5, interval))

def model_is_loaded(model):
    running = get_running()
    return any((same_model(m.get('name') or m.get('model'), model) for m in running))

def benchmark(model, num_ctx=8192, runs=3, output_tokens=128):
    if not model or not model.strip():
        print(c('Model name cannot be empty.', C_RED))
        return 2
    if not 512 <= int(num_ctx) <= 262144:
        print(c('num_ctx must be between 512 and 262144.', C_RED))
        return 2
    if not 1 <= int(runs) <= 20:
        print(c('runs must be between 1 and 20.', C_RED))
        return 2
    if not 1 <= int(output_tokens) <= 4096:
        print(c('output_tokens must be between 1 and 4096.', C_RED))
        return 2
    prompt = "Explain why increasing an LLM's context window increases KV-cache memory usage. Be technically precise, use exactly four short paragraphs, and do not use bullet points."
    print(c('OLLAMA BENCHMARK', C_CYAN))
    print('=' * 72)
    print(f'model       : {model}')
    print(f'num_ctx     : {num_ctx:,}')
    print(f'runs        : {runs}')
    print(f'output cap  : {output_tokens}')
    print()
    print('Warmup...')
    try:
        api('/api/generate', method='POST', payload={'model': model, 'prompt': 'Reply with the single word ready.', 'stream': False, 'keep_alive': '10m', 'options': {'num_ctx': num_ctx, 'num_predict': 8}}, timeout=180)
    except Exception as exc:
        print(c(f'Warmup failed: {exc}', C_RED))
        return 1
    results = []
    for idx in range(1, runs + 1):
        if not model_is_loaded(model):
            print(c(f'  model was evicted before run {idx}, reloading...', C_YELLOW))
            try:
                api('/api/generate', method='POST', payload={'model': model, 'prompt': 'Reply with the single word ready.', 'stream': False, 'keep_alive': '10m', 'options': {'num_ctx': num_ctx, 'num_predict': 8}}, timeout=180)
            except Exception as exc:
                print(c(f'  reload failed: {exc}, skipping run {idx}', C_RED))
                continue
        gpu_before = nvidia_row()
        ram_before = meminfo()
        started = time.time()
        try:
            r = api('/api/generate', method='POST', payload={'model': model, 'prompt': prompt, 'stream': False, 'keep_alive': '10m', 'options': {'num_ctx': num_ctx, 'num_predict': output_tokens, 'temperature': 0.2, 'seed': 42}}, timeout=600)
        except Exception as exc:
            print(c(f'Run {idx} failed: {exc}', C_RED))
            continue
        wall = time.time() - started
        pin = as_int(r.get('prompt_eval_count'))
        pout = as_int(r.get('eval_count'))
        pd = as_float(r.get('prompt_eval_duration'))
        ed = as_float(r.get('eval_duration'))
        load = as_float(r.get('load_duration'))
        prompt_tps = pin / (pd / 1000000000.0) if pd else None
        output_tps = pout / (ed / 1000000000.0) if ed else None
        running = get_running()
        rm = next((m for m in running if same_model(m.get('name') or m.get('model'), model)), None)
        size_vram = rm.get('size_vram') if rm else None
        ctx_live = rm.get('context_length') if rm else None
        row = {'timestamp': dt.datetime.now().astimezone().isoformat(), 'model': model, 'num_ctx': num_ctx, 'run': idx, 'prompt_tokens': pin, 'output_tokens': pout, 'prompt_tps': prompt_tps, 'output_tps': output_tps, 'wall_seconds': wall, 'load_seconds': load / 1000000000.0 if load else None, 'size_vram': size_vram, 'context_length_live': ctx_live, 'gpu_before': gpu_before, 'ram_before_available': ram_before.get('available') if ram_before else None}
        results.append(row)
        print(f'run {idx}: prompt {pin:,} @ {fmt_rate(prompt_tps)} | output {pout:,} @ {fmt_rate(output_tps)} | wall {wall:.2f}s | VRAM {human_bytes(size_vram)}')
    if not results:
        print(c('No successful runs; nothing recorded.', C_RED))
        return 1
    with BENCH.open('a', encoding='utf-8') as fh:
        for row in results:
            fh.write(json.dumps(row, ensure_ascii=False) + '\n')

    def avg(key):
        vals = [r[key] for r in results if r.get(key) is not None]
        return sum(vals) / len(vals) if vals else None
    print()
    print(c('SUMMARY', C_CYAN))
    print('-' * 72)
    pavg = avg('prompt_tps')
    oavg = avg('output_tps')
    wavg = avg('wall_seconds')
    if pavg is not None:
        print(f'average prompt processing : {fmt_rate(pavg)}')
    if oavg is not None:
        print(f'average generation        : {fmt_rate(oavg)}')
    if wavg is not None:
        print(f'average wall time         : {wavg:.2f} s')
    print(f'successful runs            : {len(results)}/{runs}')
    print(f'saved history              : {BENCH}')
    return 0

def benchmark_history(limit=20):
    limit = max(1, min(int(limit), 1000))
    if not BENCH.exists():
        print('No benchmark history yet.')
        return
    rows = []
    for line in BENCH.read_text(encoding='utf-8').splitlines():
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    print(c('BENCHMARK HISTORY', C_CYAN))
    print('=' * 100)
    print(f"{'TIME':19} {'MODEL':34} {'CTX':>8} {'PROMPT':>12} {'OUTPUT':>12} {'VRAM':>10}")
    print('-' * 100)
    for r in rows[-limit:]:
        ts = r.get('timestamp', '')[:19].replace('T', ' ')
        model = str(r.get('model', ''))[:34]
        ctx = r.get('num_ctx')
        pt = r.get('prompt_tps')
        ot = r.get('output_tps')
        print(f"{ts:19} {model:34} {(ctx if ctx is not None else ''):>8} {(fmt_rate(pt) if pt is not None else 'n/a'):>12} {(fmt_rate(ot) if ot is not None else 'n/a'):>12} {human_bytes(r.get('size_vram')):>10}")

def dashboard():
    while True:
        print('\x1b[2J\x1b[H', end='')
        print(c('JYNERATION // DASHBOARD', C_CYAN))
        print('=' * 86)
        print(dt.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z'))
        print()
        print(f"Ollama: {service_state('ollama.service')} | Open WebUI: {service_state('open-webui.service')} | WebUI health: {('OK' if webui_health() else 'FAIL')}")
        running = get_running()
        if running:
            print()
            print('MODELS')
            for m in running:
                name = m.get('name') or m.get('model')
                size = m.get('size') or 0
                vram = m.get('size_vram') or 0
                pct = vram / size * 100 if size else 0
                print(f"{name}: {human_bytes(vram)} VRAM | {pct:.0f}% GPU | ctx {m.get('context_length', 'n/a')}")
        gpu = nvidia_row()
        if gpu:
            print()
            print(f"GPU: {gpu['name']} | {gpu['util']}% util | {gpu['vram_used']}/{gpu['vram_total']} MiB | {gpu['temp']} C | {gpu['power']} W")
        mem = meminfo()
        if mem:
            print(f"RAM: {human_bytes(mem['used'])}/{human_bytes(mem['total'])} | {human_bytes(mem['available'])} available | swap {human_bytes(mem['swap_used'])}")
        try:
            rows = load_usage_rows()
            a, _, _ = agg(rows, time.time() - 86400)
            print()
            print(f"TODAY: {a['in']:,} input + {a['out']:,} output = {a['in'] + a['out']:,} tokens across {a['count']:,} responses")
        except Exception:
            pass
        print()
        print(c('Ctrl+C closes dashboard only. Services keep running.', C_DIM))
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            return

def main():
    ap = argparse.ArgumentParser(description='JYNERATION runtime utility suite')
    sp = ap.add_subparsers(dest='cmd', required=True)
    sp.add_parser('health')
    sp.add_parser('models')
    sp.add_parser('manage-models')
    p = sp.add_parser('tokens')
    p.add_argument('--days', type=float, default=7)
    p.add_argument('--live', action='store_true')
    p.add_argument('--interval', type=float, default=2)
    p = sp.add_parser('benchmark')
    p.add_argument('--model', default=DEFAULT_MODEL)
    p.add_argument('--num-ctx', type=int, default=8192)
    p.add_argument('--runs', type=int, default=3)
    p.add_argument('--output-tokens', type=int, default=128)
    p = sp.add_parser('benchmark-history')
    p.add_argument('--limit', type=int, default=20)
    sp.add_parser('dashboard')
    args = ap.parse_args()
    if args.cmd == 'health':
        sys.exit(health())
    elif args.cmd == 'models':
        models()
    elif args.cmd == 'manage-models':
        manage_models()
    elif args.cmd == 'tokens':
        tokens(args.days, args.live, args.interval)
    elif args.cmd == 'benchmark':
        sys.exit(benchmark(args.model, args.num_ctx, args.runs, args.output_tokens))
    elif args.cmd == 'benchmark-history':
        benchmark_history(args.limit)
    elif args.cmd == 'dashboard':
        dashboard()
if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
