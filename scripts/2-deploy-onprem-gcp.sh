#!/usr/bin/env bash
# =============================================================================
# Script 2 — Deploy On-Premises Simulation on GCP via Megaport Partner Interconnect
# =============================================================================
# Usage: bash scripts/2-deploy-onprem-gcp.azcli
#
# Pre-requisites:
#   - gcloud CLI authenticated: gcloud auth login
#   - Active GCP project with billing enabled
#   - Megaport account (for connecting GCP Interconnect ↔ Azure ER Circuit)
#
# This script:
#   1. Creates a GCP VPC and subnet (192.168.0.0/24 simulating on-prem)
#   2. Deploys a GCP VM (f1-micro, Ubuntu 20.04)
#   3. Creates Cloud Router (BGP ASN: 16550)
#   4. Creates a Megaport Partner Interconnect attachment
#   5. Outputs the pairing key for use in the Megaport portal
#
# CLEANUP SECTION is at the bottom of this file.
# =============================================================================

set -euo pipefail

# ─── Debug mode ──────────────────────────────────────────────────────────────
# Run with DEBUG=1 bash scripts/2-deploy-onprem-gcp.sh to trace every command.
if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
fi

# Trap any error and print the failing line number + last command so it's easy
# to pinpoint exactly where the script stopped.
trap 'rc=$?; echo ""; echo "================================================"; echo "ERROR: Script failed at line ${LINENO} (exit code $rc)"; echo "  Last command: ${BASH_COMMAND}"; echo "  Hint: Re-run with DEBUG=1 to trace all commands:"; echo "    DEBUG=1 bash scripts/2-deploy-onprem-gcp.sh"; echo "================================================"; exit $rc' ERR

# ─── Parameters ──────────────────────────────────────────────────────────────
region=us-central1           # GCP region (Chicago area maps to us-central1)
zone=us-central1-c           # Availability zone
vpcrange=192.168.0.0/24      # On-premises simulation range (matches Azure ER route advertisement)
envname=lab-erscale          # Environment name prefix

# ─── Verify gcloud authentication and credentials ───────────────────────────
echo ""
echo "=== Checking gcloud authentication ==="

# Check if gcloud CLI is available at all
if ! command -v gcloud &>/dev/null; then
    echo ""
    echo "ERROR: gcloud CLI not found. Install it first:"
    echo ""
    echo "  Option A — GCP Cloud Shell (recommended, no install needed):"
    echo "    Open https://shell.cloud.google.com"
    echo ""
    echo "  Option B — Local install (Linux / WSL):"
    echo "    curl https://sdk.cloud.google.com | bash"
    echo "    exec -l \$SHELL"
    echo "    gcloud init"
    echo ""
    echo "  Docs: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check for an active authenticated account
active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [[ -z "$active_account" ]]; then
    echo ""
    echo "ERROR: No active gcloud account found. Authenticate first:"
    echo ""
    echo "  Interactive login (browser opens):"
    echo "    gcloud auth login"
    echo ""
    echo "  Device code / headless login (e.g. SSH, WSL without browser):"
    echo "    gcloud auth login --no-launch-browser"
    echo ""
    echo "  Service account key:"
    echo "    gcloud auth activate-service-account --key-file=<path/to/key.json>"
    echo ""
    echo "  Docs: https://cloud.google.com/sdk/gcloud/reference/auth/login"
    exit 1
fi
echo "Logged in as: $active_account"

# Check Application Default Credentials (ADC) — needed for some API calls
if ! gcloud auth application-default print-access-token &>/dev/null; then
    echo ""
    echo "WARNING: Application Default Credentials (ADC) not configured."
    echo "Some API calls may fail. To set them up:"
    echo "  gcloud auth application-default login"
    echo ""
    echo "  (In Cloud Shell, ADC is configured automatically — you can ignore this warning)"
    echo ""
fi

# Try to grab the project already configured in the active session
session_project=$(gcloud config get-value project 2>/dev/null || echo "")

if [[ -n "$session_project" && "$session_project" != "(unset)" ]]; then
    echo ""
    read -r -p "GCP Project ID [$session_project]: " project_input
    project="${project_input:-$session_project}"
else
    echo ""
    echo "Available projects:"
    gcloud projects list --format="table(projectId,name)" 2>/dev/null || true
    echo ""
    read -r -p "GCP Project ID: " project_input
    if [[ -z "$project_input" ]]; then
        echo "ERROR: A GCP project ID is required."
        exit 1
    fi
    project="$project_input"
fi

echo ""
echo "  GCP Account : $active_account"
echo "  GCP Project : $project"
echo ""

# ─── Configure GCP Project ───────────────────────────────────────────────────
echo "=== Configuring GCP project: $project ==="
gcloud config set project "$project"

# ─── Create VPC and Subnet (idempotent) ─────────────────────────────────────
echo ""
echo "=== Ensuring GCP VPC exists ==="
if gcloud compute networks describe "${envname}-vpc" --format="value(name)" &>/dev/null; then
    echo "  VPC '${envname}-vpc' already exists — skipping."
else
    gcloud compute networks create "${envname}-vpc" \
        --subnet-mode=custom \
        --mtu=1460 \
        --bgp-routing-mode=regional \
        --quiet
    echo "  VPC created: ${envname}-vpc"
fi

echo "=== Ensuring subnet exists ==="
if gcloud compute networks subnets describe "${envname}-subnet" --region="$region" --format="value(name)" &>/dev/null; then
    echo "  Subnet '${envname}-subnet' already exists — skipping."
else
    gcloud compute networks subnets create "${envname}-subnet" \
        --range="$vpcrange" \
        --network="${envname}-vpc" \
        --region="$region" \
        --quiet
    echo "  Subnet created: ${envname}-subnet ($vpcrange)"
fi

# ─── Create Firewall Rules (idempotent) ──────────────────────────────────────
echo ""
echo "=== Ensuring firewall rules exist ==="
if gcloud compute firewall-rules describe "${envname}-allow-azure" --format="value(name)" &>/dev/null; then
    echo "  Firewall rule '${envname}-allow-azure' already exists — skipping."
else
    # Allow traffic from Azure VNets (10.0.0.0/8) and RFC1918 ranges
    gcloud compute firewall-rules create "${envname}-allow-azure" \
        --network "${envname}-vpc" \
        --allow tcp,udp,icmp \
        --source-ranges "192.168.0.0/16,10.0.0.0/8,172.16.0.0/12" \
        --description "Allow traffic from Azure VNets via ExpressRoute" \
        --quiet
    echo "  Firewall rule '${envname}-allow-azure' created."
fi

if gcloud compute firewall-rules describe "${envname}-allow-iap-ssh" --format="value(name)" &>/dev/null; then
    echo "  Firewall rule '${envname}-allow-iap-ssh' already exists — skipping."
else
    # Allow Cloud IAP SSH tunnels (required for 'gcloud compute ssh' via IAP)
    # Source range 35.235.240.0/20 is Google's IAP forwarder range
    gcloud compute firewall-rules create "${envname}-allow-iap-ssh" \
        --network "${envname}-vpc" \
        --allow tcp:22 \
        --source-ranges "35.235.240.0/20" \
        --description "Allow SSH via Cloud Identity-Aware Proxy (IAP)" \
        --quiet
    echo "  Firewall rule '${envname}-allow-iap-ssh' created."
fi

# ─── Create Ubuntu VM (idempotent) ───────────────────────────────────────────
echo ""
echo "=== Ensuring GCP VM exists ==="
# Search across all zones in the region so we don't create a duplicate if the
# VM was previously placed in a fallback zone.
existing_zone=$(gcloud compute instances list \
    --filter="name=${envname}-vm1 AND zone:($region)" \
    --format="value(zone)" \
    --limit=1 2>/dev/null | head -1)

if [[ -n "$existing_zone" ]]; then
    echo "  VM '${envname}-vm1' already exists in zone $existing_zone — skipping creation."
    zone="$existing_zone"
else
    echo "=== Creating GCP VM (on-premises simulation) ==="

    # Resolve the latest Ubuntu 24.04 LTS image dynamically so the script never
    # pins to a stale image version.
    echo "  Resolving latest Ubuntu 24.04 LTS image..."
    ubuntu_image=$(gcloud compute images list \
        --project=ubuntu-os-cloud \
        --filter="family=ubuntu-2404-lts-amd64 AND status=READY" \
        --sort-by="~creationTimestamp" \
        --format="value(name)" \
        --limit=1 2>/dev/null)

    if [[ -z "$ubuntu_image" ]]; then
        echo "  ubuntu-2404-lts-amd64 not found, falling back to ubuntu-2204-lts..."
        ubuntu_image=$(gcloud compute images list \
            --project=ubuntu-os-cloud \
            --filter="family=ubuntu-2204-lts AND status=READY" \
            --sort-by="~creationTimestamp" \
            --format="value(name)" \
            --limit=1 2>/dev/null)
    fi

    if [[ -z "$ubuntu_image" ]]; then
        echo "ERROR: Could not resolve any Ubuntu LTS image. Check your gcloud auth and API access."
        exit 1
    fi
    echo "  Using image: $ubuntu_image"

    # f1-micro is a legacy shared-core type and may not be available in all zones.
    # Prefer e2-micro (modern equivalent, also free-tier eligible); fall back to
    # e2-small if neither is available.
    echo "  Checking machine type availability in zone: $zone..."
    machine_type=""
    for candidate in e2-micro f1-micro e2-small; do
        if gcloud compute machine-types describe "$candidate" --zone="$zone" \
            --format="value(name)" &>/dev/null; then
            machine_type="$candidate"
            echo "  Using machine type: $machine_type"
            break
        fi
        echo "  $candidate not available in $zone, trying next..."
    done

    if [[ -z "$machine_type" ]]; then
        echo "ERROR: No suitable small machine type found in zone $zone."
        echo "  Try a different zone, e.g.: zone=us-central1-a"
        exit 1
    fi

    # Try the preferred zone first, then fall back to other zones in the region
    # if the zone has insufficient resources (ZONE_RESOURCE_POOL_EXHAUSTED).
    fallback_zones=("us-central1-c" "us-central1-a" "us-central1-b" "us-central1-f")
    vm_created=false
    for try_zone in "${fallback_zones[@]}"; do
        echo "  Creating instance '${envname}-vm1' in zone $try_zone ..."
        create_output=$(gcloud compute instances create "${envname}-vm1" \
            --zone="$try_zone" \
            --machine-type="$machine_type" \
            --network-interface=subnet="${envname}-subnet",network-tier=PREMIUM \
            --image="$ubuntu_image" \
            --image-project=ubuntu-os-cloud \
            --boot-disk-size=10GB \
            --boot-disk-type=pd-balanced \
            --boot-disk-device-name="${envname}-vm1" \
            --quiet 2>&1) && vm_created=true && zone="$try_zone" && break

        if echo "$create_output" | grep -q "ZONE_RESOURCE_POOL_EXHAUSTED"; then
            echo "  Zone $try_zone has insufficient resources — trying next zone..."
        else
            echo "$create_output" >&2
            exit 1
        fi
    done

    if ! $vm_created; then
        echo "ERROR: Could not create VM in any zone: ${fallback_zones[*]}"
        echo "  Try again later or specify a different region."
        exit 1
    fi
    echo "  VM created in zone: $zone"
fi

# Get VM internal IP
vmInternalIp=$(gcloud compute instances describe "${envname}-vm1" \
    --zone="$zone" \
    --format="value(networkInterfaces[0].networkIP)")
echo "  VM Internal IP: $vmInternalIp"

# ─── Create Cloud Router (idempotent) ────────────────────────────────────────
echo ""
echo "=== Ensuring Cloud Router exists ==="
if gcloud compute routers describe "${envname}-router" --region="$region" --format="value(name)" &>/dev/null; then
    echo "  Cloud Router '${envname}-router' already exists — skipping."
else
    # ASN 16550 is required for Google Cloud Partner Interconnect
    gcloud compute routers create "${envname}-router" \
        --region="$region" \
        --network="${envname}-vpc" \
        --asn=16550 \
        --quiet
    echo "  Cloud Router created (ASN 16550)."
fi

# ─── Create Partner Interconnect Attachment (idempotent) ─────────────────────
echo ""
echo "=== Ensuring Partner Interconnect attachment exists ==="
if gcloud compute interconnects attachments describe "${envname}-vlan" --region="$region" --format="value(name)" &>/dev/null; then
    echo "  Attachment '${envname}-vlan' already exists — skipping."
else
    gcloud compute interconnects attachments partner create "${envname}-vlan" \
        --region "$region" \
        --edge-availability-domain availability-domain-1 \
        --router "${envname}-router" \
        --admin-enabled \
        --quiet
    echo "  Attachment created."
fi

# ─── Display Pairing Key ─────────────────────────────────────────────────────
echo ""
echo "=== Partner Interconnect pairing key ==="
pairingKey=$(gcloud compute interconnects attachments describe "${envname}-vlan" \
    --region "$region" \
    --format="value(pairingKey)")

echo "  Pairing Key: $pairingKey"
echo ""
echo "  *** ACTION REQUIRED ***"
echo "  Use this pairing key in the Megaport portal to connect this GCP"
echo "  attachment to the Azure ExpressRoute Circuit (Service Key from script 1)."
echo "  See: https://docs.megaport.com/cloud/google-cloud/"
echo ""

# ─── Show Interconnect Status ─────────────────────────────────────────────────
echo "=== Interconnect attachment status ==="
gcloud compute interconnects attachments describe "${envname}-vlan" --region "$region"

echo ""
echo "============================================================"
echo "  GCP ON-PREMISES SIMULATION DEPLOYED"
echo "============================================================"
echo "  VPC:         ${envname}-vpc"
echo "  Subnet:      $vpcrange"
echo "  VM:          ${envname}-vm1  ($vmInternalIp)"
echo "  Router ASN:  16550"
echo "  Attachment:  ${envname}-vlan"
echo ""
echo "  *** PARTNER INTERCONNECT PAIRING KEY ***"
echo "  $pairingKey"
echo "  (Provide this key to Megaport to connect GCP ↔ Azure ER)"
echo ""
echo "  Next steps:"
echo "  1. Configure Megaport to connect Azure ER ↔ GCP Interconnect"
echo "  2. Run: bash scripts/4-test-connectivity.sh (verify connectivity)"
echo "============================================================"

# ─── SSH into the VM (optional) ──────────────────────────────────────────────
# gcloud compute ssh ${envname}-vm1 --zone=$zone

# =============================================================================
# CLEANUP — Uncomment and run to remove all GCP resources
# =============================================================================
# echo "=== Cleaning up GCP resources ==="
# gcloud compute interconnects attachments delete "${envname}-vlan" --region $region --quiet
# gcloud compute routers delete "${envname}-router" --region=$region --quiet
# gcloud compute instances delete "${envname}-vm1" --zone=$zone --quiet
# gcloud compute firewall-rules delete "${envname}-allow-iap-ssh" --quiet
# gcloud compute firewall-rules delete "${envname}-allow-azure" --quiet
# gcloud compute networks subnets delete "${envname}-subnet" --region=$region --quiet
# gcloud compute networks delete "${envname}-vpc" --quiet
# echo "GCP cleanup complete."
