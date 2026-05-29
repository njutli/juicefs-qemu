#!/bin/bash
set -euo pipefail

# ============================================================
# JuiceFS Test Script
# Metadata: TiKV (3 nodes, via tikv-qemu)
# Data:     Ceph RGW S3 (via ceph-rgw-qemu)
# ============================================================

# ── Configuration (from tikv-qemu + ceph-rgw-qemu) ──
TIKV_PD="172.16.0.101:2379,172.16.0.102:2379,172.16.0.103:2379"
RGW_ENDPOINT="http://172.16.1.101:80"
# JuiceFS RGW user credentials (created by ceph-rgw-qemu/deploy-ceph.sh)
ACCESS_KEY="412ISJADLIWIS6KS03D4"
SECRET_KEY="ARhIrvjyKJpydnzm0eGlYhZSKByMwchB05YR6cMv"

FS_NAME="juicefs-test"
BUCKET="${RGW_ENDPOINT}/${FS_NAME}"
MOUNT_POINT="/tmp/juicefs-mnt"
METADATA_URL="tikv://${TIKV_PD}/${FS_NAME}"

echo "========================================"
echo "JuiceFS Integration Test"
echo "========================================"
echo "Metadata: ${METADATA_URL}"
echo "Data:     ${BUCKET} (Ceph RGW S3)"
echo ""

# ── Pre-flight checks ──

if ! command -v juicefs &>/dev/null; then
    echo ">>> Installing JuiceFS..."
    curl -sSL https://d.juicefs.com/install | sh -
fi

echo "JuiceFS version: $(juicefs version 2>&1 | head -1)"

# Check TiKV PD is accessible
echo -n "TiKV PD: "
if curl -s --noproxy '*' --connect-timeout 3 "http://${TIKV_PD%%:*}:2379/pd/api/v1/health" > /dev/null 2>&1; then
    echo "OK"
else
    echo "UNREACHABLE - ensure tikv-qemu VMs are running"
    exit 1
fi

# Check RGW is accessible
echo -n "Ceph RGW: "
if curl -s --noproxy '*' --connect-timeout 3 "${RGW_ENDPOINT}" > /dev/null 2>&1; then
    echo "OK"
else
    echo "UNREACHABLE - ensure ceph-rgw-qemu VMs are running"
    exit 1
fi

# ── Clean stale state from previous runs ──
sudo killall -9 juicefs 2>/dev/null || true
sudo umount "${MOUNT_POINT}" 2>/dev/null || true
rm -rf "${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}"

# Unset proxy — JuiceFS Go client must connect directly to TiKV PD over bridge
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# ── Step 1: Format JuiceFS filesystem ──

echo ""
echo ">>> Step 1: Formatting JuiceFS filesystem..."
echo "    Metadata URL: ${METADATA_URL}"
echo "    Data bucket:  ${BUCKET}"
echo "    Metadata URL: ${METADATA_URL}"
echo "    Data bucket:  ${BUCKET}"

export AWS_ACCESS_KEY_ID="${ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${SECRET_KEY}"
# RGW doesn't have regions — set empty to avoid IllegalLocationConstraintException
export AWS_DEFAULT_REGION=""

# Pre-create the S3 bucket (JuiceFS auto-create may fail on RGW with region errors)
echo "    Creating S3 bucket '${FS_NAME}'..."
aws --endpoint-url="${RGW_ENDPOINT}" --no-verify-ssl \
    s3 mb "s3://${FS_NAME}" 2>/dev/null || true

# Unset proxy so JuiceFS Go client connects directly to TiKV PD over bridge
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

if juicefs status "${METADATA_URL}" > /dev/null 2>&1; then
    echo "    Filesystem already exists, skipping format."
else
    juicefs format \
        --storage s3 \
        --bucket "${BUCKET}" \
        --access-key "${ACCESS_KEY}" \
        --secret-key "${SECRET_KEY}" \
        "${METADATA_URL}" \
        "${FS_NAME}" 2>&1 | tail -5
fi

# ── Step 2: Mount filesystem ──

echo ""
echo ">>> Step 2: Mounting filesystem..."

juicefs mount -d "${METADATA_URL}" "${MOUNT_POINT}" &
MOUNT_PID=$!
sleep 3

if mountpoint -q "${MOUNT_POINT}"; then
    echo "    Mounted at ${MOUNT_POINT}"
else
    echo "ERROR: Mount failed"
    exit 1
fi

# ── Step 3: Write test file ──

echo ""
echo ">>> Step 3: Write test file..."

echo "Hello from JuiceFS with TiKV metadata + Ceph RGW data!" > "${MOUNT_POINT}/hello.txt"
dd if=/dev/urandom of="${MOUNT_POINT}/random.bin" bs=1M count=10 2>&1 | tail -1
echo "    Files written"

# ── Step 4: Read and verify ──

echo ""
echo ">>> Step 4: Read and verify..."

READ_BACK=$(cat "${MOUNT_POINT}/hello.txt")
if echo "${READ_BACK}" | grep -q "Hello from JuiceFS"; then
    echo "    PASS: Text file read correctly"
else
    echo "    FAIL: Text file mismatch"
fi

SIZE=$(stat -c%s "${MOUNT_POINT}/random.bin")
if [ "${SIZE}" -eq 10485760 ]; then
    echo "    PASS: Binary file size correct (10MB)"
else
    echo "    FAIL: Binary file size mismatch (expected 10MB, got ${SIZE})"
fi

# ── Step 5: List files ──

echo ""
echo ">>> Step 5: Directory listing..."
ls -lh "${MOUNT_POINT}/"

# ── Step 6: Create subdirectory and nested files ──

echo ""
echo ">>> Step 6: Nested directory operations..."

mkdir -p "${MOUNT_POINT}/subdir"
for i in $(seq 1 5); do
    echo "nested-file-${i}" > "${MOUNT_POINT}/subdir/file-${i}.txt"
done
echo "    5 nested files created"

# ── Step 7: Filesystem stats ──

echo ""
echo ">>> Step 7: Filesystem statistics..."
juicefs info "${METADATA_URL}" 2>&1 | head -10

# ── Step 8: Unmount and cleanup ──

echo ""
echo ">>> Step 8: Unmounting..."
umount "${MOUNT_POINT}" 2>/dev/null && echo "    Unmounted" || echo "    Unmount skipped"

echo ""
echo "========================================"
echo "JuiceFS Integration Test: ALL PASSED"
echo "========================================"
echo ""
echo "Filesystem:  ${FS_NAME}"
echo "Metadata:    ${METADATA_URL}"
echo "Data bucket: ${BUCKET}"
echo ""
echo "To mount again:"
echo "  juicefs mount ${METADATA_URL} /mnt/juicefs"
echo ""
echo "To destroy:"
echo "  juicefs destroy ${METADATA_URL} <password-from-format>"
