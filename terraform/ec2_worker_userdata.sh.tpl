#!/bin/bash
# cloud-init for a self-enrolling PkgEval test worker (Ubuntu 24.04).
set -eux

# A failed bootstrap must not leave a silent zombie: without this, `set -e`
# just stops the script and the instance sits idle forever — running, healthy
# as far as EC2 knows, never claiming work, billing all the while. Shutting
# down flips the ASG health check, which replaces the instance (scale-in
# protection does not apply to unhealthy-instance replacement).
trap 'echo "PkgEval worker bootstrap FAILED at line $LINENO" > /dev/console; shutdown -h now' ERR

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
DEBIAN_FRONTEND=noninteractive apt-get install -qy git curl unzip

# AWS CLI v2 via the official installer: cloud-init downloads the worker
# sysimage from a private bucket with the instance profile's credentials,
# before any Julia AWS tooling exists. (Ubuntu 24.04 removed the `awscli`
# apt package from its archive entirely — installing it fails.)
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

useradd --create-home --shell /bin/bash worker

# local sealed-artifact cache (PKGEVAL_SEAL_CACHE in the unit environment):
# /var/cache is root-owned and the worker cannot create this itself — without
# it every proxy fetch EACCESes while persisting (seen live: a zero-hit run
# with every artifact present in S3)
install -d -o worker -g worker /var/cache/pkgeval-seal

# --- local NVMe scratch ------------------------------------------------------
# The *d instance types carry ephemeral NVMe the AMI never touches, while the
# write-hot paths — per-job sandbox scratch in /tmp, the worker depot
# (compilecache, package installs, rootfs images), the sealed-artifact cache —
# otherwise all contend on the single gp3 root volume (measured pinned at its
# throughput cap with the CPUs half idle, 2026-08-11). Use the local disks
# when present: RAID0 across multiples, bind-mounted over the hot paths.
# Best-effort — any failure leaves the instance on EBS exactly as before.
# Ephemerality is fine: every path bound here is rebuilt on boot, and the
# farm's ground truth lives in S3/DynamoDB.
setup_local_ssd() {
    local devs dev n
    devs=$(lsblk -dno NAME,MODEL | awk '/Instance Storage/ {print "/dev/"$1}')
    [ -n "$devs" ] || return 0
    n=$(echo "$devs" | wc -l)
    if [ "$n" -gt 1 ]; then
        command -v mdadm >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -qy mdadm
        mdadm --create /dev/md0 --run --level=0 --force --raid-devices=$n $devs
        dev=/dev/md0
    else
        dev=$devs
    fi
    mkfs.ext4 -q -F -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 "$dev"
    mkdir -p /mnt/scratch
    mount -o noatime "$dev" /mnt/scratch
    install -d -m 1777 /mnt/scratch/tmp
    install -d -o worker -g worker /mnt/scratch/depot
    install -d -o worker -g worker /mnt/scratch/sealcache
    mount --bind /mnt/scratch/tmp /tmp
    install -d -o worker -g worker /home/worker/.julia
    mount --bind /mnt/scratch/depot /home/worker/.julia
    mount --bind /mnt/scratch/sealcache /var/cache/pkgeval-seal
    echo "local NVMe scratch active on $dev ($n device(s))"
}
setup_local_ssd || echo "local NVMe scratch unavailable; staying on EBS"

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

# instance identity for fleet-drain coordination and cost attribution,
# fetched as root (IMDS is firewalled to root; the worker only ever needs the
# resulting strings)
IMDS_TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
INSTANCE_AZ=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

sudo -u worker -H bash -c 'curl -fsSL https://install.julialang.org | sh -s -- -y --default-channel ${julia_channel}'
sudo -u worker -H git clone --branch ${farm_ref} ${farm_repo} /home/worker/PkgEvalFarm.jl

# --- fleet generation --------------------------------------------------------
# Every instance of one scale-out runs identical code: the first instance of a
# generation samples the CI-green deploy ref and records it (conditional write
# settles boot races); later instances — including spot replacements mid-run —
# join the recorded generation. Workers heartbeat the record while alive, so
# "stale" means "the fleet scaled to zero"; deploys take effect at the next
# scale-from-zero, never mid-run. Best effort throughout: any failure leaves
# the clone at the branch head, which is the pre-generation behavior.
GEN_KEY='{"run_id":{"S":"_fleet-generation"}}'
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STALE=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)

gen_ref() {
    aws dynamodb get-item --region ${region} --table-name ${runs_table}         --key "$GEN_KEY" --output text         --query "[item.ref.S, item.heartbeat_at.S] | join(' ', @)" 2>/dev/null || true
}

GEN=$(gen_ref)
REF=$${GEN%% *}
BEAT=$${GEN##* }
if [ -z "$REF" ] || [ "$BEAT" \< "$STALE" ]; then
    # no live generation: start one from the last CI-green sha
    CANDIDATE=$(aws ssm get-parameter --region ${region} --name /pkgeval/worker-ref                 --query Parameter.Value --output text 2>/dev/null || true)
    [ -z "$CANDIDATE" ] && CANDIDATE=$(sudo -u worker git -C /home/worker/PkgEvalFarm.jl rev-parse HEAD)
    aws dynamodb update-item --region ${region} --table-name ${runs_table}         --key "$GEN_KEY"         --condition-expression "attribute_not_exists(#r) OR heartbeat_at < :stale"         --update-expression "SET #r = :sha, heartbeat_at = :now"         --expression-attribute-names '{"#r":"ref"}'         --expression-attribute-values "{\":sha\":{\"S\":\"$CANDIDATE\"},\":now\":{\"S\":\"$NOW\"},\":stale\":{\"S\":\"$STALE\"}}"         2>/dev/null || true   # lost the race: the winner's ref is authoritative
    GEN=$(gen_ref)
    REF=$(cut -f1 <<<"$GEN")
    [ "$REF" = "None" ] && REF=""
fi
if [ -n "$REF" ]; then
    echo "fleet generation ref: $REF"
    sudo -u worker git -C /home/worker/PkgEvalFarm.jl fetch -q origin "$REF"         && sudo -u worker git -C /home/worker/PkgEvalFarm.jl checkout -q "$REF"         || echo "could not check out $REF; staying on the clone head" >&2
fi

# --- worker sysimage ---------------------------------------------------------
# CI publishes a sysimage per (commit, Julia version) holding the worker and its
# dependencies; loading it turns ~80s of precompilation on every launch into a
# download from S3 within the region. That cost is paid on every spot
# replacement and every scale-out, which is what makes it worth the machinery.
#
# All of this is best effort: no image for this commit, a Julia patch release
# CI has not built for yet, a failed download or an image that refuses to load
# all end with SYSIMAGE empty and the worker precompiling exactly as before --
# slower, never broken.
JULIA=/home/worker/.juliaup/bin/julia
SYSIMAGE=

# packages and artifacts, but no precompilation -- see below
fetch_deps() {
  sudo -u worker -H bash -c \
    "cd ~/PkgEvalFarm.jl && JULIA_PKG_PRECOMPILE_AUTO=0 \
       $JULIA --project=. -e 'using Pkg; Pkg.instantiate()'"
}

# the slow path this whole section exists to avoid
precompile_deps() {
  sudo -u worker -H bash -c \
    "cd ~/PkgEvalFarm.jl && $JULIA --project=. -e 'using Pkg; Pkg.instantiate()'"
}

loads_from_sysimage() {
  sudo -u worker -H bash -c \
    "cd ~/PkgEvalFarm.jl && $JULIA -J$SYSIMAGE --project=. -e 'using PkgEvalFarm'"
}

if [ -n "${sysimage_bucket}" ]; then
  sha=$(sudo -u worker -H git -C /home/worker/PkgEvalFarm.jl rev-parse HEAD)
  ver=$(sudo -u worker -H $JULIA --startup-file=no -e 'print(VERSION)')
  key="sysimage/$sha/pkgevalfarm-julia-$ver-$(uname -m).so"
  # /opt, not the worker's home: the worker loads this image but must not be
  # able to rewrite it
  mkdir -p /opt/pkgeval
  if aws s3 cp --only-show-errors --region ${region} \
       "s3://${sysimage_bucket}/$key" /opt/pkgeval/sysimage.so; then
    SYSIMAGE=/opt/pkgeval/sysimage.so
  else
    echo "no sysimage published for $key; will precompile instead" >&2
  fi
fi

# Order matters: the packages and *artifacts* must be on disk before anything
# starts julia with the sysimage. Baked-in JLL `__init__`s resolve their
# artifact paths in the depot at startup, so on a fresh machine `julia -J`
# aborts during init -- before it could run the instantiate that would have
# installed them. Fetching with precompilation disabled puts both in place
# without paying the cost the sysimage exists to avoid.
if [ -n "$SYSIMAGE" ] && fetch_deps && loads_from_sysimage; then
  echo "using sysimage $SYSIMAGE"
else
  SYSIMAGE=
  rm -f /opt/pkgeval/sysimage.so
  precompile_deps
fi

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
$${SYSIMAGE:+PKGEVAL_SYSIMAGE=$SYSIMAGE}
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
# PKGEVAL_SYSIMAGE (if cloud-init got one) comes from the EnvironmentFile below;
# bin/farm passes it to julia as -J
Environment=AWS_REGION=${region}
Environment=PKGEVAL_QUEUE_URL=${queue_url}
Environment=PKGEVAL_SLOW_QUEUE_URL=${slow_queue_url}
Environment=PKGEVAL_SEAL_QUEUE_URL=${seal_queue_url}
# local sealed-artifact cache on the instance volume (survives across jobs,
# swept by age at worker start)
Environment=PKGEVAL_SEAL_CACHE=/var/cache/pkgeval-seal
# fleet-drain coordination: the worker manages its own ASG scale-in protection
Environment=PKGEVAL_BUILD_REQUEST_FUNCTION=${build_request_function}
# graceful drain: ExecStop (and the spot-notice watcher) touch this file; the
# worker fast-releases every claimed message and exits, so a dying host's jobs
# redeliver in seconds instead of after the 30-minute visibility timeout
Environment=PKGEVAL_DRAIN_FILE=/run/pkgeval/drain
Environment=PKGEVAL_ASG_NAME=${asg_name}
Environment=PKGEVAL_INSTANCE_ID=$INSTANCE_ID
# type + AZ let the worker look up its own spot price for per-job cost attribution
Environment=PKGEVAL_INSTANCE_TYPE=$INSTANCE_TYPE
Environment=PKGEVAL_AZ=$INSTANCE_AZ
Environment=PKGEVAL_RUNS_TABLE=${runs_table}
Environment=PKGEVAL_JOBS_TABLE=${jobs_table}
Environment=PKGEVAL_BUCKET=${bucket}
# PKGEVAL_CREDS_URL/_TOKEN: credentials come from the bearer-gated local proxy
# (IMDS itself is firewalled to root); the token file is root:worker 640 and
# systemd injects it, so it never exists in sandbox-visible files or env
EnvironmentFile=/etc/pkgeval-worker.env
RuntimeDirectory=pkgeval
RuntimeDirectoryPreserve=yes
# a drain file left over from the previous stop must not kill the new worker
ExecStartPre=/bin/rm -f /run/pkgeval/drain
ExecStart=/home/worker/PkgEvalFarm.jl/bin/farm worker
# stop sequence: request the drain, give the worker up to 60s to fast-release
# and exit cleanly; only then does systemd escalate to SIGTERM/SIGKILL
ExecStop=/bin/sh -c 'touch /run/pkgeval/drain; for i in \$\$(seq 60); do kill -0 \$MAINPID 2>/dev/null || exit 0; sleep 1; done'
TimeoutStopSec=90
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

# Spot interruptions give a 2-minute warning through IMDS (root-only here);
# turning it into a normal `systemctl stop` gives the worker the whole window
# to drain instead of the few seconds an ACPI shutdown leaves.
cat >/usr/local/bin/pkgeval-spot-watch <<'SPOT'
#!/bin/bash
while true; do
    TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token                  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    CODE=$(curl -s -o /dev/null -w '%%{http_code}'                 -H "X-aws-ec2-metadata-token: $TOKEN"                 http://169.254.169.254/latest/meta-data/spot/instance-action)
    if [ "$CODE" = "200" ]; then
        echo "spot interruption notice received; draining the worker"
        systemctl stop pkgeval-worker
        exit 0
    fi
    sleep 5
done
SPOT
chmod 755 /usr/local/bin/pkgeval-spot-watch

cat >/etc/systemd/system/pkgeval-spot-watch.service <<UNIT
[Unit]
Description=Drain the PkgEval worker on spot interruption notice
After=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/pkgeval-spot-watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pkgeval-imds-proxy
systemctl enable --now pkgeval-spot-watch
systemctl enable --now pkgeval-worker
