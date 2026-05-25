# Global IP Allocation Plan (Source of Truth)

**Last Updated:** 2026-05-11
**Authority:** Cloud Administration Team
**Network Strategy:** Hierarchical Slicing (Region-based offsets)

---

## 0. Shared VPC Host Project Inventory (The 12 Hubs)

SIESA maintains **12 distinct Shared VPCs** to ensure strict blast-radius isolation between business tiers and environments. Service projects (Spokes) MUST be attached to the correct host project.

### 0.1 SIESA Business Tiers (Modern & Compliance)

| Compliance Tier | Environment | Host Project ID | VPC Network Name |
| :--- | :--- | :--- | :--- |
| **SIESA Business** | Development | `prj-sie-com-vpc-host-dev` | `vpc-sie-com-shared-host-dev` |
| **SIESA Business** | QAS | `prj-sie-com-vpc-host-qa` | `vpc-sie-com-shared-host-qa` |
| **SIESA Business** | Production | `prj-sie-com-vpc-host-prod` | `vpc-sie-com-shared-host-prod` |
| **SDE (Masivos)** | Development | `prj-sie-sde-vpc-host-dev` | `vpc-sie-sde-shared-dev` |
| **SDE (Masivos)** | QAS | `prj-sie-sde-vpc-host-qa` | `vpc-sie-sde-shared-qa` |
| **SDE (Masivos)** | Production | `prj-sie-sde-vpc-host-prod` | `vpc-sie-sde-shared-prod` |

### 0.2 Legacy & Migration Tiers

| Compliance Tier | Environment | Host Project ID | VPC Network Name |
| :--- | :--- | :--- | :--- |
| **SDE Legacy** | Development | `prj-sie-sde-leg-vpc-host-dev` | `vpc-sie-sde-leg-shared-dev` |
| **SDE Legacy** | QAS | `prj-sie-sde-leg-vpc-host-qa` | `vpc-sie-sde-leg-shared-qa` |
| **SDE Legacy** | Production | `prj-sie-sde-leg-vpc-host-prod` | `vpc-sie-sde-leg-shared-prod` |
| **Legacy Global** | Development | `prj-sie-leg-vpc-host-dev` | `vpc-sie-leg-shared-host-dev` |
| **Legacy Global** | QAS | `prj-sie-leg-vpc-host-qa` | `vpc-sie-leg-shared-host-qa` |
| **Legacy Global** | Production | `prj-sie-leg-vpc-host-prod` | `vpc-sie-leg-shared-host-prod` |

---

## 1. Global Supernet Definitions

| Environment | Primary (Nodes) | Pods (GKE) | Services (GKE) | PSA (Peering) |
| :--- | :--- | :--- | :--- | :--- |
| **Development** | `10.4.0.0/14` | `100.64.0.0/14` | `100.100.0.0/16` | `192.168.240.0/20` |
| **QAS** | `10.20.0.0/14` | `100.80.0.0/14` | `100.101.0.0/16` | `192.168.160.0/20` |
| **Production** | `10.36.0.0/14` | `100.96.0.0/14` | `100.102.0.0/16` | `192.168.208.0/20` |

---

## 2. Infrastructure & Shared Services

### 2.1 Private Service Access (PSA)
Managed ranges for AlloyDB, Cloud SQL, and Memorystore.

| Env | Range Name | CIDR Block | Status |
| :--- | :--- | :--- | :--- |
| **Dev** | `psa-sie-googleapi-shared-dev` | `192.168.240.0/20` | **Active** |
| **QA** | `psa-sie-googleapi-shared-qa` | `192.168.160.0/20` | **Active** |
| **Prod** | `psa-sie-googleapi-shared-prod` | `192.168.208.0/20` | Reserved |

### 2.2 Serverless VPC Access (SVA)
Connectors for Cloud Run and Cloud Functions.

| Env | Region | Subnet Name | Range | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Dev** | `us-east1` | `sva-sie-us-east1-shared-dev` | `10.22.32.0/28` | **Active** |
| **Dev** | `us-east4` | `sva-sie-us-east4-shared-dev` | `10.20.32.0/28` | Reserved |

---

## 3. Business Unit Allocation Master Table

Each BU is assigned a **Global Slice Index**. The CIDRs are calculated by adding the `(Index * 8)` to the base of the environment supernet.

### Standard Slice Size:
*   **Primary Subnet:** `/21` (8 blocks of `/24`)
*   **Pods Range:** `/18` (16k IPs)
*   **Services Range:** `/21` (2k IPs)

### 3.1 Development Environment (`10.4.0.0/14` Base)

| Index | BU Code | Business Unit | Region | Primary CIDR | Pods CIDR | Services CIDR |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 0 | **pla** | Platform | `us-east1` | `10.4.0.0/21` | `100.64.0.0/18` | `100.100.0.0/21` |
| 0 | **pla** | Platform | `us-east4` | `10.8.0.0/21` | `100.64.64.0/18` | `100.100.8.0/21` |
| 1 | **int** | Integrations | `us-east1` | `10.4.8.0/21` | `100.64.128.0/18` | `100.100.16.0/21` |
| 1 | **int** | Integrations | `us-east4` | `10.8.8.0/21` | `100.64.192.0/18` | `100.100.24.0/21` |
| 2 | **aip** | AI Platform | `us-east1` | `10.4.16.0/21` | `100.65.0.0/18` | `100.100.32.0/21` |
| 3 | **ana** | Analytics | `us-east1` | `10.4.24.0/21` | `100.65.128.0/18` | `100.100.48.0/21` |
| 4 | **fin** | Finance | `us-east1` | `10.4.32.0/21` | `100.66.0.0/18` | `100.100.64.0/21` |
| 5 | **com** | Commercial | `us-east1` | `10.4.40.0/21` | `100.66.128.0/18` | `100.100.80.0/21` |
| 6 | **man** | Manufacturing | `us-east1` | `10.4.48.0/21` | `100.67.0.0/18` | `100.100.96.0/21` |
| 7 | **pos** | Point of Sale | `us-east1` | `10.4.56.0/21` | `100.67.128.0/18` | `100.100.112.0/21` |
| 8 | **hcm** | Human Capital | `us-east1` | `10.4.64.0/21` | `100.68.0.0/18` | `100.100.128.0/21` |
| 9 | **hot** | Hospitality | `us-east1` | `10.4.72.0/21` | `100.68.128.0/18` | `100.100.144.0/21` |
| 10| **sal** | Sales | `us-east1` | `10.4.80.0/21` | `100.69.0.0/18` | `100.100.160.0/21` |
| 11| **clu** | Club/Loyalty | `us-east1` | `10.4.88.0/21` | `100.69.128.0/18` | `100.100.176.0/21` |
| 12| **otr** | Other/Misc | `us-east1` | `10.4.96.0/21` | `100.70.0.0/18` | `100.100.192.0/21` |
| 13| **nom** | Payroll (Nomina) | `us-east1` | `10.4.104.0/21` | `100.70.128.0/18` | `100.100.208.0/21` |
| 14| **cor** | Corporate | `us-east1` | `10.4.112.0/21` | `100.71.0.0/18` | `100.100.224.0/21` |
| **15**| **---** | **FREE SLOT** | `us-east1` | **`10.4.120.0/21`** | **`100.71.128.0/18`** | **`100.100.240.0/21`** |

---

## 4. Reservation & Calculation Logic

To maintain consistency, always use the **Index-based offset**.

1.  **Identify the BU Index.**
2.  **Calculate Primary Offset:** `Base Octet 2 + (Index * 8)` (Note: If result > 255, increment next octet).
3.  **Calculate Pods Offset:** `Base Octet 3 + (Index * 64)` within the Pods supernet.
4.  **Calculate Services Offset:** `Base Octet 4 + (Index * 8)` within the Services supernet.

---

## 5. GKE Control Plane (Master) Allocation Strategy

To prevent VPC Peering conflicts, every GKE cluster attached to a Shared VPC must have a unique `/28` CIDR block for its Control Plane. SIESA uses the `172.16.0.0/12` range as a dedicated Master Pool.

### 5.1 Standard BU Master Pools & Active Inventory
Standard BUs are assigned a dedicated `/24` block (providing 16 cluster slots) based on their Index.
*   **Formula:** `172.<Env_Octet>.<BU_Index>.0/24`
*   **Env Octets:** DEV=`16`, QA=`17`, PROD=`18`

**Active GKE Cluster Inventory (Standard BUs):**
| BU Index | BU Name | Environment | Cluster Name | Assigned Master CIDR (`/28`) | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 0 | Platform | PROD | *TBD* | `172.18.0.0/28` | Available |
| 4 | Finance | PROD | *TBD* | `172.18.4.0/28` | Available |
| 5 | Comercial | PROD | `gke-sie-com-comercial-prod` | `172.18.5.0/28` | **Allocated** |

---

## 6. Parallel Environments (SDE / ISO Compliance)

### 6.1 SDE Shared VPC Architecture (Business)
**Host Projects:** `prj-sie-sde-vpc-host-[env]`

| Env | Subnet Name | Primary CIDR | Pods (GKE) | Services (GKE) |
| :--- | :--- | :--- | :--- | :--- |
| **Dev** | `snt-sie-sde-use1-01-dev` | `100.124.0.0/18` | N/A | N/A |
| **QA** | `snt-sie-sde-use1-01-qa` | `10.101.16.0/20` | `100.124.64.0/18` | `100.125.8.0/21` |
| **Prod** | `snt-sie-sde-use1-01-prod`| `10.102.16.0/20` | `100.124.128.0/18`| `100.125.16.0/21` |

### 6.2 SDE Shared VPC Architecture (Legacy)
**Host Projects:** `prj-sie-sde-leg-vpc-host-[env]`

| Env | Subnet Name | Primary CIDR |
| :--- | :--- | :--- |
| **Dev** | `snt-sie-sde-leg-use1-01-dev` | `172.24.16.0/20` |
| **QA** | `snt-sie-sde-leg-use1-01-qa` | `172.25.16.0/20` |
| **Prod** | `snt-sie-sde-leg-use1-01-prod`| `172.26.16.0/20` |
