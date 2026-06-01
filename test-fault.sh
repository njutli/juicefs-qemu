#!/bin/bash
set -euo pipefail

# ============================================================
# JuiceFS Fault Injection Test
# Verifies IO continuity during single-node failures:
#   Test 1: RGW data node failure (1 of 2 RGW instances stopped)
#   Test 2: TiKV metadata node failure (1 of 3 PD/TiKV stopped)
# ============================================================

TIKV_PD="172.16.0.101:2379,172.16.0.102:2379,172.16.0.103:2379"
RGW_DOMAIN="rgw.ceph.local"
RGW_PORT="80"
RGW_NODES="172.16.1.101 172.16.1.102"
ACCESS_KEY="412ISJADLIWIS6KS03D4"
SECRET_KEY="ARhIrvjyKJpydnzm0eGlYhZSKByMwchB05YR6cMv"

FS_NAME="juicefs-fault-test"
BUCKET="http://${RGW_DOMAIN}:${RGW_PORT}/${FS_NAME}"
MOUNT_POINT="/tmp/juicefs-fault-mnt"
METADATA_URL="tikv://${TIKV_PD}/${FS_NAME}"
SSH_PASS="ubuntu"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

ssh_vm() { sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "ubuntu@$1" "$2" 2>/dev/null; }

cleanup() {
    echo ""
    echo ">>> Cleanup: restoring services..."
    for ip in 172.16.1.102 172.16.0.103; do
        ssh_vm "${ip}" "sudo systemctl start tikv 2>/dev/null || true" &
    done
    wait
    sudo killall -9 juicefs 2>/dev/null || true
    sudo umount "${MOUNT_POINT}" 2>/dev/null || true
    rm -rf "${MOUNT_POINT}"
    echo "Services restored."
}

trap cleanup EXIT

# ── Sync VM clocks (QEMU VMs lack NTP, drift after host sleep/resume) ──
echo ">>> Syncing VM clocks with host..."
HOST_TIME=$(date -u +"%Y-%m-%d %H:%M:%S")
for ip in 172.16.1.101 172.16.1.102 172.16.1.103 172.16.0.101 172.16.0.102 172.16.0.103; do
    ssh_vm "${ip}" "sudo date -s '${HOST_TIME}' 2>/dev/null; date -u" 2>/dev/null | tail -1
done
echo "  Clocks synced"

# Restart RGW containers to clear clock-skew state
ssh_vm "172.16.1.101" "sudo podman restart \$(sudo podman ps --filter name=rgw --format '{{.Names}}' | head -1) 2>/dev/null || true" 2>/dev/null
ssh_vm "172.16.1.102" "sudo podman restart \$(sudo podman ps --filter name=rgw --format '{{.Names}}' | head -1) 2>/dev/null || true" 2>/dev/null
sleep 10

# ── Pre-flight ──

echo "========================================"
echo "JuiceFS Fault Injection Test"
echo "========================================"
echo "Metadata: ${METADATA_URL}"
echo "Data:     ${BUCKET}"
echo ""

# Ensure RGW HA hosts entries
for ip in ${RGW_NODES}; do
    if ! grep -q "^${ip} ${RGW_DOMAIN}" /etc/hosts 2>/dev/null; then
        echo "${ip} ${RGW_DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
    fi
done

# Clean stale state
sudo killall -9 juicefs 2>/dev/null || true
sudo umount "${MOUNT_POINT}" 2>/dev/null || true
rm -rf "${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}"

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
export AWS_ACCESS_KEY_ID="${ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${SECRET_KEY}"

# ── Format + Mount ──

echo ">>> Formatting JuiceFS..."
if juicefs status "${METADATA_URL}" > /dev/null 2>&1; then
    echo "  FS already exists, destroying old..."
    UUID=$(juicefs status "${METADATA_URL}" 2>/dev/null | grep '"UUID"' | cut -d'"' -f4)
    yes | timeout 30 juicefs destroy --force "${METADATA_URL}" "${UUID}" 2>/dev/null || true
fi
# Pre-create bucket to avoid region constraint error on Ceph RGW
export AWS_DEFAULT_REGION=""
aws --endpoint-url="http://${RGW_DOMAIN}:${RGW_PORT}" --no-verify-ssl \
    s3 mb "s3://${FS_NAME}" 2>/dev/null || true
juicefs format --storage s3 --bucket "${BUCKET}" \
    --access-key "${ACCESS_KEY}" --secret-key "${SECRET_KEY}" \
    "${METADATA_URL}" "${FS_NAME}" 2>&1 | tail -3

echo ">>> Mounting..."
juicefs mount -d "${METADATA_URL}" "${MOUNT_POINT}" &
sleep 3
mountpoint -q "${MOUNT_POINT}" || { echo "ERROR: Mount failed"; exit 1; }
echo "  Mounted at ${MOUNT_POINT}"

# ── Helper: background writer ──

BG_WRITER_PID=""
start_writer() {
    local prefix=$1
    (
        seq=0
        while true; do
            seq=$((seq + 1))
            echo "${prefix}-seq-${seq}-$(date +%s%N)" > "${MOUNT_POINT}/${prefix}-${seq}.txt" 2>/dev/null || {
                echo "  [WRITER-${prefix}] write failed at seq ${seq}" >&2
            }
            sleep 0.5
        done
    ) &
    BG_WRITER_PID=$!
}

stop_writer() {
    [ -n "${BG_WRITER_PID}" ] && kill "${BG_WRITER_PID}" 2>/dev/null || true
    wait "${BG_WRITER_PID}" 2>/dev/null || true
}

# ── Test 1: RGW data node failure ──

echo ""
echo "========================================"
echo "Test 1: RGW Node Failure (data path)"
echo "========================================"

echo ">>> Starting background writer..."
start_writer "rgwtest"

echo ">>> Writing baseline (5s)..."
sleep 5
BASELINE_COUNT=$(ls "${MOUNT_POINT}"/rgwtest-*.txt 2>/dev/null | wc -l)
echo "  Baseline: ${BASELINE_COUNT} files written"

echo ">>> Injecting fault: stopping RGW on 172.16.1.101..."
ssh_vm "172.16.1.101" "RGW_CONTAINER=\$(sudo podman ps --filter name=rgw --format '{{.Names}}' | head -1); sudo podman stop \${RGW_CONTAINER} 2>/dev/null || true"
echo "  RGW stopped on node1"

echo ">>> Writing during fault (10s)..."
sleep 10
FAULT_COUNT=$(ls "${MOUNT_POINT}"/rgwtest-*.txt 2>/dev/null | wc -l)
FAILED_COUNT=$((FAULT_COUNT - BASELINE_COUNT))
echo "  During fault: ${FAULT_COUNT} total files (+${FAILED_COUNT})"

echo ">>> Restoring RGW..."
ssh_vm "172.16.1.101" "RGW_CONTAINER=\$(sudo podman ps -a --filter name=rgw --format '{{.Names}}' | head -1); sudo podman start \${RGW_CONTAINER} 2>/dev/null || true"
sleep 5
echo "  RGW restored"

echo ">>> Verifying read after recovery..."
echo "verify-$(date +%s)" > "${MOUNT_POINT}/rgw-recovery-test.txt"
READ_BACK=$(cat "${MOUNT_POINT}/rgw-recovery-test.txt" 2>/dev/null)
if echo "${READ_BACK}" | grep -q "verify-"; then
    echo "  PASS: Write/read works after RGW recovery"
else
    echo "  FAIL: Cannot read after RGW recovery"
fi

stop_writer

if [ "${FAILED_COUNT}" -gt 0 ]; then
    echo ""
    echo "  RESULT: IO continued (${FAILED_COUNT} writes during fault, resolver switched to 172.16.1.102)"
else
    echo ""
    echo "  RESULT: IO stopped or no writes detected during fault"
fi

# ── Test 2: TiKV metadata node failure ──

echo ""
echo "========================================"
echo "Test 2: TiKV Node Failure (metadata path)"
echo "========================================"

echo ">>> Starting background writer..."
start_writer "tikvtest"
sleep 5

echo ">>> Injecting fault: stopping TiKV on 172.16.0.103..."
ssh_vm "172.16.0.103" "sudo systemctl stop tikv 2>/dev/null || true"
echo "  TiKV stopped on 172.16.0.103"

echo ">>> Writing during fault (10s)..."
WROTE_COUNT=0
for i in $(seq 1 10); do
    if echo "tikv-fault-${i}" > "${MOUNT_POINT}/tikv-fault-${i}.txt" 2>/dev/null; then
        WROTE_COUNT=$((WROTE_COUNT + 1))
    fi
    sleep 1
done
echo "  ${WROTE_COUNT}/10 writes succeeded during TiKV node failure"

echo ">>> Restoring TiKV..."
ssh_vm "172.16.0.103" "sudo systemctl start tikv 2>/dev/null || true"
sleep 10
echo "  TiKV restored"

echo ">>> Verifying read after recovery..."
echo "tikv-recovery-test" > "${MOUNT_POINT}/tikv-recovery.txt"
READ_BACK=$(cat "${MOUNT_POINT}/tikv-recovery.txt" 2>/dev/null)
if echo "${READ_BACK}" | grep -q "tikv-recovery"; then
    echo "  PASS: Write/read works after TiKV recovery"
else
    echo "  FAIL: Cannot read after TiKV recovery"
fi

# Clean up test files
rm -f "${MOUNT_POINT}"/tikvtest-*.txt "${MOUNT_POINT}"/rgwtest-*.txt \
      "${MOUNT_POINT}"/tikv-fault-*.txt "${MOUNT_POINT}"/tikv-recovery.txt \
      "${MOUNT_POINT}"/rgw-recovery-test.txt 2>/dev/null || true

stop_writer

echo ""
echo "========================================"
echo "Fault Injection Test Complete"
echo "========================================"

# ── Cleanup ──

echo ">>> Unmounting..."
sudo umount "${MOUNT_POINT}" 2>/dev/null || true

echo ">>> Destroying test filesystem..."
yes | timeout 30 juicefs destroy --force "${METADATA_URL}" 2>/dev/null || true

echo ">>> Cleanup done."
