#!/usr/bin/env bash
# FITCOM Linux Hardening Practice Lab | 1.0.0 | 2026-10-28
# Independent practice material for rexaa. NOT an official FITCOM challenge.
# Intentionally weak configuration. Run ONLY in a disposable Ubuntu VM.
# Usage: sudo bash install.sh [install|brief|check|hint ID|solutions|status|uninstall]
# Ubuntu targets: 26.04 LTS; 24.04 LTS accepted for fallback practice.
# All lab network services listen on 127.0.0.1. No firewall rules are changed.
# Dependencies are installed from the VM's configured APT repositories.
# Reference docs:
# https://ubuntu.com/server/docs/how-to/security/openssh-server/
# https://nginx.org/en/docs/ngx_core_module.html
# https://nginx.org/en/docs/http/ngx_http_autoindex_module.html
# https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
# Snapshot rollback is the full reset. Uninstall removes lab-owned objects only.

set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

LAB_VERSION=1.0.0
BASE=/opt/fitcom-lab
CONF=/etc/fitcom-lab
STATE=/var/lib/fitcom-lab
WEB=/srv/fitcom-lab
LOG=/var/log/fitcom-lab
MANAGER=/usr/local/sbin/fitcom-lab
OWNER_MARKER=fitcom-practice-lab-v1
STAGE=initialization
UNITS=(fitcom-web.service fitcom-ssh.service fitcom-backup.service fitcom-backup.timer fitcom-diagnostics.service)
LAB_USERS=(fitops fithelpdesk fitlegacy fitweb)

say() { printf '\n[fitcom] %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
root_required() { [[ $EUID -eq 0 ]] || die 'Jalankan dengan sudo.'; }
owned_state() { [[ -f "$STATE/.owner" ]] && [[ $(cat "$STATE/.owner") == "$OWNER_MARKER" ]]; }
installed_required() { owned_state && [[ -f "$STATE/installed" ]] || die 'Lab belum selesai terpasang. Gunakan install; jika instalasi terputus, gunakan uninstall dahulu.'; }

usage() {
  cat <<'USAGE'
FITCOM Linux Hardening Practice Lab (mandiri; bukan soal resmi)

  sudo bash install.sh                 Instal lab rentan di VM disposable
  sudo bash install.sh brief           Brief, aturan, dan identitas akun
  sudo bash install.sh check           Skor + pengujian layanan wajib
  sudo bash install.sh check --json    Laporan terstruktur ke stdout
  sudo bash install.sh hint 04         Petunjuk untuk satu nomor (01..12)
  sudo bash install.sh solutions       Pembahasan dan contoh perbaikan
  sudo bash install.sh status          Status service + port lab
  sudo bash install.sh uninstall       Hapus objek milik lab

Sesudah install, "sudo fitcom-lab ..." dapat menggantikan "sudo bash install.sh ...".
Ubuntu 26.04 disarankan; Ubuntu 24.04 juga diterima untuk latihan.
Butuh VM dengan systemd, sudo, serta internet jika dependensi belum ada.
Gunakan snapshot sebelum install. Jangan gunakan VM berisi data/layanan penting.
NAT tanpa port forwarding atau jaringan internal cocok untuk latihan ini.
Jangan gunakan bridged networking. Semua layanan lab bind ke loopback.
Tidak ada auto-fix: kamu memperbaiki konfigurasi sendiri.
USAGE
}

restore_policy() {
  # A marker makes restoration retryable even after an interrupted installation.
  if [[ -f "$STATE/policy-temporary" ]]; then
    rm -f -- /usr/sbin/policy-rc.d
    if [[ -e "$STATE/policy-rc.d.original" || -L "$STATE/policy-rc.d.original" ]]; then
      mv -- "$STATE/policy-rc.d.original" /usr/sbin/policy-rc.d
    fi
    rm -f -- "$STATE/policy-temporary"
  fi
}

on_failure() {
  local code=$? line=${1:-unknown}
  trap - ERR
  printf '\nInstalasi/perintah gagal pada tahap "%s", baris %s (exit %s).\n' "$STAGE" "$line" "$code" >&2
  if owned_state; then
    printf 'Untuk status: sudo bash install.sh status\nUntuk membersihkan instalasi parsial: sudo bash install.sh uninstall\n' >&2
  fi
  exit "$code"
}
trap 'on_failure "$LINENO"' ERR

preflight() {
  root_required
  [[ -r /etc/os-release ]] || die 'OS tidak terdeteksi.'
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die 'Installer ini ditujukan untuk Ubuntu.'
  case ${VERSION_ID:-} in
    26.04) ;;
    24.04) say 'Ubuntu 24.04: materi latihan sama, tetapi cocokkan kembali dengan 26.04 sebelum lomba.' ;;
    *) die "Versi ${VERSION_ID:-unknown} belum ditargetkan. Gunakan Ubuntu 26.04 atau 24.04." ;;
  esac
  command -v systemd-detect-virt >/dev/null || die 'systemd-detect-virt tidak tersedia.'
  systemd-detect-virt --vm --quiet || die 'Tidak terdeteksi sebagai VM penuh. Installer menolak host fisik, container, dan WSL. Gunakan VM Ubuntu.'
  [[ $(ps -p 1 -o comm=) == systemd ]] || die 'PID 1 harus systemd.'
  command -v sudo >/dev/null || die 'sudo harus tersedia sebelum instalasi.'
  command -v flock >/dev/null || die 'util-linux/flock tidak tersedia.'
  local p name
  for p in "$BASE" "$CONF" "$STATE" "$WEB" "$LOG" "$MANAGER" \
      /etc/sudoers.d/fitcom-helpdesk /run/fitcom-nginx; do
    [[ ! -e "$p" && ! -L "$p" ]] || die "Path sudah ada: $p. Tidak ditimpa. Jika ini lab sebelumnya, uninstall atau restore snapshot." 
  done
  for name in "${LAB_USERS[@]}"; do
    if getent passwd "$name" >/dev/null || getent group "$name" >/dev/null; then
      die "User/grup $name sudah ada. Gunakan VM bersih."
    fi
    [[ ! -e /home/$name && ! -L /home/$name ]] || die "Home /home/$name sudah ada."
  done
  for name in "${UNITS[@]}"; do
    [[ ! -e /etc/systemd/system/$name && ! -L /etc/systemd/system/$name ]] || die "Unit $name sudah ada."
    if systemctl cat "$name" >/dev/null 2>&1; then die "Unit $name sudah dikenal systemd."; fi
  done
  # Port check without needing Python before dependencies are installed.
  if ss -H -ltn | awk '{print $4}' | grep -Eq ':(2222|8080|9090)$'; then
    die 'Port 2222, 8080, atau 9090 sedang dipakai. Installer tidak menghentikan pemilik port.'
  fi
  local options
  options=$(findmnt -n -o OPTIONS -T /opt)
  case ",$options," in
    *,nosuid,*|*,noexec,*) die '/opt berada pada mount nosuid/noexec. Gunakan disk VM normal agar latihan SUID/capabilities bermakna.' ;;
  esac
  visudo -c >/dev/null || die 'Konfigurasi sudo awal tidak valid. Perbaiki dahulu.'
}

dependencies() {
  STAGE=dependencies
  local pkg
  local -a missing=()
  for pkg in openssh-server openssh-client nginx python3 libcap2-bin acl curl; do
    if [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true) != 'install ok installed' ]]; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]})); then
    say "Memasang dependensi dari APT: ${missing[*]}"
    # Suppress package-triggered service starts; preserve an existing policy file.
    if [[ -e /usr/sbin/policy-rc.d || -L /usr/sbin/policy-rc.d ]]; then
      mv -- /usr/sbin/policy-rc.d "$STATE/policy-rc.d.original"
    fi
    : > "$STATE/policy-temporary"
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 0755 /usr/sbin/policy-rc.d
    trap restore_policy EXIT
    apt-get -o DPkg::Lock::Timeout=60 update
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
      apt-get -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confold \
      install -y --no-install-recommends "${missing[@]}"
    restore_policy
    trap - EXIT
  fi
  for pkg in /usr/sbin/sshd /usr/sbin/nginx /usr/bin/python3 /usr/sbin/setcap /usr/sbin/getcap; do
    [[ -x "$pkg" ]] || die "Dependensi tidak ditemukan: $pkg"
  done
}

install_lab() {
  STAGE=preflight
  preflight
  exec 9>/run/lock/fitcom-lab-install.lock
  flock -n 9 || die 'Installer lain sedang berjalan.'
  say 'Menyiapkan lab rentan. Gunakan snapshot VM untuk mengulang dari kondisi awal.'
  install -d -m 0700 "$STATE"
  printf '%s\n' "$OWNER_MARKER" > "$STATE/.owner"
  # Keep an uninstall entry point even if dependency installation is interrupted.
  install -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$MANAGER"
  dependencies
  STAGE=accounts
  local name
  for name in fitops fithelpdesk fitlegacy; do
    useradd -m -U -d "/home/$name" -s /bin/bash "$name"
    printf '%s:Fitcom-Lab-Only-26!\n' "$name" | chpasswd
    chmod 0750 "/home/$name"
  done
  useradd -r -U -M -d /nonexistent -s /usr/sbin/nologin fitweb
  usermod -aG sudo fitlegacy
  printf 'fithelpdesk ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/fitcom-helpdesk
  chmod 0440 /etc/sudoers.d/fitcom-helpdesk
  visudo -c >/dev/null

  STAGE=files
  install -d -m 0755 "$BASE" "$BASE/bin" "$BASE/jobs" "$CONF" "$WEB" "$WEB/www" "$WEB/www/reports" "$LOG"
  install -d -m 0700 "$STATE/keys" "$STATE/backup"
  cat > "$WEB/www/index.html" <<'HTML'
<!doctype html><html lang="id"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FITCOM Practice Portal</title>
<style>body{margin:0;background:#101826;color:#e7eefb;font:17px/1.6 system-ui}main{max-width:760px;margin:70px auto;padding:30px}small{color:#75e2bc}h1{font-size:40px;line-height:1.15}a{color:#8bc8ff}code{background:#243146;padding:3px 7px;border-radius:5px}.card{border:1px solid #344157;border-radius:16px;padding:24px;margin-top:25px}</style>
<main><small>REXAA / LINUX HARDENING PRACTICE</small><h1>FITCOM Practice Portal</h1><p>Portal ini harus tetap berfungsi selama latihan hardening.</p><div class="card"><p>Periksa <a href="/health.txt">health check</a> dan <a href="/reports/q3-demo.txt">laporan contoh</a>.</p><p>Brief dan pengecekan: <code>sudo fitcom-lab brief</code> / <code>sudo fitcom-lab check</code></p></div><p>Semua identitas dan data di lab ini fiktif. Bukan soal resmi FITCOM.</p></main></html>
HTML
  printf 'FITCOM_OK\n' > "$WEB/www/health.txt"
  printf 'FITCOM_DEMO_REPORT\nRevenue=1000 (data fiktif)\n' > "$WEB/www/reports/q3-demo.txt"
  cat > "$WEB/www/.env" <<'ENV'
APP_MODE=fitcom-practice
DB_HOST=127.0.0.1
DB_USER=demo_app
DB_PASSWORD=FAKE_SECRET_TRAINING_ONLY
ENV
  chown root:fitweb "$WEB/www/.env"
  chmod 0644 "$WEB/www/.env"
  cat > "$BASE/jobs/backup.sh" <<'BACKUP'
#!/usr/bin/env bash
set -euo pipefail
umask 077
tar -czf /var/lib/fitcom-lab/backup/latest.tar.gz -C /srv/fitcom-lab/www .
printf 'backup completed at %s\n' "$(date -Is)"
BACKUP
  chmod 0777 "$BASE/jobs/backup.sh"
  # These are separate copies. The system's own bash/python binaries are untouched.
  cp -- /bin/bash "$BASE/bin/diag-shell"
  chown root:root "$BASE/bin/diag-shell"
  chmod 4755 "$BASE/bin/diag-shell"
  cp -- "$(readlink -f /usr/bin/python3)" "$BASE/bin/diag-python"
  chown root:root "$BASE/bin/diag-python"
  chmod 0755 "$BASE/bin/diag-python"
  setcap cap_setuid=ep "$BASE/bin/diag-python"
  getcap "$BASE/bin/diag-python" | grep -q cap_setuid || die 'Filesystem tidak menyimpan file capabilities.'

  STAGE=ssh
  ssh-keygen -q -t ed25519 -N '' -C fitcom-host -f "$CONF/ssh_host_ed25519_key"
  ssh-keygen -q -t ed25519 -N '' -C fitcom-approved-operator -f "$STATE/keys/operator"
  ssh-keygen -q -t ed25519 -N '' -C fitcom-retired-key -f "$STATE/keys/retired"
  install -d -m 0700 -o fitops -g fitops /home/fitops/.ssh
  cat "$STATE/keys/operator.pub" "$STATE/keys/retired.pub" > /home/fitops/.ssh/authorized_keys
  chown fitops:fitops /home/fitops/.ssh/authorized_keys
  chmod 0600 /home/fitops/.ssh/authorized_keys
  # Keep only the retired public key as a checker fixture; no usable private backdoor key.
  rm -- "$STATE/keys/retired"
  printf '[127.0.0.1]:2222 %s\n' "$(cut -d ' ' -f1,2 "$CONF/ssh_host_ed25519_key.pub")" > "$STATE/keys/known_hosts"
  cat > "$CONF/sshd_config" <<'SSHD'
# Separate practice SSH daemon. The VM's normal sshd_config is not used.
Port 2222
ListenAddress 127.0.0.1
HostKey /etc/fitcom-lab/ssh_host_ed25519_key
PidFile /run/fitcom-sshd.pid
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
AllowUsers fitops fitlegacy root
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
LogLevel VERBOSE
Subsystem sftp internal-sftp
SSHD
  chmod 0600 "$CONF/ssh_host_ed25519_key"
  install -d -m 0755 /run/sshd
  /usr/sbin/sshd -t -f "$CONF/sshd_config"

  STAGE=web
  cat > "$CONF/nginx.conf" <<'NGINX'
user root;
worker_processes 1;
pid /run/fitcom-nginx/nginx.pid;
error_log /var/log/fitcom-lab/nginx-error.log;
events { worker_connections 128; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/fitcom-lab/nginx-access.log;
    server {
        listen 127.0.0.1:8080;
        server_name localhost;
        root /srv/fitcom-lab/www;
        index index.html;
        autoindex on;
        include /etc/fitcom-lab/nginx-extra.conf;
        location / { try_files $uri $uri/ =404; }
    }
}
NGINX
  printf '# Tambahkan aturan akses spesifik sesuai kebutuhan lab.\n' > "$CONF/nginx-extra.conf"
  cat > "$BASE/diagnostics.py" <<'PY_DIAG'
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"FITCOM obsolete diagnostics: demo only; no sensitive data\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("127.0.0.1", 9090), Handler).serve_forever()
PY_DIAG
  chmod 0644 "$BASE/diagnostics.py"

  STAGE=systemd
  cat > /etc/systemd/system/fitcom-web.service <<'UNIT_WEB'
[Unit]
Description=FITCOM practice portal (independent nginx instance)
After=network.target
[Service]
Type=simple
RuntimeDirectory=fitcom-nginx
ExecStartPre=/usr/sbin/nginx -t -c /etc/fitcom-lab/nginx.conf
ExecStart=/usr/sbin/nginx -c /etc/fitcom-lab/nginx.conf -g "daemon off;"
ExecReload=/usr/sbin/nginx -t -c /etc/fitcom-lab/nginx.conf
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=15
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT_WEB
  cat > /etc/systemd/system/fitcom-ssh.service <<'UNIT_SSH'
[Unit]
Description=FITCOM practice SSH on loopback port 2222
After=network.target
[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -m 0755 /run/sshd
ExecStartPre=/usr/sbin/sshd -t -f /etc/fitcom-lab/sshd_config
ExecStart=/usr/sbin/sshd -D -e -f /etc/fitcom-lab/sshd_config
ExecReload=/usr/sbin/sshd -t -f /etc/fitcom-lab/sshd_config
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT_SSH
  cat > /etc/systemd/system/fitcom-backup.service <<'UNIT_BACKUP'
[Unit]
Description=FITCOM required portal backup
[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=/opt/fitcom-lab/jobs/backup.sh
UNIT_BACKUP
  cat > /etc/systemd/system/fitcom-backup.timer <<'UNIT_TIMER'
[Unit]
Description=FITCOM scheduled backup every five minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=fitcom-backup.service
[Install]
WantedBy=timers.target
UNIT_TIMER
  cat > /etc/systemd/system/fitcom-diagnostics.service <<'UNIT_DIAG'
[Unit]
Description=FITCOM obsolete diagnostics listener
After=network.target
[Service]
Type=simple
User=fitweb
ExecStart=/usr/bin/python3 /opt/fitcom-lab/diagnostics.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT_DIAG
  for name in "${UNITS[@]}"; do chmod 0644 "/etc/systemd/system/$name"; done
  /usr/bin/python3 - "$STATE" "$LAB_VERSION" <<'PY_MANIFEST'
import json, pathlib, pwd, sys, time
state = pathlib.Path(sys.argv[1])
manifest = {
    "version": sys.argv[2], "created_at": int(time.time()),
    "users": {name: pwd.getpwnam(name).pw_uid for name in ("fitops", "fithelpdesk", "fitlegacy", "fitweb")},
    "approved_key": (state / "keys/operator.pub").read_text().split()[1],
    "retired_key": (state / "keys/retired.pub").read_text().split()[1],
}
(state / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY_MANIFEST
  systemctl daemon-reload
  systemctl enable --now fitcom-web.service fitcom-ssh.service fitcom-backup.timer fitcom-diagnostics.service
  systemctl start fitcom-backup.service
  : > "$STATE/installed"
  STAGE=baseline-validation
  # Small bounded readiness loop; not a fixed blind wait.
  local attempt
  for ((attempt = 0; attempt < 20; attempt++)); do
    if curl --noproxy '*' --silent --fail --max-time 1 http://127.0.0.1:8080/health.txt >/dev/null \
       && curl --noproxy '*' --silent --fail --max-time 1 http://127.0.0.1:9090/ >/dev/null; then break; fi
    sleep 0.25
  done
  check_lab --json > "$STATE/baseline.json"
  /usr/bin/python3 - "$STATE/baseline.json" <<'PY_BASELINE'
import json, sys
r = json.load(open(sys.argv[1]))
if not r["healthy"] or r["raw_score"] != 0:
    print("Baseline tidak sesuai. Jangan mulai simulasi dahulu.", file=sys.stderr)
    print(json.dumps(r, indent=2), file=sys.stderr)
    sys.exit(1)
print("Baseline OK: layanan wajib berfungsi, 12 temuan masih terbuka, skor 0/100.")
PY_BASELINE
  say 'Instalasi selesai. Baca brief, lalu mulai timer latihanmu.'
  brief
}

brief() {
  installed_required
  cat <<'BRIEF'

FITCOM PRACTICE / BRIEF UNTUK REXAA
=================================
Kamu mengambil alih server portal internal yang dikonfigurasi secara ceroboh.
Lakukan audit, catat bukti, perbaiki konfigurasi, dan pertahankan fungsi bisnis.
Ada 12 temuan, total 100 poin latihan. Ini prediksi latihan, bukan kisi-kisi resmi.
Saran sesi: 15 menit inventarisasi, 70 menit perbaikan, 20 menit validasi,
15 menit laporan. Durasi ini hanya saran untuk latihanmu, bukan durasi lomba.

LAYANAN WAJIB
  Portal: http://127.0.0.1:8080/ (buka dari dalam VM, atau gunakan curl)
  Health: /health.txt; laporan publik: /reports/q3-demo.txt
  SSH operator: fitops@127.0.0.1 port 2222, key resmi harus tetap berfungsi.
  Backup: fitcom-backup.timer harus aktif dan enabled; hasil backup harus valid.
  Data .env fiktif harus tetap ada dan dapat dibaca akun layanan fitweb.

IDENTITAS DAN KEBIJAKAN
  fitops      : operator sah, akun biasa; tidak membutuhkan sudo.
  fithelpdesk : helpdesk sah, akun biasa; tidak boleh menjalankan perintah sudo.
  fitweb      : akun layanan web, non-root, tanpa login interaktif.
  fitlegacy   : pegawai lama; akses login dan hak adminnya harus dicabut.
  Akun admin asli VM-mu tetap digunakan untuk mengerjakan latihan.
  Password dummy fitops/fithelpdesk/fitlegacy: Fitcom-Lab-Only-26!
  Tidak ada perubahan password root atau akun admin asli.

BATAS LATIHAN
  Layanan diagnostik lama tidak diperlukan lagi dan tidak boleh autostart.
  Konfigurasi layanan lab menggunakan nama fitcom-*.service dan /etc/fitcom-lab.
  Nginx master boleh tetap root; worker harus memakai fitweb.
  File laporan tetap dapat diunduh langsung, tetapi listing direktori dilarang.
  Data .env tidak boleh diunduh melalui HTTP atau dibaca akun biasa.
  Binary diagnostik tidak membutuhkan SUID atau Linux file capabilities.
  Jangan menghapus data wajib, mengubah checker/fixture, atau mengganti port lab.
  Pertahankan SSH key resmi di bawah; hapus akses key yang tidak diotorisasi.
  Root login pada daemon SSH lab harus dinonaktifkan secara eksplisit.

ALUR
  sudo fitcom-lab check          Cek kemajuan; status layanan juga diuji
  sudo fitcom-lab hint 04        Buka satu petunjuk jika buntu
  sudo fitcom-lab solutions      Buka pembahasan setelah mencoba
  sudo fitcom-lab status         Diagnosis service/port

Skor konfigurasi ditampilkan sebagai skor mentah. Skor akhir menjadi 0 jika
salah satu fungsi wajib rusak. Aturan ini milik latihan, bukan aturan FITCOM.
Checker terbatas pada skenario yang ditanam; bukan audit menyeluruh/anti-cheat.
Setelah latihan: restore snapshot untuk reset penuh. Uninstall hanya menghapus
objek milik lab, bukan paket dependensi atau perubahan di luar lab.

FINGERPRINT KEY OPERATOR YANG SAH:
BRIEF
  ssh-keygen -lf "$STATE/keys/operator.pub"
  printf '\nTemplate catatan: Temuan | Bukti awal | Dampak | Perubahan | Uji ulang | Rollback\n'
}

check_lab() {
  installed_required
  [[ ${1:-} == '' || ${1:-} == --json ]] || die 'Gunakan check atau check --json.'
  /usr/bin/python3 - "${1:-}" <<'PY_CHECK'
import grp
import json
import os
import pathlib
import pwd
import socket
import stat
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

STATE = pathlib.Path('/var/lib/fitcom-lab')
BASE = pathlib.Path('/opt/fitcom-lab')
CONF = pathlib.Path('/etc/fitcom-lab')
WWW = pathlib.Path('/srv/fitcom-lab/www')
M = json.loads((STATE / 'manifest.json').read_text())
OUT_JSON = '--json' in sys.argv

def run(args, timeout=12):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, 'LC_ALL': 'C', 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'})
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(args, 125, '', str(e))

def http(path):
    # Ignore the caller's proxy settings, including for error pages.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open('http://127.0.0.1:8080' + path, timeout=3) as r:
            return r.status, r.read(65536).decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read(65536).decode('utf-8', 'replace')
    except (OSError, urllib.error.URLError):
        return 0, ''

def readable(user, path):
    return run(['/usr/sbin/runuser', '-u', user, '--', '/usr/bin/test', '-r', str(path)]).returncode == 0

def writable(user, path):
    return run(['/usr/sbin/runuser', '-u', user, '--', '/usr/bin/test', '-w', str(path)]).returncode == 0

def no_sudo(user):
    result = run(['/usr/bin/sudo', '-l', '-U', user])
    text = result.stdout + result.stderr
    # A command/query failure is not automatically treated as a secure policy.
    return result.returncode in (0, 1) and ('not allowed to run sudo' in text or 'is not allowed to run' in text)

def enabled(unit):
    r = run(['systemctl', 'is-enabled', unit])
    return r.returncode == 0 and r.stdout.strip() == 'enabled'

def active(unit):
    return run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0

def same_user(name):
    try:
        return pwd.getpwnam(name).pw_uid == M['users'][name] and M['users'][name] > 0
    except KeyError:
        return False

health = {}
health['authorized_accounts'] = all(same_user(n) for n in ('fitops', 'fithelpdesk', 'fitweb'))
code, body = http('/')
health['portal'] = code == 200 and 'FITCOM Practice Portal' in body and enabled('fitcom-web.service')
code, body = http('/health.txt')
health['http_health'] = code == 200 and body.strip() == 'FITCOM_OK'
code, body = http('/reports/q3-demo.txt')
health['public_report'] = code == 200 and 'FITCOM_DEMO_REPORT' in body
secret = WWW / '.env'
try:
    health['application_data'] = ('APP_MODE=fitcom-practice' in secret.read_text()
                                  and readable('fitweb', secret))
except OSError:
    health['application_data'] = False

ssh_result = run([
    '/usr/bin/ssh', '-F', '/dev/null', '-p', '2222', '-i', str(STATE / 'keys/operator'),
    '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=4',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'GlobalKnownHostsFile=/dev/null',
    '-o', 'UserKnownHostsFile=' + str(STATE / 'keys/known_hosts'),
    'fitops@127.0.0.1', 'printf FITCOM_SSH_OK'
], timeout=8)
health['approved_ssh_login'] = (ssh_result.returncode == 0 and ssh_result.stdout == 'FITCOM_SSH_OK'
                                and enabled('fitcom-ssh.service'))

# Verify a fresh, working backup instead of granting credit for an old archive.
archive = STATE / 'backup/latest.tar.gz'
before = archive.stat().st_mtime_ns if archive.exists() else -1
backup = run(['systemctl', 'start', 'fitcom-backup.service'], timeout=20)
backup_ok = False
try:
    with tarfile.open(archive, 'r:gz') as tf:
        names = {n[2:] if n.startswith('./') else n for n in tf.getnames()}
        backup_ok = {'index.html', 'health.txt', 'reports/q3-demo.txt', '.env'} <= names
    backup_ok = backup_ok and archive.stat().st_mtime_ns > before
except (OSError, tarfile.TarError):
    pass
health['fresh_backup'] = backup.returncode == 0 and backup_ok
health['backup_schedule'] = active('fitcom-backup.timer') and enabled('fitcom-backup.timer')

rows = []
def add(number, title, points, test):
    try:
        ok = bool(test())
    except Exception:
        ok = False
    rows.append({'id': f'{number:02d}', 'title': title, 'points': points, 'passed': ok})

def retired_user():
    try:
        u = pwd.getpwnam('fitlegacy')
    except KeyError:
        return True
    groups = {g.gr_name for g in grp.getgrall() if 'fitlegacy' in g.gr_mem or g.gr_gid == u.pw_gid}
    ps = run(['/usr/bin/passwd', '-S', 'fitlegacy']).stdout.split()
    locked = len(ps) > 1 and ps[1] == 'L'
    return (u.pw_uid != 0 and u.pw_gid != 0 and locked
            and u.pw_shell in ('/usr/sbin/nologin', '/sbin/nologin', '/bin/false', '/usr/bin/false')
            and not groups.intersection({'sudo', 'admin', 'wheel'}) and no_sudo('fitlegacy'))

def secret_permission():
    s = secret.stat()
    return (s.st_uid == 0 and not stat.S_IMODE(s.st_mode) & 0o007
            and not writable('fitweb', secret) and readable('fitweb', secret)
            and not readable('fithelpdesk', secret) and not readable('fitops', secret))

def backup_permission():
    script = BASE / 'jobs/backup.sh'
    if not script.is_file():
        return False
    for path in (script, BASE / 'jobs', BASE, BASE.parent):
        s = path.stat()
        if s.st_uid != 0 or stat.S_IMODE(s.st_mode) & 0o022:
            return False
        if any(writable(user, path) for user in ('fitops', 'fithelpdesk', 'fitweb')):
            return False
    return os.access(script, os.X_OK)

def suid_removed():
    p = BASE / 'bin/diag-shell'
    return not p.exists() or not (p.stat().st_mode & (stat.S_ISUID | stat.S_ISGID))

def caps_removed():
    p = BASE / 'bin/diag-python'
    if not p.exists():
        return True
    r = run(['/usr/sbin/getcap', str(p)])
    return r.returncode == 0 and not r.stdout.strip()

def ssh_root_policy():
    r = run(['/usr/sbin/sshd', '-T', '-f', str(CONF / 'sshd_config'),
             '-C', 'user=root,host=localhost,addr=127.0.0.1'])
    # Global policy in the supplied scenario; separately test the live operator session above.
    return r.returncode == 0 and 'permitrootlogin no' in r.stdout.splitlines()

def authorized_keys():
    p = pathlib.Path('/home/fitops/.ssh/authorized_keys')
    tokens = p.read_text().split()
    return M['approved_key'] in tokens and M['retired_key'] not in tokens

def no_listing():
    code, _ = http('/reports/')
    return code in (403, 404)

def no_http_secret():
    code, _ = http('/.env')
    return secret.is_file() and code in (403, 404)

def workers_unprivileged():
    r = run(['systemctl', 'show', '-p', 'MainPID', '--value', 'fitcom-web.service'])
    if r.returncode or not r.stdout.strip().isdigit() or int(r.stdout.strip()) <= 0:
        return False
    master = int(r.stdout.strip())
    r = run(['ps', '-eo', 'pid=,ppid=,euid=,args='])
    workers = []
    for line in r.stdout.splitlines():
        cols = line.split(None, 3)
        if len(cols) == 4 and cols[1] == str(master) and 'nginx: worker process' in cols[3]:
            workers.append(int(cols[2]))
    return bool(workers) and all(uid == M['users']['fitweb'] for uid in workers)

def diagnostics_off():
    result = run(['systemctl', 'is-enabled', 'fitcom-diagnostics.service'])
    off = result.stdout.strip() in ('disabled', 'masked', 'not-found') or 'not found' in result.stderr
    try:
        with socket.create_connection(('127.0.0.1', 9090), timeout=1):
            listening = True
    except OSError:
        listening = False
    return not active('fitcom-diagnostics.service') and off and not listening

add(1, 'Akun pegawai lama: akses dan hak admin dicabut', 10, retired_user)
add(2, 'Helpdesk tidak memiliki izin sudo', 10, lambda: same_user('fithelpdesk') and no_sudo('fithelpdesk'))
add(3, 'Data aplikasi hanya terbaca pihak yang berhak', 8, secret_permission)
add(4, 'Script backup root dan jalur induknya terlindungi', 10, backup_permission)
add(5, 'Binary diagnostik tanpa SUID/SGID', 8, suid_removed)
add(6, 'Interpreter diagnostik tanpa file capabilities', 8, caps_removed)
add(7, 'Konfigurasi efektif SSH menolak login root', 8, ssh_root_policy)
add(8, 'Hanya key operator resmi yang dipertahankan', 8, authorized_keys)
add(9, 'Directory listing laporan dinonaktifkan', 8, no_listing)
add(10, 'Data .env tidak dapat diunduh melalui HTTP', 8, no_http_secret)
add(11, 'Nginx worker berjalan sebagai fitweb', 8, workers_unprivileged)
add(12, 'Diagnostik lama berhenti dan tidak autostart', 6, diagnostics_off)

raw = sum(r['points'] for r in rows if r['passed'])
healthy = all(health.values())
report = {'version': M['version'], 'checked_at': int(time.time()), 'health': health,
          'healthy': healthy, 'checks': rows, 'raw_score': raw,
          'final_score': raw if healthy else 0, 'maximum': 100}
(STATE / 'last-report.json').write_text(json.dumps(report, indent=2) + '\n')
if OUT_JSON:
    print(json.dumps(report, indent=2))
else:
    print('\nFITCOM PRACTICE / HASIL PEMERIKSAAN\n')
    print('FUNGSI WAJIB')
    for key, ok in health.items():
        print(f'  [{"OK" if ok else "RUSAK"}] {key}')
    print('\nKONFIGURASI')
    for row in rows:
        mark = 'SELESAI' if row['passed'] else 'TERBUKA'
        print(f'  {row["id"]} [{mark}] {row["title"]} ({row["points"]} poin)')
    print(f'\nSkor konfigurasi: {raw}/100')
    print(f'Skor akhir latihan: {report["final_score"]}/100')
    if not healthy:
        print('Pulihkan fungsi yang RUSAK dahulu. Mematikan layanan wajib tidak menyelesaikan lab.')
        if not health['approved_ssh_login']:
            print('Diagnosis SSH: sudo journalctl -u fitcom-ssh -n 30 --no-pager')
    elif raw == 100:
        print('Seluruh skenario lolos. Selesaikan laporan bukti sebelum/ sesudah perbaikan.')
    print('Laporan terakhir: /var/lib/fitcom-lab/last-report.json')
    print('Pemeriksaan SSH menilai konfigurasi pada disk; validasi lalu reload daemon setelah mengedit.')
    print('Ini skor lab mandiri, bukan sistem penilaian resmi FITCOM.')
PY_CHECK
}

hint() {
  case ${1:-} in
    1|01) cat <<'H01'
01 / Bandingkan roster pada brief dengan getent passwd dan getent group sudo.
Mencabut sudo saja belum menonaktifkan login. Periksa status password dan shell.
H01
      ;;
    2|02) cat <<'H02'
02 / Jalankan sudo -l -U fithelpdesk sebagai admin. Telusuri sudoers dan include-nya.
Kebijakan lab: akun helpdesk tetap ada, tetapi tidak membutuhkan perintah sudo.
H02
      ;;
    3|03) cat <<'H03'
03 / Cari file dotfile pada document root. Bandingkan stat, getfacl, dan akses aktual
sebagai fithelpdesk versus fitweb. Akun layanan harus masih dapat membacanya.
H03
      ;;
    4|04) cat <<'H04'
04 / systemctl cat fitcom-backup.service fitcom-backup.timer
Periksa siapa yang menjalankan job, siapa yang bisa menulis script, dan permission
direktori induknya. Mematikan timer akan merusak fungsi wajib.
H04
      ;;
    5|05) cat <<'H05'
05 / Cari file dengan bit SUID/SGID di /opt/fitcom-lab/bin menggunakan find/stat.
Binary diagnostik tidak punya kebutuhan bisnis untuk berjalan dengan privilege pemiliknya.
H05
      ;;
    6|06) cat <<'H06'
06 / getcap -r /opt/fitcom-lab 2>/dev/null
Permission 0755 tidak berarti aman jika file memperoleh capability berbahaya.
H06
      ;;
    7|07) cat <<'H07'
07 / Audit daemon SSH LAB, bukan sshd utama port 22:
sudo sshd -T -f /etc/fitcom-lab/sshd_config -C user=root,host=localhost,addr=127.0.0.1
Periksa PermitRootLogin. Uji sintaks sebelum reload fitcom-ssh.
H07
      ;;
    8|08) cat <<'H08'
08 / ssh-keygen -lf /home/fitops/.ssh/authorized_keys
Bandingkan fingerprint dengan brief. Mengganti password tidak mencabut SSH key.
Jangan menghapus key operator yang sah.
H08
      ;;
    9|09) cat <<'H09'
09 / Bandingkan GET /reports/ dan GET /reports/q3-demo.txt pada port 8080.
Pahami autoindex pada konfigurasi nginx lab. File publik harus tetap dapat diunduh.
H09
      ;;
    10) cat <<'H10'
10 / Uji curl --noproxy '*' -i http://127.0.0.1:8080/.env
Permission OS dan kebijakan HTTP adalah dua lapisan berbeda. Periksa location pada nginx.
Menghapus .env akan merusak kebutuhan data aplikasi dalam lab ini.
H10
      ;;
    11) cat <<'H11'
11 / ps -eo pid,ppid,euser,args | grep nginx
Bedakan master dan worker. Periksa directive user di konfigurasi nginx LAB.
Master root dapat normal; worker root tidak sesuai kebijakan skenario ini.
H11
      ;;
    12) cat <<'H12'
12 / ss -tulpn dan systemctl list-unit-files 'fitcom-*'
Brief menyatakan diagnostik lama tidak dibutuhkan. Stop saja tidak mencegah autostart.
H12
      ;;
    *) die 'Gunakan hint 01 sampai hint 12, misalnya: sudo fitcom-lab hint 04' ;;
  esac
}

solutions() {
  cat <<'SOLUTIONS'
PEMBAHASAN / SPOILER
===================
Ini contoh perbaikan untuk konfigurasi awal lab. Baca dahulu dan sesuaikan jika
kamu telah mengubah file. Perintah di bawah DITAMPILKAN saja, tidak dieksekusi.
Backup file yang akan diedit. Setelah setiap kelompok perubahan, jalankan check.

01. Akun lama harus kehilangan akses, bukan hanya keluar dari satu grup.
    sudo usermod -L -s /usr/sbin/nologin -G '' fitlegacy
    sudo -l -U fitlegacy
    Alternatif dalam lab: hapus akun lama, setelah memastikan data yang dibutuhkan.
    Lock password tidak otomatis mencabut SSH key; audit keduanya di sistem nyata.

02. Hapus rule lab yang memberikan hak admin kepada helpdesk.
    sudo rm /etc/sudoers.d/fitcom-helpdesk
    sudo visudo -c
    sudo -l -U fithelpdesk
    Jangan mengubah izin sudo akun admin asli VM.

03. Pertahankan akses baca akun layanan, cabut akses akun biasa.
    sudo chown root:fitweb /srv/fitcom-lab/www/.env
    sudo chmod 0640 /srv/fitcom-lab/www/.env
    sudo -u fitweb test -r /srv/fitcom-lab/www/.env
    sudo -u fithelpdesk test -r /srv/fitcom-lab/www/.env
    Perintah terakhir seharusnya exit 1 (ditolak). Pastikan ACL tambahan tidak membuka akses.

04. Script yang dijalankan root harus terlindungi dari modifikasi user biasa.
    sudo chown root:root /opt/fitcom-lab/jobs/backup.sh
    sudo chmod 0750 /opt/fitcom-lab/jobs/backup.sh
    sudo systemctl start fitcom-backup.service
    sudo systemctl status fitcom-backup.timer --no-pager
    Direktori induk juga tidak boleh writable oleh akun tidak tepercaya.

05. Hilangkan SUID/SGID yang tidak diperlukan pada COPY binary lab.
    sudo chmod u-s,g-s /opt/fitcom-lab/bin/diag-shell
    Jangan menghapus SUID semua binary sistem secara massal.

06. Hilangkan capability pada COPY interpreter lab.
    sudo setcap -r /opt/fitcom-lab/bin/diag-python
    getcap /opt/fitcom-lab/bin/diag-python
    Output kosong sesuai kebutuhan skenario ini.

07. Edit /etc/fitcom-lab/sshd_config: PermitRootLogin no
    sudo sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/fitcom-lab/sshd_config
    sudo sshd -t -f /etc/fitcom-lab/sshd_config
    sudo systemctl reload fitcom-ssh.service
    Jalankan check untuk memastikan login operator sah masih berfungsi.

08. Hapus hanya key yang tidak diotorisasi; fingerprint resmi ada pada brief.
    Pada file awal lab, komentar key tidak sah adalah fitcom-retired-key:
    sudo sed -i '/fitcom-retired-key$/d' /home/fitops/.ssh/authorized_keys
    sudo chown fitops:fitops /home/fitops/.ssh/authorized_keys
    sudo chmod 0600 /home/fitops/.ssh/authorized_keys
    Jangan menghapus seluruh .ssh atau key resmi.

09. Edit /etc/fitcom-lab/nginx.conf: autoindex off;
    sudo sed -i 's/autoindex on;/autoindex off;/' /etc/fitcom-lab/nginx.conf
    sudo nginx -t -c /etc/fitcom-lab/nginx.conf
    sudo systemctl reload fitcom-web.service
    /reports/ akan 403; /reports/q3-demo.txt harus tetap 200.

10. Tambahkan blok berikut ke /etc/fitcom-lab/nginx-extra.conf:
    location ~ /\. {
        deny all;
    }
    Lalu:
    sudo nginx -t -c /etc/fitcom-lab/nginx.conf
    sudo systemctl reload fitcom-web.service
    curl --noproxy '*' -i http://127.0.0.1:8080/.env
    Harus ditolak. Pada produksi, secret idealnya juga ditempatkan di luar document root;
    lab ini mempertahankan path tetap agar pengujian permission dan HTTP dapat dibandingkan.

11. Edit /etc/fitcom-lab/nginx.conf: user fitweb;
    sudo sed -i 's/^user root;/user fitweb;/' /etc/fitcom-lab/nginx.conf
    sudo nginx -t -c /etc/fitcom-lab/nginx.conf
    sudo systemctl reload fitcom-web.service
    ps -eo pid,ppid,euser,args | grep nginx
    Tunggu worker lama selesai; master boleh tetap root, worker harus fitweb.

12. Nonaktifkan service diagnostik yang sudah tidak dibutuhkan.
    sudo systemctl disable --now fitcom-diagnostics.service
    ss -ltnp
    Port 9090 harus berhenti listening.

VALIDASI AKHIR
    sudo fitcom-lab check
    sudo fitcom-lab check --json
    Semua fungsi wajib OK, skor 100/100. Simpan bukti dan penjelasan dampak tiap temuan.
    Jika diizinkan pada latihanmu, reboot VM lalu ulangi check untuk menguji persistensi.

MATERI TAMBAHAN DI LUAR 12 SKENARIO
    UFW/nftables, PAM/password policy, AppArmor, paket/CVE, dan analisis log juga
    patut dipelajari. Installer ini tidak menanam semua kemungkinan materi lomba.
SOLUTIONS
}

status_lab() {
  printf '\nUnit lab:\n'
  systemctl --no-pager --full status "${UNITS[@]}" || true
  printf '\nListener lab:\n'
  ss -ltnp | awk 'NR == 1 || /:(2222|8080|9090)[[:space:]]/'
  printf '\nLog terkait: sudo journalctl -u fitcom-web -u fitcom-ssh -u fitcom-backup -n 60 --no-pager\n'
}

uninstall_lab() {
  root_required
  owned_state || die 'Marker kepemilikan lab tidak ditemukan; tidak menghapus apa pun.'
  STAGE=uninstall
  restore_policy
  local unit name uid
  for unit in "${UNITS[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  for name in "${LAB_USERS[@]}"; do
    if getent passwd "$name" >/dev/null; then
      uid=$(id -u "$name")
      [[ $uid -gt 0 ]] || die "Akun $name memiliki UID 0; perbaiki identitasnya dahulu, uninstall dihentikan."
      # Kill only accounts created by this lab, never the VM administrator.
      pkill -TERM -u "$uid" 2>/dev/null || true
      userdel "$name" || die "Tidak dapat menghapus $name. Tutup sesi/proses akun lab, lalu ulangi uninstall."
    fi
    if getent group "$name" >/dev/null; then groupdel "$name"; fi
  done
  for unit in "${UNITS[@]}"; do rm -f -- "/etc/systemd/system/$unit"; done
  rm -f -- /etc/sudoers.d/fitcom-helpdesk /run/fitcom-sshd.pid
  rm -rf -- /home/fitops /home/fithelpdesk /home/fitlegacy "$BASE" "$CONF" "$WEB" "$LOG" /run/fitcom-nginx
  systemctl daemon-reload
  systemctl reset-failed "${UNITS[@]}" 2>/dev/null || true
  rm -rf -- "$STATE"
  rm -f -- "$MANAGER"
  say 'Objek lab dihapus. Paket APT dan perubahanmu di luar lab tetap ada. Restore snapshot untuk kembali persis ke kondisi awal.'
}

main() {
  local command=${1:-install}
  if (($#)); then shift; fi
  case "$command" in
    -h|--help|help) usage ;;
    install) (($# == 0)) || die 'install tidak menerima argumen tambahan.'; install_lab ;;
    brief) root_required; brief ;;
    check) root_required; check_lab "${1:-}" ;;
    hint) root_required; installed_required; hint "${1:-}" ;;
    solutions) solutions ;;
    status) root_required; status_lab ;;
    uninstall) uninstall_lab ;;
    *) usage; die "Perintah tidak dikenal: $command" ;;
  esac
}

main "$@"
