# Azure ExpressRoute Gateway Upgrade Lab: ErGw1AZ → ErGwScale

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Bicep](https://img.shields.io/badge/IaC-Bicep-blue)](./bicep/)

This lab demonstrates how to upgrade an existing Azure ExpressRoute Gateway from **ErGw1AZ** to the **Scalable ExpressRoute Gateway (ErGwScale)** with minimal or zero downtime. GCP is used to simulate an on-premises environment connected via a Megaport partner interconnect.

---

## Why Upgrade to the Scalable ExpressRoute Gateway (ErGwScale)?

The **Scalable ExpressRoute Gateway** (SKU: `ErGwScale`) is the next-generation gateway designed for enterprise and large-scale hybrid connectivity. Legacy SKUs (ErGw1AZ, ErGw2AZ, ErGw3AZ) have **fixed, hard-capped throughput** and do not adapt to changing traffic demands. ErGwScale removes these ceilings and introduces elastic, pay-per-use scaling.

### Throughput: From Fixed Limits to 40 Gbps

| SKU | Max Throughput | Scale Units | Zone Redundant |
|-----|---------------|-------------|----------------|
| ErGw1AZ | ~1 Gbps | 1 (fixed) | Yes |
| ErGw2AZ | ~2 Gbps | 2 (fixed) | Yes |
| ErGw3AZ | ~10 Gbps | 10 (fixed) | Yes |
| **ErGwScale** | **up to 40 Gbps** | **1–40 (auto or manual)** | **Yes** |

> Each scale unit adds ~1 Gbps of gateway throughput. You can configure auto-scale min/max bounds or set a fixed number of units.

### Real-World Example: Maximum Resiliency with Two ER Circuits

A common enterprise design uses **two ExpressRoute circuits for maximum resiliency** — a primary and a secondary, each on a different peering location and provider. With legacy SKUs, a single ER gateway becomes the **throughput bottleneck**:

```
┌─────────────────────────────────────────────────────────────┐
│  Maximum Resiliency Design (2 × ER Circuits, 10 Gbps each)  │
│                                                             │
│  ER Circuit A ──┐                                           │
│   (10 Gbps)     ├──► ErGw3AZ (max 10 Gbps) ──► Azure VNets  │  ← bottlenecked
│  ER Circuit B ──┘                                           │
│   (10 Gbps)                                                 │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Same Design with ErGwScale (20+ scale units)               │
│                                                             │
│  ER Circuit A ──┐                                           │
│   (10 Gbps)     ├──► ErGwScale (20 Gbps+) ──► Azure VNets   │  ← full throughput
│  ER Circuit B ──┘                                           │
│   (10 Gbps)                                                 │
└─────────────────────────────────────────────────────────────┘
```

With **ErGwScale set to 20 scale units**, both circuits can contribute their full 10 Gbps simultaneously — delivering **20 Gbps of aggregate throughput** and true active-active utilization of your ER investments. If you require even higher bandwidth, simply increase scale units up to 40.

### FastPath: Bypass the Gateway from the Data Plane

**FastPath** is one of the most impactful features for latency-sensitive and high-throughput workloads. Normally, all data flowing between on-premises and Azure traverses the ExpressRoute Gateway — adding a hop, latency, and gateway processing overhead.

With FastPath enabled:

- **The gateway is removed from the data plane** — traffic flows **directly** from the on-premises edge to the Azure VM NIC, bypassing the gateway entirely.
- The gateway still handles the **control plane** (BGP, route advertisement) but is no longer in the packet forwarding path.
- This dramatically reduces end-to-end latency and removes the gateway as a throughput ceiling for VM-level traffic.

```
Without FastPath:
  On-Prem ──► MSEE ──► ER Gateway ──► VM NIC   (gateway in data path)

With FastPath:
  On-Prem ──► MSEE ──────────────► VM NIC       (gateway bypassed)
```

> **FastPath requirement:** FastPath is supported on **ErGwScale** and **ErGw3AZ** and requires an **ExpressRoute Direct** circuit (not a provider/partner circuit). It is not supported with partner circuits (e.g., Megaport, Equinix).

### Business Value Summary

| Benefit | Legacy SKUs | ErGwScale |
|---------|-------------|-----------|
| **Maximum throughput** | Up to 10 Gbps (fixed) | Up to **40 Gbps** (scalable) |
| **Active-active multi-circuit** | Gateway-limited | Full bandwidth from all circuits |
| **Cost efficiency** | Pay for fixed SKU | Pay only for scale units in use |
| **Elastic scaling** | Manual SKU change = downtime | Auto-scale with min/max bounds |
| **FastPath (ER Direct)** | ErGw3AZ only | **Fully supported** |
| **Zone redundancy** | Yes (AZ variants) | Yes (built-in) |
| **Upgrade path** | Disruptive SKU change | **In-place, non-disruptive** |
| **Future-proof** | Fixed capability | Scales with your business |

### Who Should Upgrade?

Consider upgrading to ErGwScale if any of these apply:

- You have **multiple ExpressRoute circuits** and want to fully utilize aggregate bandwidth
- You are approaching the **throughput limit** of your current gateway SKU
- You want to enable **FastPath** for latency-sensitive workloads (requires ER Direct)
- You want **auto-scaling** to handle burst workloads without pre-provisioning
- You want to **consolidate** multiple ER gateways into a single scalable gateway
- You want a **future-proof** gateway that doesn't require disruptive SKU upgrades

### Upgrade Considerations and Caveats

Not all upgrade paths are equal. Before proceeding, review the following:

| Scenario | Disruptive? | Notes |
|----------|-------------|-------|
| Any AZ SKU → **ErGwScale** | **No** | In-place, live migration; existing connections stay up |
| **ErGwScale** → lower AZ SKU (downgrade) | **Yes** | Downgrades are not supported in-place; requires gateway recreation |
| **Non-AZ SKU** (e.g., Standard, HighPerf, UltraPerf) → ErGwScale | **Yes — migration required** | Non-AZ gateways must first be migrated to an AZ-aware SKU or recreated |
| ErGw1AZ / ErGw2AZ → ErGw3AZ (legacy AZ upgrades) | Varies | Supported but may cause brief BGP flap; ErGwScale is the preferred target |

> **Non-AZ to AZ migration:** If your current gateway uses a legacy non-zone-redundant SKU (Standard, HighPerf, UltraPerf), you cannot do a direct in-place upgrade to ErGwScale. A **gateway migration** is required, which involves deploying a new gateway and re-establishing connections. Plan for a maintenance window.

> **Downgrade warning:** Once upgraded to ErGwScale, downgrading to a lower SKU (e.g., ErGw1AZ) is **not supported as an in-place operation**. If a rollback is needed, the gateway must be deleted and recreated.

For the latest supported upgrade paths, SKU restrictions, and migration procedures, always consult the official Microsoft documentation:

- 📄 [Upgrade an ExpressRoute gateway to ErGwScale](https://learn.microsoft.com/azure/expressroute/expressroute-howto-gateway-migration-portal)
- 📄 [About ExpressRoute virtual network gateways — SKUs](https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways#gwsku)
- 📄 [Migrate to availability zone-enabled ExpressRoute virtual network gateways](https://learn.microsoft.com/azure/expressroute/expressroute-howto-gateway-migration-portal)
- 📄 [Configure FastPath for ExpressRoute](https://learn.microsoft.com/azure/expressroute/expressroute-howto-linkvnet-arm#configure-expressroute-fastpath)

---

## Architecture

![Architecture Diagram](diagrams/architecture.svg)

> 📐 [Open and edit in Excalidraw](https://excalidraw.com/#url=https://raw.githubusercontent.com/dmauser/azure-er-scalablegw/main/diagrams/architecture.excalidraw)

### Upgrade Flow

```
┌──────────────┐         ┌──────────────┐
│   ErGw1AZ    │──────►  │  ErGwScale   │
│  (Standard)  │ upgrade │  (Scalable)  │
│  ~1 Gbps     │         │  Auto-scale  │
└──────────────┘         └──────────────┘
   Script 1                 Script 3
```

## Repository Structure

```
azure-er-scalablegw/
├── README.md
├── LICENSE
├── .gitignore
├── bicep/
│   ├── main.bicep              # Orchestration: VNets, VMs, Bastion, KV, ER GW
│   ├── main.bicepparam         # Default parameters
│   └── modules/
│       ├── hub-vnet.bicep      # Hub VNet with all subnets
│       ├── spoke-vnet.bicep    # Spoke VNet (reusable)
│       ├── vnet-peering.bicep  # VNet peering with gateway transit
│       ├── keyvault.bicep      # Key Vault + auto-generated admin password
│       ├── bastion.bicep       # Azure Bastion (Basic SKU)
│       ├── vm.bicep            # Ubuntu 22.04 VM, no public IP, boot diagnostics
│       └── er-gateway.bicep    # ExpressRoute Gateway (upgradeable SKU)
└── scripts/
    ├── 1-deploy-azure.azcli    # Deploy Azure infra + ER circuit + connection
    ├── 2-deploy-onprem-gcp.azcli  # GCP on-premises simulation
    ├── 3-upgrade-ergw.azcli    # Upgrade ER GW: ErGw1AZ → ErGwScale
    ├── 4-test-connectivity.sh  # Validate connectivity and routing
    └── 5-monitor-downtime.sh   # Continuous monitoring during upgrade
```

## Lab Components

| Component | Details |
|-----------|---------|
| **Hub VNet** | 10.0.0.0/24 — ER Gateway, Bastion |
| **Spoke1 VNet** | 10.0.1.0/24 — Workload subnet |
| **Spoke2 VNet** | 10.0.2.0/24 — Workload subnet |
| **VMs** | Ubuntu 22.04 · No Public IP · Serial Console + Bastion access |
| **Azure Bastion** | Basic SKU — browser-based SSH to all VMs |
| **Key Vault** | Auto-generated strong password stored as secret |
| **ER Gateway** | Starts as **ErGw1AZ** · upgraded to **ErGwScale** |
| **ER Circuit** | Provider: Megaport · Location: Chicago · BW: 50 Mbps |
| **On-Prem (GCP)** | GCP VPC + VM via Megaport Partner Interconnect |

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Azure CLI ≥ 2.55 | `az --version` |
| Bicep CLI ≥ 0.22 | `az bicep version` or `bicep --version` |
| Azure Subscription | With Owner or Contributor + Key Vault permissions |
| GCP Account | For on-premises simulation |
| Megaport Account | For the partner interconnect between Azure ER and GCP Interconnect |
| Python 3 | For password generation in deploy script |

## Step-by-Step Lab Guide

### Phase 1 — Deploy Azure Infrastructure

```bash
# 1. Clone the repository
git clone https://github.com/dmauser/azure-er-scalablegw.git
cd azure-er-scalablegw

# 2. Review and edit parameters (optional)
# Edit bicep/main.bicepparam or override via CLI flags

# 3. Run the Azure deployment script
bash scripts/1-deploy-azure.azcli
```

The script will:
- Generate a cryptographically strong admin password
- Store it securely in Azure Key Vault
- Deploy Hub + Spokes + VMs (no public IPs) + Bastion + ER Gateway (ErGw1AZ)
- Create the ExpressRoute Circuit (Megaport / Chicago)
- Display the **service key** for provisioning via Megaport

### Phase 2 — Provision On-Premises (GCP)

```bash
# In a GCP Cloud Shell or local terminal with gcloud configured
bash scripts/2-deploy-onprem-gcp.azcli
```

This script will:
- Create a GCP VPC and subnet (192.168.0.0/24)
- Deploy a GCP VM for on-prem simulation
- Create a Cloud Router and Partner Interconnect attachment
- Display the **pairing key** to use in Megaport

> **Manual step:** Use the Megaport portal to connect the Azure ER circuit (service key) ↔ GCP Interconnect (pairing key).

### Phase 3 — Connect ExpressRoute Circuit

Once Megaport has provisioned both sides (ProviderProvisioningState = `Provisioned`):

```bash
# Script 1 (continued) will automatically detect provisioning and create the connection
# Or run manually:
bash scripts/1-deploy-azure.azcli  # Picks up from the wait loop
```

### Phase 4 — Test Baseline Connectivity

```bash
bash scripts/4-test-connectivity.sh
```

This validates:
- BGP adjacency on the ER gateway
- Learned routes from on-prem
- ICMP and traceroute from spoke VMs → GCP VM
- Effective routes on VM NICs

### Phase 5 — Monitor and Upgrade the ER Gateway

> Run the monitoring script **before** starting the upgrade to capture any micro-outage.

**Terminal 1 — Start monitoring:**
```bash
bash scripts/5-monitor-downtime.sh
```

**Terminal 2 — Upgrade the gateway:**
```bash
bash scripts/3-upgrade-ergw.azcli
```

The upgrade changes the gateway SKU from **ErGw1AZ** → **ErGwScale**. The process:
1. Azure performs an in-place upgrade (live migration)
2. Existing connections remain attached
3. BGP sessions may briefly flap (typically < 1 second)
4. The new ErGwScale gateway auto-scales based on traffic demand

### Phase 6 — Post-Upgrade Validation

```bash
bash scripts/4-test-connectivity.sh
```

Confirming:
- Gateway SKU is now `ErGwScale`
- All BGP sessions are re-established
- All spoke-to-on-prem routes are still present
- Connectivity is fully restored

## Retrieving VM Credentials

The admin password is auto-generated and stored in Key Vault:

```bash
rg=lab-er-scale
kvName=$(az keyvault list -g $rg --query '[0].name' -o tsv)

# Retrieve password
az keyvault secret show --vault-name $kvName --name admin-password --query value -o tsv

# Retrieve username
az keyvault secret show --vault-name $kvName --name admin-username --query value -o tsv
```

## VM Access Methods

### Azure Bastion (Recommended)

1. Open the [Azure Portal](https://portal.azure.com)
2. Navigate to the VM → **Connect** → **Bastion**
3. Enter the credentials retrieved from Key Vault

### Azure Serial Console

1. Open the [Azure Portal](https://portal.azure.com)
2. Navigate to the VM → **Help** → **Serial Console**
3. No network connectivity required — works even if Bastion is unavailable

## IP Addressing Reference

| Network | CIDR | Usage |
|---------|------|-------|
| Hub VNet | 10.0.0.0/24 | Hub network |
| subnet1 | 10.0.0.0/27 | Hub VMs |
| GatewaySubnet | 10.0.0.32/27 | ExpressRoute Gateway |
| AzureBastionSubnet | 10.0.0.192/26 | Azure Bastion |
| Spoke1 VNet | 10.0.1.0/24 | Spoke 1 |
| Spoke1/subnet1 | 10.0.1.0/27 | Spoke 1 VMs |
| Spoke2 VNet | 10.0.2.0/24 | Spoke 2 |
| Spoke2/subnet1 | 10.0.2.0/27 | Spoke 2 VMs |
| On-Premises (GCP) | 192.168.0.0/24 | Simulated on-prem |

## ExpressRoute Gateway SKU Comparison

| SKU | Max Throughput | Zone Redundant | Scalable |
|-----|---------------|----------------|---------|
| ErGw1AZ | 1 Gbps | ✅ | ❌ |
| ErGw2AZ | 2 Gbps | ✅ | ❌ |
| ErGw3AZ | 10 Gbps | ✅ | ❌ |
| **ErGwScale** | **Auto-scale** | ✅ | ✅ |

## Cleanup

```bash
# Azure resources
rg=lab-er-scale
az group delete --name $rg --yes --no-wait

# GCP resources
bash scripts/2-deploy-onprem-gcp.azcli  # Contains cleanup section at the bottom
```

> **Note:** Key Vault has soft-delete enabled (7-day retention). To permanently purge after deletion:
> ```bash
> az keyvault purge --name <kv-name> --location westus3
> ```

## References

- [Azure ExpressRoute Gateway Scalable SKU](https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways#scalable-gateway)
- [Upgrade an ExpressRoute Gateway](https://learn.microsoft.com/azure/expressroute/expressroute-howto-upgrade-expressroute-gateway)
- [Azure Bastion — Connect to VM](https://learn.microsoft.com/azure/bastion/bastion-connect-vm-ssh-linux)
- [Azure Serial Console](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/serial-console-linux)
- [Megaport Azure ExpressRoute](https://docs.megaport.com/cloud/microsoft-azure/azure-expressroute/)
- [GCP Partner Interconnect](https://cloud.google.com/network-connectivity/docs/interconnect/concepts/partner-overview)

## Contributing

Contributions are welcome! Please open an issue or pull request. For major changes, open an issue first to discuss the proposed change.

## License

This project is licensed under the MIT License — see the [LICENSE](./LICENSE) file for details.
