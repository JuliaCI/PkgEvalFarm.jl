#!/bin/bash
# cloud-init for a self-enrolling PkgEval test worker (Ubuntu 24.04).
set -eux

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

sudo -u worker bash -c 'curl -fsSL https://install.julialang.org | sh -s -- -y --default-channel ${julia_channel}'
sudo -u worker git clone --branch ${farm_ref} ${farm_repo} /home/worker/PkgEvalFarm.jl
sudo -u worker bash -c 'cd ~/PkgEvalFarm.jl && ~/.juliaup/bin/julia --project=. -e "using Pkg; Pkg.instantiate()"'

# No enrollment/broker needed on EC2: the instance profile carries the worker
# policy, and the farm CLI's env-bypass mode picks it up via the ambient AWS
# credential chain (IMDS).
cat >/etc/systemd/system/pkgeval-worker.service <<UNIT
[Unit]
Description=PkgEval farm worker
After=network-online.target
Wants=network-online.target

[Service]
User=worker
# PkgEval needs a delegated cgroup v2 subtree for per-job resource limits
Delegate=yes
TasksMax=infinity
LimitNOFILE=1048576
Environment=JULIA=/home/worker/.juliaup/bin/julia
Environment=AWS_REGION=${region}
Environment=PKGEVAL_QUEUE_URL=${queue_url}
Environment=PKGEVAL_RUNS_TABLE=${runs_table}
Environment=PKGEVAL_JOBS_TABLE=${jobs_table}
Environment=PKGEVAL_BUCKET=${bucket}
ExecStart=/home/worker/PkgEvalFarm.jl/bin/farm worker
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now pkgeval-worker
