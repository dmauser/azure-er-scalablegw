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

# ─── Parameters ──────────────────────────────────────────────────────────────
project=YOUR_GCP_PROJECT_ID  # Set your GCP project: gcloud projects list
region=us-central1           # GCP region (Chicago area maps to us-central1)
zone=us-central1-c           # Availability zone
vpcrange=192.168.0.0/24      # On-premises simulation range (matches Azure ER route advertisement)
envname=lab-erscale          # Environment name prefix

# ─── Configure GCP Project ───────────────────────────────────────────────────
echo ""
echo "=== Configuring GCP project: $project ==="
gcloud config set project "$project"

# ─── Create VPC and Subnet ───────────────────────────────────────────────────
echo ""
echo "=== Creating GCP VPC and subnet ==="
gcloud compute networks create "${envname}-vpc" \
    --subnet-mode=custom \
    --mtu=1460 \
    --bgp-routing-mode=regional \
    --quiet

gcloud compute networks subnets create "${envname}-subnet" \
    --range="$vpcrange" \
    --network="${envname}-vpc" \
    --region="$region" \
    --quiet

# ─── Create Firewall Rules ────────────────────────────────────────────────────
echo ""
echo "=== Creating firewall rules ==="
# Allow traffic from Azure VNets (10.0.0.0/8) and RFC1918 ranges
gcloud compute firewall-rules create "${envname}-allow-azure" \
    --network "${envname}-vpc" \
    --allow tcp,udp,icmp \
    --source-ranges "192.168.0.0/16,10.0.0.0/8,172.16.0.0/12" \
    --description "Allow traffic from Azure VNets via ExpressRoute" \
    --quiet

# ─── Create Ubuntu VM ─────────────────────────────────────────────────────────
echo ""
echo "=== Creating GCP VM (on-premises simulation) ==="
gcloud compute instances create "${envname}-vm1" \
    --zone="$zone" \
    --machine-type=f1-micro \
    --network-interface=subnet="${envname}-subnet",network-tier=PREMIUM \
    --image-family=ubuntu-2004-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-balanced \
    --boot-disk-device-name="${envname}-vm1" \
    --quiet

# Get VM internal IP
vmInternalIp=$(gcloud compute instances describe "${envname}-vm1" \
    --zone="$zone" \
    --format="value(networkInterfaces[0].networkIP)")
echo "  VM Internal IP: $vmInternalIp"

# ─── Create Cloud Router ──────────────────────────────────────────────────────
echo ""
echo "=== Creating Cloud Router ==="
# ASN 16550 is required for Google Cloud Partner Interconnect
gcloud compute routers create "${envname}-router" \
    --region="$region" \
    --network="${envname}-vpc" \
    --asn=16550 \
    --quiet

# ─── Create Partner Interconnect Attachment (Megaport) ───────────────────────
echo ""
echo "=== Creating Partner Interconnect attachment ==="
gcloud compute interconnects attachments partner create "${envname}-vlan" \
    --region "$region" \
    --edge-availability-domain availability-domain-1 \
    --router "${envname}-router" \
    --admin-enabled \
    --quiet

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
# gcloud compute firewall-rules delete "${envname}-allow-azure" --quiet
# gcloud compute networks subnets delete "${envname}-subnet" --region=$region --quiet
# gcloud compute networks delete "${envname}-vpc" --quiet
# echo "GCP cleanup complete."
