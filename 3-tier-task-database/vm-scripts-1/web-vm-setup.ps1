<#
.SYNOPSIS
  Installs IIS + ASP.NET on Web Tier VMs and deploys the front-end page.
.PARAMETER AppLbIp
  Private IP of the internal (App) load balancer. Default: 10.0.2.100
#>
param(
    [string]$AppLbIp = "10.0.2.100"
)

$logFile = "C:\web-setup.log"
function Log { param($m) $ts=(Get-Date).ToString("HH:mm:ss"); "$ts - $m" | Add-Content $logFile; Write-Host "$ts - $m" }

Log "=== Web VM Setup Started ==="
Log "AppLbIp = $AppLbIp"

# ── Install IIS + ASP.NET ─────────────────────────────────────────────────────
Log "Installing IIS and ASP.NET 4.5..."
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Net-Ext45, `
    Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Default-Doc, `
    Web-Http-Errors, Web-Static-Content -IncludeManagementTools | Out-Null

C:\Windows\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe -i | Out-Null
Log "IIS + ASP.NET installed."

# ── Health check page ─────────────────────────────────────────────────────────
Remove-Item "C:\inetpub\wwwroot\iisstart.htm"  -Force -EA SilentlyContinue
Remove-Item "C:\inetpub\wwwroot\iisstart.png"  -Force -EA SilentlyContinue
Set-Content -Path "C:\inetpub\wwwroot\health.html" `
    -Value "<html><body>OK</body></html>" -Encoding UTF8

# ── Front-end ASPX page ───────────────────────────────────────────────────────
$page = @'
<%@ Page Language="C#" AutoEventWireup="true" %>
<%@ Import Namespace="System.Net" %>
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Azure 3-Tier Demo</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:"Segoe UI",Arial,sans-serif;background:#f0f4f8}
    .hdr{background:linear-gradient(135deg,#0078d4,#005a9e);color:#fff;padding:28px 40px}
    .hdr h1{font-size:26px;font-weight:600}
    .flow{display:flex;align-items:center;gap:8px;margin-top:10px;font-size:13px;opacity:.9}
    .flow span{background:rgba(255,255,255,.2);padding:3px 10px;border-radius:4px;font-weight:600}
    .flow i{opacity:.7}
    .wrap{max-width:1000px;margin:28px auto;padding:0 20px}
    .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-bottom:24px}
    .card{background:#fff;border-radius:8px;padding:18px;box-shadow:0 2px 6px rgba(0,0,0,.08)}
    .card label{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:#0078d4;font-weight:700;margin-bottom:4px}
    .card p{font-size:17px;font-weight:600;color:#1a1a1a}
    .box{background:#fff;border-radius:8px;padding:22px;box-shadow:0 2px 6px rgba(0,0,0,.08)}
    .box h2{font-size:18px;font-weight:600;margin-bottom:16px;color:#1a1a1a}
    table{width:100%;border-collapse:collapse}
    th{background:#0078d4;color:#fff;padding:11px 14px;text-align:left;font-size:13px}
    td{padding:11px 14px;border-bottom:1px solid #edf0f5;font-size:14px}
    tr:last-child td{border:0}
    tr:hover td{background:#f5f9ff}
    .tag{display:inline-block;padding:2px 9px;border-radius:10px;font-size:12px;font-weight:600}
    .Electronics{background:#ddf4ff;color:#0550ae}
    .Accessories{background:#dafbe1;color:#1a7f37}
    .err{background:#fff5f5;border:1px solid #fcc;border-radius:6px;padding:14px;color:#c0392b;font-size:14px}
  </style>
</head>
<body>
<div class="hdr">
  <h1>&#9729; Azure 3-Tier Architecture Live Demo</h1>
  <div class="flow">
    <span>Internet</span><i>&#8594;</i>
    <span>Public LB (LB-1)</span><i>&#8594;</i>
    <span>Web VMs</span><i>&#8594;</i>
    <span>Private LB (LB-2)</span><i>&#8594;</i>
    <span>App VMs</span><i>&#8594;</i>
    <span>SQL Server</span>
  </div>
</div>
<div class="wrap">
  <div class="cards">
    <div class="card"><label>&#127760; Web Server</label><p><%= System.Net.Dns.GetHostName() %></p></div>
    <div class="card"><label>&#128203; Web Subnet</label><p>10.0.1.0/24 (Public)</p></div>
    <div class="card"><label>&#128336; Served At (UTC)</label><p style="font-size:13px"><%= DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") %></p></div>
  </div>
  <div class="box">
    <h2>&#128722; Product Catalog &nbsp;<small style="font-size:13px;font-weight:400;color:#666">Live data via App LB &#8594; App VM &#8594; SQL</small></h2>
    <%
    string apiUrl = "http://__APP_LB_IP__/api/data.aspx";
    for(int i=0;i<3;i++){
        try {
            var wc = new System.Net.WebClient();
            wc.Headers["X-Web-Host"] = System.Net.Dns.GetHostName();
            Response.Write(wc.DownloadString(apiUrl));
            break;
        } catch(Exception ex){
            if(i==2){
                Response.Write("<div class='err'><strong>&#9888; App tier unreachable</strong><br/>"+
                    "App LB: "+apiUrl+"<br/>Error: "+System.Web.HttpUtility.HtmlEncode(ex.Message)+"</div>");
            } else { System.Threading.Thread.Sleep(2000); }
        }
    }
    %>
  </div>
</div>
</body></html>
'@

# Inject the actual App LB IP
$page = $page -replace "__APP_LB_IP__", $AppLbIp
Set-Content -Path "C:\inetpub\wwwroot\index.aspx" -Value $page -Encoding UTF8
Log "index.aspx written with AppLbIp=$AppLbIp"

# ── Set default document ──────────────────────────────────────────────────────
Import-Module WebAdministration -ErrorAction SilentlyContinue
try {
    Set-WebConfiguration //defaultDocument/files "IIS:\Sites\Default Web Site" `
        -Value @{value="index.aspx"}
    Log "Default document set to index.aspx"
} catch { Log "Warning: could not set default doc via WebAdmin: $_" }

iisreset /restart | Out-Null
Log "=== Web VM Setup Completed ==="