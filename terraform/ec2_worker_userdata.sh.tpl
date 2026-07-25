#!/bin/bash
# cloud-init for a self-enrolling PkgEval test worker (Ubuntu 24.04).
set -eux

# FIRST, before any third-party code runs (installers, Pkg build scripts):
# IMDS is reachable by root only. Everything below that runs as non-root —
# including the eventual sandboxed package code — goes through the
# bearer-gated credential proxy instead. Re-applied on reboots by the proxy
# service's ExecStartPre.
command -v iptables >/dev/null || { apt-get update -q; apt-get install -qy iptables; }
iptables -I OUTPUT -d 169.254.169.254 -m owner ! --uid-owner root -j REJECT

# rootless containers (crun) + rr need these; Ubuntu 24.04 restricts
# unprivileged user namespaces via AppArmor by default
cat >/etc/sysctl.d/99-pkgeval.conf <<SYSCTL
kernel.apparmor_restrict_unprivileged_userns = 0
kernel.perf_event_paranoid = 1
SYSCTL
sysctl --system

apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -qy git curl

useradd --create-home --shell /bin/bash worker

# PkgEval drives containers with `crun --systemd-cgroup`, which for a rootless
# container asks the *user's* systemd (over its session D-Bus) to create the
# transient scope. A `User=` system service has neither, so every container --
# starting with the shared Xvfb one -- dies instantly with the error discarded.
# Lingering starts a persistent `systemd --user` for the worker at boot, which
# creates /run/user/<uid> and its bus.
#
# systemd delegates only `memory pids cpu` to user managers by default. The
# worker pins each slot to a CPU, so crun also needs `cpuset` — without it every
# container fails with "the requested cgroup controller `cpuset` is not
# available", which PkgEval surfaces as an unhelpful skip/uninstallable.
mkdir -p /etc/systemd/system/user@.service.d
cat >/etc/systemd/system/user@.service.d/delegate.conf <<DELEGATE
[Service]
Delegate=cpu cpuset io memory pids
DELEGATE
systemctl daemon-reload

loginctl enable-linger worker
WORKER_UID=$(id -u worker)

sudo -u worker -H bash -c 'curl -fsSL https://install.julialang.org | sh -s -- -y --default-channel ${julia_channel}'
sudo -u worker -H git clone --branch ${farm_ref} ${farm_repo} /home/worker/PkgEvalFarm.jl
sudo -u worker -H bash -c 'cd ~/PkgEvalFarm.jl && ~/.juliaup/bin/julia --project=. -e "using Pkg; Pkg.instantiate()"'

# --- IMDS protection ---------------------------------------------------------
# PkgEval sandboxes share the host network namespace, so package code under
# test could otherwise reach IMDS and steal the instance's role credentials.
# Instead: IMDS is firewalled to root only, and a root-owned localhost proxy
# re-serves the credentials gated on a bearer token. The token is handed to the
# worker via systemd EnvironmentFile; the sandbox inherits neither the worker's
# environment nor host files, so it can reach the proxy's port but never
# authenticate to it.
CREDS_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
install -m 640 -o root -g worker /dev/null /etc/pkgeval-worker.env
cat >/etc/pkgeval-worker.env <<ENVFILE
PKGEVAL_CREDS_URL=http://127.0.0.1:9911/credentials
PKGEVAL_CREDS_TOKEN=$CREDS_TOKEN
ENVFILE

cat >/usr/local/bin/pkgeval-imds-proxy <<'PROXY'
#!/usr/bin/env python3
"""Serve this instance's IMDSv2 role credentials on localhost, bearer-gated."""
import json, os, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

IMDS = "http://169.254.169.254"
TOKEN = os.environ["CREDS_TOKEN"]
cache = {"expires": 0, "body": b""}

def imds(path, token):
    req = urllib.request.Request(IMDS + path, headers={"X-aws-ec2-metadata-token": token})
    return urllib.request.urlopen(req, timeout=5).read()

def fetch():
    if time.time() < cache["expires"]:
        return cache["body"]
    req = urllib.request.Request(IMDS + "/latest/api/token", method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"})
    token = urllib.request.urlopen(req, timeout=5).read().decode()
    role = imds("/latest/meta-data/iam/security-credentials/", token).decode().strip()
    body = imds("/latest/meta-data/iam/security-credentials/" + role, token)
    cache["body"] = body
    cache["expires"] = time.time() + 120  # IMDS rotates well ahead of expiry
    return body

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.send_response(401); self.end_headers(); return
        if self.path != "/credentials":
            self.send_response(404); self.end_headers(); return
        try:
            body = fetch()
        except Exception as err:
            self.send_response(502); self.end_headers()
            self.wfile.write(json.dumps({"error": str(err)}).encode()); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", 9911), Handler).serve_forever()
PROXY
chmod 755 /usr/local/bin/pkgeval-imds-proxy

cat >/etc/systemd/system/pkgeval-imds-proxy.service <<UNIT
[Unit]
Description=Bearer-gated IMDS credential proxy for the PkgEval worker
After=network-online.target
Wants=network-online.target

[Service]
User=root
Environment=CREDS_TOKEN=$CREDS_TOKEN
# (re-)apply the firewall on every boot: IMDS reachable by root only
ExecStartPre=-/usr/sbin/iptables -D OUTPUT -d 169.254.169.254 -m owner ! --uid-owner root -j REJECT
ExecStartPre=/usr/sbin/iptables -I OUTPUT -d 169.254.169.254 -m owner ! --uid-owner root -j REJECT
ExecStart=/usr/local/bin/pkgeval-imds-proxy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/pkgeval-worker.service <<UNIT
[Unit]
Description=PkgEval farm worker
After=network-online.target pkgeval-imds-proxy.service user@$WORKER_UID.service
Wants=network-online.target user@$WORKER_UID.service
Requires=pkgeval-imds-proxy.service

[Service]
User=worker
# PkgEval needs a delegated cgroup v2 subtree for per-job resource limits
Delegate=yes
TasksMax=infinity
LimitNOFILE=1048576
Environment=HOME=/home/worker
# crun --systemd-cgroup talks to the user manager over this bus
Environment=XDG_RUNTIME_DIR=/run/user/$WORKER_UID
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$WORKER_UID/bus
Environment=JULIA=/home/worker/.juliaup/bin/julia
Environment=AWS_REGION=${region}
Environment=PKGEVAL_QUEUE_URL=${queue_url}
Environment=PKGEVAL_RUNS_TABLE=${runs_table}
Environment=PKGEVAL_JOBS_TABLE=${jobs_table}
Environment=PKGEVAL_BUCKET=${bucket}
# PKGEVAL_CREDS_URL/_TOKEN: credentials come from the bearer-gated local proxy
# (IMDS itself is firewalled to root); the token file is root:worker 640 and
# systemd injects it, so it never exists in sandbox-visible files or env
EnvironmentFile=/etc/pkgeval-worker.env
ExecStart=/home/worker/PkgEvalFarm.jl/bin/farm worker
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pkgeval-imds-proxy
systemctl enable --now pkgeval-worker
