#!/bin/bash
# The 16384-byte EC2 user-data limit bit us live (a comment pushed the raw
# worker script over the edge; gzipping bought headroom, see 94eb33d). Guard
# the margin: evaluate the exact expression ec2_workers.tf ships —
# base64gzip(templatefile(...)) — with oversized dummy values and require
# clearance under the limit. Adding a template variable makes the render fail
# here until the dummy list below learns about it; that's intentional.
set -eu
tpl=$(realpath "${1:-ec2_worker_userdata.sh.tpl}")
u80=$(printf 'u%.0s' {1..80}) # longer than any real queue URL/ARN/name
expr="length(base64gzip(templatefile(\"$tpl\", {
  region = \"us-east-2\", queue_url = \"$u80\", slow_queue_url = \"$u80\",
  seal_queue_url = \"$u80\", asg_name = \"$u80\", build_request_function = \"$u80\",
  runs_table = \"$u80\", jobs_table = \"$u80\", bucket = \"$u80\",
  farm_repo = \"$u80\", farm_ref = \"$u80\", julia_channel = \"$u80\",
  sysimage_bucket = \"$u80\" })))"
# an empty dir: console must see no config, so the expression alone evaluates
size=$(cd "$(mktemp -d)" && echo "$expr" | tofu console)
echo "user_data (base64, post-gzip): $size bytes (limit 16384)"
[ "$size" -lt 15000 ] || { echo "user data too close to the 16KB EC2 limit"; exit 1; }
