#!/usr/bin/env bash
# =============================================================================
# Script 7 — Cleanup GCP Resources
# =============================================================================
# Usage: bash scripts/7-cleanup-gcp.sh
#
# This script removes all GCP resources created by script 2:
#   - Interconnect attachment (VLAN)
#   - Cloud Router
#   - VM instance
#   - Firewall rule
#   - Subnet
#   - VPC network
#
# WARNING: This action is irreversible.
# =============================================================================

set -euo pipefail

# ─── Debug mode ──────────────────────────────────────────────────────────────
if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
fi

trap 'rc=$?; echo ""; echo "================================================"; echo "ERROR: Script failed at line ${LINENO} (exit code $rc)"; echo "  Last command: ${BASH_COMMAND}"; echo "  Hint: Re-run with DEBUG=1 to trace all commands:"; echo "    DEBUG=1 bash scripts/7-cleanup-gcp.sh"; echo "================================================"; exit $rc' ERR

# ─── Parameters (must match values used in script 2) ─────────────────────────
region=us-central1
zone=us-central1-c
envname=lab-erscale

# ─── Verify gcloud authentication ────────────────────────────────────────────
echo ""
echo "=== Checking gcloud authentication ==="
if ! command -v gcloud &>/dev/null; then
    echo "ERROR: gcloud CLI not found. See script 2 for installation instructions."
    exit 1
fi

activeAccount=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [[ -z "$activeAccount" ]]; then
    echo "ERROR: No active gcloud account. Run:  gcloud auth login"
    exit 1
fi
echo "  Active account: $activeAccount"
echo ""

# ─── Detect or prompt for project ────────────────────────────────────────────
detectedProject=$(gcloud config get-value project 2>/dev/null || true)

if [[ -n "$detectedProject" ]]; then
    echo "  Detected GCP project: $detectedProject"
    read -r -p "  Use this project? [Y/n]: " use_detected
    use_detected="${use_detected:-Y}"
    if [[ "${use_detected,,}" == "y" ]]; then
        project="$detectedProject"
    else
        read -r -p "  Enter GCP project ID: " project
    fi
else
    read -r -p "  Enter GCP project ID: " project
fi

gcloud config set project "$project" --quiet
echo ""

# ─── Confirm destructive action ───────────────────────────────────────────────
echo "============================================================"
echo "  WARNING: The following GCP resources will be deleted:"
echo "  Project  : $project"
echo "  Prefix   : $envname"
echo "  Resources: ${envname}-vlan (attachment), ${envname}-router,"
echo "             ${envname}-vm1, ${envname}-allow-azure (firewall),"  echo "             ${envname}-allow-iap-ssh (firewall),"echo "             ${envname}-subnet, ${envname}-vpc"
echo "============================================================"
echo ""
read -r -p "Type 'yes' to confirm deletion: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Confirmation did not match. Aborting."
    exit 1
fi
echo ""

# ─── Start Timer ─────────────────────────────────────────────────────────────
start=$(date +%s)

# ─── Delete Interconnect Attachment ──────────────────────────────────────────
echo "=== Deleting interconnect attachment: ${envname}-vlan ==="
if gcloud compute interconnects attachments describe "${envname}-vlan" \
    --region "$region" --project "$project" &>/dev/null; then
    gcloud compute interconnects attachments delete "${envname}-vlan" \
        --region "$region" --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

# ─── Delete Cloud Router ──────────────────────────────────────────────────────
echo "=== Deleting Cloud Router: ${envname}-router ==="
if gcloud compute routers describe "${envname}-router" \
    --region "$region" --project "$project" &>/dev/null; then
    gcloud compute routers delete "${envname}-router" \
        --region "$region" --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

# ─── Delete VM ───────────────────────────────────────────────────────────────
echo "=== Deleting VM: ${envname}-vm1 ==="
if gcloud compute instances describe "${envname}-vm1" \
    --zone "$zone" --project "$project" &>/dev/null; then
    gcloud compute instances delete "${envname}-vm1" \
        --zone "$zone" --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

# ─── Delete Firewall Rules ───────────────────────────────────────────────────
echo "=== Deleting firewall rule: ${envname}-allow-iap-ssh ==="
if gcloud compute firewall-rules describe "${envname}-allow-iap-ssh" \
    --project "$project" &>/dev/null; then
    gcloud compute firewall-rules delete "${envname}-allow-iap-ssh" \
        --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

echo "=== Deleting firewall rule: ${envname}-allow-azure ==="
if gcloud compute firewall-rules describe "${envname}-allow-azure" \
    --project "$project" &>/dev/null; then
    gcloud compute firewall-rules delete "${envname}-allow-azure" \
        --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

# ─── Delete Subnet ────────────────────────────────────────────────────────────
echo "=== Deleting subnet: ${envname}-subnet ==="
if gcloud compute networks subnets describe "${envname}-subnet" \
    --region "$region" --project "$project" &>/dev/null; then
    gcloud compute networks subnets delete "${envname}-subnet" \
        --region "$region" --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

# ─── Delete VPC ───────────────────────────────────────────────────────────────
echo "=== Deleting VPC network: ${envname}-vpc ==="
if gcloud compute networks describe "${envname}-vpc" \
    --project "$project" &>/dev/null; then
    gcloud compute networks delete "${envname}-vpc" \
        --project "$project" --quiet
    echo "  Deleted."
else
    echo "  Not found — skipping."
fi
echo ""

# ─── Elapsed Time ─────────────────────────────────────────────────────────────
end=$(date +%s)
runtime=$((end - start))
echo "============================================================"
echo "  GCP CLEANUP COMPLETE"
echo "============================================================"
echo "  Project  : $project"
echo "  Prefix   : $envname"
echo "  Region   : $region"
echo ""
echo "  Total time: $((runtime / 60)) min $((runtime % 60)) sec"
echo "============================================================"
