import { exec, toast } from 'kernelsu';

const MODDIR = '/data/adb/modules/ir_blast';
const CFG = `${MODDIR}/ir_blast/config.json`;
const CTL = `${MODDIR}/ir_blast/ctl.sh`;

// ---- tiny helpers ---------------------------------------------------------
const $ = (id) => document.getElementById(id);
let toastTimer = 0;
function showToast(msg, kind = '') {
  const el = $('toast');
  el.textContent = msg;
  el.className = `toast show ${kind}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.className = 'toast'; }, 2600);
}
function run(cmd) {
  // exec returns {errno, stdout}; fall back gracefully for older shapes
  const r = exec(cmd) || {};
  return { errno: (r.errno !== undefined ? r.errno : r.code), stdout: r.stdout || '' };
}

// ---- config <-> form -----------------------------------------------------
const KEYS = [
  ['host', 'server', 'host'], ['port', 'server', 'port'],
  ['auth_header', 'server', 'auth_header'], ['auth_value', 'server', 'auth_value'],
  ['backend', 'ir', 'backend'], ['carrier', 'ir', 'carrier'],
  ['repeat', 'ir', 'repeat'], ['timeout_ms', 'ir', 'timeout_ms'],
  ['gpio', 'ir', 'gpio'], ['active_high', 'ir', 'active_high'],
  ['irctl_path', 'ir', 'irctl_path'], ['lirc_device', 'ir', 'lirc_device'],
  ['command', 'ir', 'command'],
  ['ir_spi_device', 'ir', 'ir_spi_device'],
  ['ir_spi_mode', 'ir', 'ir_spi_mode'],
  ['ir_spi_carrier_sysfs', 'ir', 'ir_spi_carrier_sysfs'],
  ['python', 'daemon', 'python'], ['max_body_bytes', 'daemon', 'max_body_bytes'],
];

function getVal(cfg, sec, key, def) {
  const v = (cfg[sec] || {})[key];
  return v === undefined || v === null ? def : v;
}

function fillForm(cfg) {
  const defaults = {
    host: '0.0.0.0', port: 8424, auth_header: 'X-IR-Token', auth_value: '',
    backend: 'command', carrier: 38000, repeat: 1, timeout_ms: 5000,
    gpio: 17, active_high: true, irctl_path: 'ir-ctl', lirc_device: '/dev/lirc0',
    command: 'echo "carrier=$IR_CARRIER timings=$IR_TIMINGS_CSV rawfile=$IR_RAWFILE repeat=$IR_REPEAT"',
    ir_spi_device: '/dev/ir_spi', ir_spi_mode: 'auto', ir_spi_carrier_sysfs: '',
    python: '/data/data/com.termux/files/usr/bin/python3', max_body_bytes: 65536,
  };
  for (const [id, sec, key] of KEYS) {
    const v = getVal(cfg, sec, key, defaults[id]);
    const el = $(id);
    if (!el) continue;
    el.value = (typeof v === 'boolean') ? String(v) : v;
  }
}

function readForm() {
  const num = (id) => { const n = parseInt($(id).value, 10); return isNaN(n) ? undefined : n; };
  const cfg = {
    server: {
      host: $('host').value || '0.0.0.0',
      port: num('port') ?? 8424,
      auth_header: $('auth_header').value || 'X-IR-Token',
      auth_value: $('auth_value').value || '',
    },
    ir: {
      backend: $('backend').value,
      carrier: num('carrier') ?? 38000,
      repeat: num('repeat') ?? 1,
      timeout_ms: num('timeout_ms') ?? 5000,
      irctl_path: $('irctl_path').value || 'ir-ctl',
      lirc_device: $('lirc_device').value || '/dev/lirc0',
      gpio: num('gpio') ?? 17,
      active_high: $('active_high').value === 'true',
      command: $('command').value || '',
      ir_spi_device: $('ir_spi_device').value || '/dev/ir_spi',
      ir_spi_mode: $('ir_spi_mode').value || 'auto',
      ir_spi_carrier_sysfs: $('ir_spi_carrier_sysfs').value || '',
    },
    daemon: {
      python: $('python').value || '/data/data/com.termux/files/usr/bin/python3',
      max_body_bytes: num('max_body_bytes') ?? 65536,
    },
  };
  return cfg;
}

// ---- actions -------------------------------------------------------------
async function loadConfig() {
  const { errno, stdout } = run(`cat ${CFG}`);
  if (errno !== 0 || !stdout.trim()) {
    showToast('설정 불러오기 실패', 'err');
    $('status').innerHTML = '상태: <span class="badge off">설정 없음</span>';
    return null;
  }
  let cfg;
  try { cfg = JSON.parse(stdout); } catch (e) {
    showToast('config.json 파싱 실패', 'err'); return null;
  }
  fillForm(cfg);
  return cfg;
}

function saveConfig() {
  const json = JSON.stringify(readForm(), null, 2);
  // base64 transport avoids heredoc/quoting/expansion issues through ksu exec
  const b64 = btoa(unescape(encodeURIComponent(json)));
  const cmd = `echo '${b64}' | base64 -d | sh ${CTL} set-config`;
  const { errno, stdout } = run(cmd);
  if (errno === 0) showToast('저장됨', 'ok');
  else showToast('저장 실패: ' + (stdout || errno), 'err');
}

function restart() {
  const { errno, stdout } = run(`sh ${CTL} restart`);
  refreshStatus();
  if (errno === 0) showToast('재시작됨', 'ok');
  else showToast('재시작 실패: ' + (stdout || ''), 'err');
}
function stop() {
  run(`sh ${CTL} stop`);
  refreshStatus();
  showToast('정지됨', 'ok');
}
function probe() {
  const { errno, stdout } = run(`sh ${CTL} probe`);
  const card = $('logcard');
  $('logview').textContent = stdout || '(출력 없음)';
  card.style.display = '';
  showToast('ir_spi 조사 완료 — 로그 참조');
}
function testTx() {
  showToast('테스트 송신 중…');
  const { errno, stdout } = run(`sh ${CTL} test`);
  if (errno === 0) showToast('백엔드 OK', 'ok');
  else showToast('백엔드 실패 rc=' + errno + ' ' + (stdout || '').slice(-160), 'err');
}
function toggleLog() {
  const card = $('logcard');
  if (card.style.display === 'none') {
    const { stdout } = run(`tail -n 200 ${MODDIR}/logs/server.log 2>/dev/null`);
    $('logview').textContent = stdout || '(로그 없음)';
    card.style.display = '';
  } else {
    card.style.display = 'none';
  }
}
function refreshStatus() {
  const { stdout } = run(`sh ${CTL} status`);
  const on = /running/.test(stdout);
  $('status').innerHTML = '상태: <span class="badge ' + (on ? 'on' : 'off') + '">' +
    (on ? '실행 중' : '정지') + '</span> &nbsp; <span class="badge">' + stdout.replace(/\s+$/, '') + '</span>';
}

// ---- wire up -------------------------------------------------------------
window.addEventListener('DOMContentLoaded', async () => {
  $('btn-save').addEventListener('click', saveConfig);
  $('btn-restart').addEventListener('click', restart);
  $('btn-stop').addEventListener('click', stop);
  $('btn-probe').addEventListener('click', probe);
  $('btn-test').addEventListener('click', testTx);
  $('btn-log').addEventListener('click', toggleLog);
  await loadConfig();
  refreshStatus();
});
