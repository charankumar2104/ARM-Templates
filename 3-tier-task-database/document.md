# Azure 3-Tier Architecture — Resource Interconnection Guide

> How every resource works, what it does, and how it connects to everything else.
---

## The Big Picture — Traffic Flow in One Line

```
Internet → Public LB → Web VMs → Private LB → App VMs → Private Endpoint → Azure SQL
```

Every resource in this architecture exists to either **enable** this flow or **protect** it.

---

## Resource Map — Who Talks to Whom

```
                          ┌─────────────────────┐
                          │   INTERNET / USER    │
                          └──────────┬──────────┘
                                     │
                          ┌──────────▼──────────┐
                          │   web-lb-public-ip  │ ← Public IP Address
                          └──────────┬──────────┘
                                     │
                          ┌──────────▼──────────┐
                          │   web-public-lb     │ ← Public Load Balancer
                          └──────┬──────┬───────┘
                                 │      │
                    ┌────────────▼┐    ┌▼────────────┐
                    │  web-vm-1  │    │  web-vm-2   │ ← Web VMs
                    │  web-nsg   │    │  web-nsg    │ ← NSG on web-subnet
                    └────────────┘    └─────────────┘
                                 │
                          ┌──────▼──────────────┐
                          │   app-private-lb    │ ← Private Load Balancer (10.0.2.100)
                          └──────┬──────┬───────┘
                                 │      │
                    ┌────────────▼┐    ┌▼────────────┐
                    │  app-vm-1  │    │  app-vm-2   │ ← App VMs
                    │  app-nsg   │    │  app-nsg    │ ← NSG on app-subnet
                    └────────────┘    └─────────────┘
                                 │
                    ┌────────────▼────────────────┐
                    │  Private DNS Zone           │ ← Resolves SQL FQDN → Private IP
                    └────────────┬────────────────┘
                                 │
                    ┌────────────▼────────────────┐
                    │  sql-private-endpoint       │ ← Private Endpoint NIC (10.0.3.x)
                    │  data-nsg                  │ ← NSG on data-subnet
                    └────────────┬────────────────┘
                                 │
                    ┌────────────▼────────────────┐
                    │  Azure SQL Database         │ ← SampleDB (PaaS)
                    └─────────────────────────────┘
         NAT Gateway ←── app-subnet + data-subnet (for outbound internet only)
```

---

## Every Resource — What It Does & How It Connects

---

### 1. Virtual Network (three-tier-vnet)

**What it is:** The private network that contains everything. Think of it as the building that houses all the floors.

**What it does:**
- Defines the IP address space `10.0.0.0/16` — over 65,000 private IP addresses
- Divides into 3 subnets, each acting as a separate isolated floor
- Ensures resources in different subnets can only talk to each other if NSG rules allow it

**How it connects to other resources:**

```
Virtual Network
├── web-subnet (10.0.1.0/24)
│   ├── Attached to: web-nsg          ← controls who enters/exits this subnet
│   ├── Contains:    web-vm-1 NIC
│   └── Contains:    web-vm-2 NIC
│
├── app-subnet (10.0.2.0/24)
│   ├── Attached to: app-nsg          ← controls who enters/exits this subnet
│   ├── Attached to: NAT Gateway      ← gives outbound internet to app VMs
│   ├── Contains:    app-vm-1 NIC
│   ├── Contains:    app-vm-2 NIC
│   └── Frontend IP: app-private-lb (10.0.2.100)
│
└── data-subnet (10.0.3.0/24)
    ├── Attached to: data-nsg         ← controls who enters/exits this subnet
    ├── Attached to: NAT Gateway      ← gives outbound internet (used during setup only)
    └── Contains:    private endpoint NIC (10.0.3.x)
```

**If this resource didn't exist:** Nothing would work. No network = no communication between any component.

---

### 2. Network Security Groups (web-nsg, app-nsg, data-nsg)

**What they are:** Firewalls attached directly to subnets. They inspect every packet entering or leaving a subnet and either allow or block it based on rules.

**What they do:**

```
web-nsg — Guards the Web Tier (10.0.1.0/24)
┌─────────────────────────────────────────────────────┐
│ INBOUND                                              │
│  ✅ Allow port 80  from Internet   → Web VMs get HTTP│
│  ✅ Allow port 443 from Internet   → Web VMs get HTTPS│
│  ✅ Allow *        from AzureLB    → Health probe works│
│  ❌ Deny  *        from *          → Everything else blocked│
│ OUTBOUND                                             │
│  ✅ Allow *  to VirtualNetwork     → Web VM can call App LB│
│  ✅ Allow *  to Internet           → Web VM can download updates│
└─────────────────────────────────────────────────────┘
app-nsg — Guards the App Tier (10.0.2.0/24)
┌─────────────────────────────────────────────────────┐
│ INBOUND                                              │
│  ✅ Allow port 80 from 10.0.1.0/24 → Only web VMs can call App VMs│
│  ✅ Allow *        from AzureLB    → Health probe works│
│  ❌ Deny  *        from Internet   → App tier NEVER reachable from internet│
│  ❌ Deny  *        from *          → Everything else blocked│
│ OUTBOUND                                             │
│  ✅ Allow port 1433 to 10.0.3.0/24 → App VM can reach SQL endpoint│
│  ✅ Allow *         to Internet    → NAT GW for updates + script download│
└─────────────────────────────────────────────────────┘
data-nsg — Guards the Data Tier (10.0.3.0/24)
┌─────────────────────────────────────────────────────┐
│ INBOUND                                              │
│  ✅ Allow port 1433 from VirtualNetwork → App VMs can reach SQL│
│  ❌ Deny  *          from *             → Completely isolated│
│ OUTBOUND                                             │
│  ❌ Deny  * to Internet  → Private endpoint needs no outbound│
└─────────────────────────────────────────────────────┘
```

**How they connect to other resources:**
- `web-nsg` → attached to `web-subnet` inside `three-tier-vnet`
- `app-nsg` → attached to `app-subnet` inside `three-tier-vnet`
- `data-nsg` → attached to `data-subnet` inside `three-tier-vnet`

**If these didn't exist:** All traffic between tiers would be unrestricted. App VMs would be directly reachable from the internet, and SQL would be accessible from anywhere inside the VNet.

---

### 3. Public IP Address (web-lb-public-ip)

**What it is:** A static, globally routable IP address assigned to the public load balancer.

**What it does:**
- Gives the entire application a single, stable entry point on the internet
- Has a DNS label `weblb-<uniqueString>.centralindia.cloudapp.azure.com` — so users get a human-readable URL
- Stays the same even if VMs are restarted or replaced

**How it connects to other resources:**
```
web-lb-public-ip
    └── Assigned to: web-public-lb (frontend IP configuration)
```

**If this didn't exist:** The public load balancer would have no internet-facing address. Users couldn't reach the application.

---

### 4. Public Load Balancer (web-public-lb)

**What it is:** The front door of the application. It receives all incoming traffic from the internet and distributes it across the web VMs.

**What it does:**

```
Internet Request arrives at web-public-lb
         │
         ▼
  Is the request on port 80? ──No──► Drop (no matching LB rule)
         │ Yes
         ▼
  Check health of backend VMs
  ┌──────────────────────────┐
  │ web-vm-1: GET /health.html → 200 OK ✅ │
  │ web-vm-2: GET /health.html → 200 OK ✅ │
  └──────────────────────────┘
         │
         ▼
  Apply SourceIPProtocol distribution
  (same client IP + protocol → same VM every time)
         │
         ▼
  Forward to web-vm-1 or web-vm-2
```

**Its 3 sub-components and what they do:**

| Sub-component | Role |
|---|---|
| **Frontend IP config** | Binds the public IP to this LB. Internet traffic arrives here. |
| **Backend pool** | List of web VM NICs that receive traffic. web-vm-1 and web-vm-2 are both registered here. |
| **Health probe** | Polls `GET /health.html` every 15 seconds. If a VM fails 2 checks in a row, it's removed from rotation until it recovers. |
| **LB Rule (port 80)** | Connects frontend → backend. `disableOutboundSnat:true` because outbound traffic uses a separate rule. |
| **Outbound Rule** | Gives web VMs outbound internet access via SNAT (they have no public IPs of their own). Allocates 10,000 SNAT ports per VM. |

**How it connects to other resources:**
```
web-public-lb
├── Uses:     web-lb-public-ip     (its internet-facing address)
├── Backend:  web-vm-1 NIC         (sends traffic here)
├── Backend:  web-vm-2 NIC         (sends traffic here)
└── Governed: web-nsg              (NSG allows port 80 from Internet before LB even sees it)
```

**If this didn't exist:** No load balancing. Traffic would have to go to a single VM directly via a public IP — no redundancy, and if that VM restarts, the app goes down.

---

### 5. Web VMs (web-vm-1, web-vm-2)

**What they are:** Windows Server 2022 VMs running IIS web server with ASP.NET 4.5. They serve the frontend HTML page to users.

**What they do:**
- Receive HTTP requests forwarded by the Public Load Balancer
- Serve `index.aspx` — which renders the application UI
- Make an internal HTTP call to `http://10.0.2.100/api/data.aspx` (the App LB)
- Embed the product data returned by the App tier into the HTML response

**Their internal components:**

```
web-vm-1 (or web-vm-2)
├── NIC (web-vm-1-nic)
│   └── IP in web-subnet + registered in web-public-lb backend pool
├── OS Disk (Premium SSD)
├── IIS Web Server
│   ├── /health.html       ← answered to LB health probes
│   └── /index.aspx        ← served to users; calls App tier
└── Custom Script Extension
    └── Downloaded web-vm-setup.ps1 from blob storage
        └── Installed IIS + deployed index.aspx automatically
```

**How they connect to other resources:**
```
web-vm-1
├── NIC registered in: web-public-lb backend pool   (receives user traffic)
├── Sits in:           web-subnet                   (network placement)
├── Governed by:       web-nsg                      (firewall rules)
├── Calls outbound:    app-private-lb (10.0.2.100)  (fetches product data)
└── Script from:       blob storage (web-vm-setup.ps1)
```

**If these didn't exist:** No frontend. Users would have nothing to connect to.

---

### 6. Private Load Balancer (app-private-lb)

**What it is:** An internal load balancer with no public IP. It lives entirely inside the VNet and distributes traffic from web VMs to app VMs.

**What it does:**
- Has a fixed private IP `10.0.2.100` — this never changes regardless of which app VMs are healthy
- Web VMs always call `http://10.0.2.100/api/data.aspx` — they don't need to know individual app VM IPs
- Checks health of app VMs every 15 seconds via `GET /health.html`
- Distributes requests across `app-vm-1` and `app-vm-2`

**Why a fixed IP matters:**

```
Without Private LB:                    With Private LB:
Web VM must know:                      Web VM only knows:
  - app-vm-1 is at 10.0.2.4            - App tier is at 10.0.2.100
  - app-vm-2 is at 10.0.2.5            (always the same, forever)
  - If app-vm-1 fails, update config   - LB handles failover automatically
```

**How it connects to other resources:**
```
app-private-lb
├── Frontend IP:  10.0.2.100 (static, inside app-subnet)
├── Backend:      app-vm-1 NIC
├── Backend:      app-vm-2 NIC
└── Governed by:  app-nsg (allows port 80 from web-subnet)
```

**If this didn't exist:** Web VMs would need to know individual app VM IPs. If an app VM failed, the web tier would also fail. No load distribution between app VMs.

---

### 7. App VMs (app-vm-1, app-vm-2)

**What they are:** Windows Server 2022 VMs running IIS with ASP.NET 4.5. They contain the business logic layer — specifically, they query the SQL database and return formatted data.

**What they do:**
- Receive HTTP requests from the Private Load Balancer
- Serve `/api/data.aspx` — which connects to Azure SQL, queries the `Products` table, and returns an HTML table
- Use built-in `.NET System.Data.SqlClient` to connect to SQL — no extra SQL tools installed

**Their internal components:**

```
app-vm-1 (or app-vm-2)
├── NIC (app-vm-1-nic)
│   └── IP in app-subnet + registered in app-private-lb backend pool
├── IIS Web Server
│   ├── /health.html           ← answered to LB health probes
│   └── /api/data.aspx         ← queries SQL, returns HTML product table
└── Custom Script Extension
    └── Downloaded app-vm-setup.ps1 from blob storage
        └── Installed IIS + deployed data.aspx automatically
```

**How they connect to other resources:**
```
app-vm-1
├── NIC registered in: app-private-lb backend pool       (receives traffic from web VMs)
├── Sits in:           app-subnet                        (network placement)
├── Governed by:       app-nsg                          (only port 80 from web-subnet allowed in)
├── DNS resolves:      myserver.database.windows.net → 10.0.3.5 (private endpoint IP)
├── Connects to:       sql-private-endpoint (TCP 1433)  (queries the SQL database)
└── Script from:       blob storage (app-vm-setup.ps1)
```

**If these didn't exist:** No business logic layer. Web VMs would have to connect directly to SQL — breaking the 3-tier separation.

---

### 8. NAT Gateway (app-data-natgw)

**What it is:** A managed outbound internet gateway shared by the app and data subnets.

**What it does:**
- App and data VMs have no public IPs. Without NAT Gateway they couldn't reach the internet at all.
- Provides a single stable outbound IP for both subnets
- Used during VM provisioning to download the PS1 scripts from Azure Blob Storage
- Also used for Windows Update, certificate validation, etc.

**Why web VMs don't use it:**
```
web-vm-1 outbound path:   web-vm → web-public-lb outbound rule → Internet
app-vm-1 outbound path:   app-vm → NAT Gateway → Internet
```

Web VMs use the LB's outbound SNAT rule because they're already behind the public LB. App/data VMs aren't behind any public LB, so they need their own outbound mechanism.

**How it connects to other resources:**
```
NAT Gateway
├── Uses:         natgw-public-ip      (its internet-facing address)
├── Attached to:  app-subnet           (all outbound traffic from app VMs flows through it)
└── Attached to:  data-subnet          (all outbound traffic from data subnet flows through it)
```

**If this didn't exist:** App VMs couldn't download their setup scripts during deployment. The Custom Script Extension would fail with a network error.

---

### 9. Azure SQL Server (logical server)

**What it is:** The logical container for the database. It's not a VM — it's a PaaS service managed entirely by Microsoft.

**What it does:**
- Hosts the `SampleDB` database
- Manages authentication — `sqladmin` login with password
- Has `publicNetworkAccess: Enabled` during deployment (needed for the ARM deployment script to seed data)
- App VMs never use the public endpoint — they always route through the Private Endpoint

**How it connects to other resources:**
```
Azure SQL Server
├── Contains:       SampleDB database
├── Connected via:  sql-private-endpoint (private link)
├── Firewall rule:  AllowAzureServices (0.0.0.0→0.0.0.0)
│                   └── Allows ARM deployment script to connect during setup
└── Seeded by:      create-products-table (deploymentScript)
```

**If this didn't exist:** No database. The entire data tier disappears.

---

### 10. Azure SQL Database (SampleDB)

**What it is:** The actual database that stores product data. Uses the General Purpose Serverless tier.

**What it does:**
- Stores the `Products` table with 10 rows (seeded automatically during deployment)
- Auto-pauses after 60 minutes of no connections (saves cost)
- Auto-resumes when a connection arrives (first query is slightly slower)
- 5 GB max size, Local backup redundancy

**The Products table structure:**
```sql
Products
├── ID        INT            PRIMARY KEY
├── Name      NVARCHAR(100)
├── Price     DECIMAL(10,2)
├── Category  NVARCHAR(50)
└── Stock     INT
```

**How it connects to other resources:**
```
SampleDB
├── Lives inside:  Azure SQL Server (logical server)
├── Accessed via:  sql-private-endpoint (app VMs connect through this)
└── Seeded by:     create-products-table (deploymentScript on first deploy)
```

**If this didn't exist:** App VMs have nowhere to query. The `/api/data.aspx` page would throw "database not found" errors.

---

### 11. Private Endpoint (sql-private-endpoint)

**What it is:** A NIC card provisioned inside your VNet that acts as the "socket" for the Azure SQL database. It makes the public SQL service behave like a private resource inside your network.

**What it does:**
- Gets a private IP from `data-subnet` (e.g., `10.0.3.5`)
- Any traffic sent to this IP on port 1433 is privately routed to the Azure SQL service
- Traffic never leaves the Microsoft backbone network

**How it connects to other resources:**
```
sql-private-endpoint
├── NIC inside:     data-subnet (10.0.3.0/24)
├── Points to:      Azure SQL Server (private link connection)
├── Protected by:   data-nsg (only VNet traffic on 1433 allowed)
├── DNS handled by: privateDnsZoneGroup (auto-registers its IP in DNS zone)
└── Reached from:   app-vm-1, app-vm-2 (via TCP 1433)
```

**The connection chain:**
```
app-vm-1
  │ resolves: myapp-sqlsrv.database.windows.net → 10.0.3.5  (via private DNS)
  │ sends: TCP :1433 to 10.0.3.5
  ▼
data-nsg (allows VNet traffic on 1433)
  ▼
sql-private-endpoint NIC at 10.0.3.5
  ▼
Azure SQL private link service
  ▼
SampleDB (data is returned)
```

**If this didn't exist:** App VMs would have to connect to the public SQL endpoint over the internet — requiring public network access to always be enabled, which is a security risk.

---

### 12. Private DNS Zone (privatelink.database.windows.net)

**What it is:** A private DNS zone that overrides public DNS resolution for SQL server addresses — but only inside your VNet.

**What it does:**

```
Without Private DNS Zone:
  app-vm-1 queries: myapp-sqlsrv.database.windows.net
  DNS returns: 52.x.x.x  ← PUBLIC Azure SQL IP
  Traffic goes to: public internet  ❌
With Private DNS Zone:
  app-vm-1 queries: myapp-sqlsrv.database.windows.net
  DNS returns: 10.0.3.5  ← PRIVATE endpoint IP
  Traffic stays: inside VNet  ✅
```

**How it connects to other resources:**
```
Private DNS Zone
├── Linked to:     three-tier-vnet (via VNet Link)
│                  └── Makes this zone authoritative for VMs inside the VNet
├── Record added by: privateDnsZoneGroup
│                  └── Auto-creates A record: myapp-sqlsrv → 10.0.3.5
└── Queried by:    app-vm-1, app-vm-2 (when they connect to SQL)
```

**If this didn't exist:** App VMs would get the public SQL IP from DNS. Either connections would fail (if public access is disabled) or traffic would go via internet instead of the private backbone.

---

### 13. Private DNS Zone VNet Link

**What it is:** The bridge between the private DNS zone and the VNet. Without this link, VMs inside the VNet would not use the private DNS zone.

**What it does:**
- Tells Azure: "When any VM in `three-tier-vnet` queries DNS for `*.database.windows.net`, use this private zone"
- Has `registrationEnabled: false` — we don't want VMs auto-registering their own names in this zone

**How it connects to other resources:**
```
VNet Link
├── Links:     Private DNS Zone ↔ three-tier-vnet
└── Enables:   app-vm-1 and app-vm-2 to use private DNS resolution
```

**If this didn't exist:** The private DNS zone exists but is never used. VMs would still get the public SQL IP from DNS.

---

### 14. Private DNS Zone Group

**What it is:** The automated connection between the Private Endpoint and the Private DNS Zone.

**What it does:**
- When created, automatically adds an A record to the DNS zone:
  ```
  myapp-sqlsrv-prod.database.windows.net → 10.0.3.5
  ```
- No manual DNS entry needed — it happens automatically
- If the private endpoint IP changes, the DNS record updates automatically

**How it connects to other resources:**
```
DNS Zone Group
├── Belongs to:    sql-private-endpoint
├── Writes A record into: Private DNS Zone
└── Effect felt by: app-vm-1, app-vm-2 (they resolve SQL → private IP)
```

**The chain reaction when this resource is created:**
```
DNS Zone Group created
    → Reads private endpoint NIC IP (e.g., 10.0.3.5)
    → Writes into private DNS zone:
      myapp-sqlsrv-prod.database.windows.net = 10.0.3.5
    → Any VM inside the VNet now resolves SQL to private IP
    → App VMs can connect to SQL via private backbone
```

**If this didn't exist:** You would have to manually add DNS A records every time. Easy to forget, and the IP could change.

---

### 15. SQL Firewall Rule (AllowAzureServices)

**What it is:** A firewall rule on the SQL Server that uses the special IP range `0.0.0.0 → 0.0.0.0`.

**What it does:**
- This special range means "Allow connections from Azure-managed infrastructure"
- Lets the ARM deployment script (which runs inside Azure's Container Instance service) connect to SQL over the public endpoint
- Does NOT allow connections from your laptop or random internet IPs

**How it connects to other resources:**
```
AllowAzureServices Firewall Rule
├── On:         Azure SQL Server
├── Enables:    create-products-table (deploymentScript) to connect
└── Purpose:    Seeds Products table during first deployment
```

> **Why keep it on?** App VMs use the private endpoint, so they're not affected by this rule. The rule only matters for Azure-to-Azure connections via the public endpoint — like the deployment script.
**If this didn't exist:** The deployment script can't connect to SQL. The Products table is never created. First deploy would result in "Invalid object name 'Products'" error.

---

### 16. ARM Deployment Script (create-products-table)

**What it is:** An ARM-native resource that runs a PowerShell script inside a temporary Azure Container Instance during deployment.

**What it does:**
1. Waits until all its `dependsOn` resources are ready (SQL Server + DB + Firewall Rule + Role Assignment)
2. Connects to `SampleDB` using `.NET System.Data.SqlClient`
3. Creates the `Products` table if it doesn't exist
4. Inserts 10 seed rows
5. Retries up to 20 times × 30 seconds if SQL isn't ready yet
6. The temporary Container Instance is cleaned up automatically after success

**Why it exists (the problem it solves):**
```
OLD APPROACH (broken):
  App VM boots → CSE runs immediately → tries to create table
  SQL Private Endpoint DNS still propagating (takes 3-8 min)
  CSE exhausts retries → table never created → "Invalid object name 'Products'"
NEW APPROACH (fixed):
  deploymentScript has dependsOn: [SQL Server, SQL DB, Firewall Rule, Role Assignment]
  ARM waits until ALL are ready → THEN runs the script
  Script connects via public endpoint (AllowAzureServices rule) → table created ✅
  App VMs boot → table already exists → works immediately ✅
```

**How it connects to other resources:**
```
create-products-table (deploymentScript)
├── dependsOn:  Azure SQL Server           (must exist first)
├── dependsOn:  SampleDB                  (must exist first)
├── dependsOn:  AllowAzureServices rule   (must be active to connect)
├── dependsOn:  Role Assignment           (identity needs Contributor to spin up ACI)
├── Uses:       deploy-script-identity    (managed identity to run as)
├── Connects to: Azure SQL Server FQDN   (public endpoint via AllowAzureServices)
└── Creates:    dbo.Products table + 10 rows inside SampleDB
```

**If this didn't exist:** Manual table creation required after every fresh deployment. The original bug you hit.

---

### 17. User Assigned Managed Identity (deploy-script-identity)

**What it is:** An Azure identity (like a service account) that the deployment script uses to authenticate and provision resources.

**What it does:**
- The ARM deployment script needs an identity to run under — it can't use your personal credentials
- This identity is granted Contributor access on the resource group
- The Contributor role lets the script spin up a temporary Azure Container Instance to host the PowerShell process

**How it connects to other resources:**
```
deploy-script-identity
├── Granted: Contributor role on resource group (via Role Assignment)
└── Used by: create-products-table deploymentScript
```

**If this didn't exist:** The deployment script has no identity to run under — it fails immediately with an authentication error.

---

### 18. Role Assignment (Contributor)

**What it is:** Grants the managed identity permission to act on resources in the resource group.

**What it does:**
- Specifically: lets the deployment script's identity provision a temporary Azure Container Instance (ACI)
- ARM uses ACI internally to actually run the PowerShell script
- Without this, ARM can't create the container — and the script never runs

**How it connects to other resources:**
```
Role Assignment
├── Grants:   deploy-script-identity  → Contributor role
└── Scope:    Resource Group
    └── Enables: deploymentScript to create temp ACI container
```

**If this didn't exist:** ARM throws "authorization failed" when trying to run the deployment script.

---

## How All 18 Resources Connect — The Full Chain

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT TIME                                   │
│                                                                          │
│  Managed Identity ──► Role Assignment                                    │
│       │                    │                                             │
│       └────────────────────┴──► deploymentScript                        │
│                                      │                                  │
│  SQL Server ──► SQL DB               │                                  │
│      │                               │                                  │
│  Firewall Rule ──────────────────────┘                                  │
│       (AllowAzureServices)    connects & seeds Products table           │
└─────────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────────┐
│                      RUNTIME — USER REQUEST                              │
│                                                                          │
│  Internet                                                                │
│     │ HTTP :80                                                           │
│     ▼                                                                    │
│  web-lb-public-ip  ──bound to──►  web-public-lb                        │
│                                        │                                │
│                          ┌─────────────┴──────────────┐                │
│                          ▼                             ▼                │
│                      web-vm-1                      web-vm-2             │
│                    (in web-subnet)               (in web-subnet)        │
│                    web-nsg guards                web-nsg guards         │
│                          │                             │                │
│                          └──────────┬──────────────────┘                │
│                                     │ HTTP :80 to 10.0.2.100            │
│                                     ▼                                   │
│                              app-private-lb                             │
│                                     │                                   │
│                          ┌──────────┴───────────┐                      │
│                          ▼                       ▼                      │
│                      app-vm-1               app-vm-2                   │
│                    (in app-subnet)         (in app-subnet)              │
│                    app-nsg guards          app-nsg guards               │
│                          │                       │                      │
│                          └──────────┬────────────┘                      │
│                                     │ TCP :1433                         │
│                                     │ DNS: myserver → 10.0.3.5          │
│                                     │   ▲                               │
│                          Private DNS Zone resolves it                   │
│                          (linked to VNet via VNet Link)                 │
│                          (IP auto-added by DNS Zone Group)              │
│                                     │                                   │
│                                     ▼                                   │
│                          sql-private-endpoint (10.0.3.x)               │
│                          (in data-subnet, guarded by data-nsg)         │
│                                     │                                   │
│                                     ▼                                   │
│                          Azure SQL Server                               │
│                                     │                                   │
│                                     ▼                                   │
│                          SampleDB → Products table                      │
│                          returns 10 rows → back up the chain           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## What Breaks If Each Resource Is Removed

| Remove This | What Breaks |
|---|---|
| Virtual Network | Everything — no network at all |
| web-nsg | Port 80 from internet blocked (no default allow) — OR everything open (security gone) |
| app-nsg | App VMs accessible from internet directly — security breach |
| data-nsg | SQL private endpoint accessible from any VM, not just app tier |
| web-lb-public-ip | No public address — users can't reach the app |
| web-public-lb | No distribution — single web VM, no failover |
| web-vm-1 AND web-vm-2 | No frontend — app unreachable |
| app-private-lb | Web VMs must hardcode app VM IPs — breaks if any app VM fails |
| app-vm-1 AND app-vm-2 | No business logic layer — SQL never queried |
| NAT Gateway | App VMs can't download setup scripts — CSE fails |
| Azure SQL Server | No database — entire data tier gone |
| SampleDB | No Products table — "database not found" error |
| Private Endpoint | App VMs route SQL traffic via internet — risky or broken |
| Private DNS Zone | App VMs get public SQL IP — traffic goes via internet |
| VNet Link | Private DNS zone unused — VMs still use public DNS |
| DNS Zone Group | No A record created — SQL FQDN doesn't resolve to private IP |
| Firewall Rule | Deployment script can't seed data — "Products" table never created |
| Deployment Script | Table and data never created automatically — manual seeding required |
| Managed Identity | Deployment script has no identity — fails immediately |
| Role Assignment | Deployment script can't create ACI container — fails immediately |

---

*Every single resource has a purpose. Remove any one of them and either security weakens or the application breaks.*