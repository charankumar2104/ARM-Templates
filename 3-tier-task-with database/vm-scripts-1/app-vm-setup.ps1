<#
.SYNOPSIS
  Installs IIS + ASP.NET on App Tier VMs and deploys the SQL data API page.
  Table creation is handled by ARM deploymentScript resource — NOT here.
.PARAMETER SqlFqdn      Azure SQL Server FQDN
.PARAMETER SqlAdminUser SQL admin login
.PARAMETER SqlAdminPass SQL admin password
#>
param(
    [string]$SqlFqdn      = "",
    [string]$SqlAdminUser = "sqladmin",
    [string]$SqlAdminPass = ""
)

$log = "C:\app-setup.log"
function Log { param($m) "$((Get-Date).ToString('HH:mm:ss')) - $m" | Add-Content $log; Write-Host $m }

Log "=== App VM Setup Started === SqlFqdn=$SqlFqdn"

# ── 1. Install IIS + ASP.NET 4.5 ─────────────────────────────────────────────
Log "Installing IIS and ASP.NET..."
Install-WindowsFeature -Name Web-Server,Web-Asp-Net45,Web-Net-Ext45,`
    Web-ISAPI-Ext,Web-ISAPI-Filter,Web-Default-Doc,`
    Web-Http-Errors,Web-Static-Content -IncludeManagementTools | Out-Null
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe -i | Out-Null
Log "IIS + ASP.NET installed."

# ── 2. Health check page ──────────────────────────────────────────────────────
Remove-Item "C:\inetpub\wwwroot\iisstart.htm" -Force -EA SilentlyContinue
Remove-Item "C:\inetpub\wwwroot\iisstart.png" -Force -EA SilentlyContinue
Set-Content "C:\inetpub\wwwroot\health.html" "<html><body>OK</body></html>" -Encoding UTF8

# ── 3. Create /api directory ──────────────────────────────────────────────────
New-Item -Path "C:\inetpub\wwwroot\api" -ItemType Directory -Force | Out-Null

# ── 4. Deploy data API ASPX page ──────────────────────────────────────────────
$api = @'
<%@ Page Language="C#" AutoEventWireup="true" ContentType="text/html" %>
<%@ Import Namespace="System.Data.SqlClient" %>
<%
string sqlFqdn = "__SQL_FQDN__";
string sqlUser = "__SQL_USER__";
string sqlPass = "__SQL_PASS__";
string connStr = "Server="+sqlFqdn+",1433;Database=SampleDB;User Id="+sqlUser+
                 ";Password="+sqlPass+";Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;";
%>
<div style="font-size:12px;color:#888;padding:4px 0 8px">
  &#9881; App Server: <%= System.Net.Dns.GetHostName() %> &nbsp;|&nbsp;
  SQL: <%= sqlFqdn %> &nbsp;|&nbsp; Subnet: 10.0.2.0/24
</div>
<%
int retries = 5;
while(retries-- > 0){
    try{
        using(var conn = new SqlConnection(connStr)){
            conn.Open();
            var cmd = new System.Data.SqlClient.SqlCommand(
                "SELECT ID,Name,CAST(Price AS DECIMAL(10,2)) AS Price,Category,Stock FROM dbo.Products ORDER BY ID",conn);
            var reader = cmd.ExecuteReader();
            Response.Write("<table style='width:100%;border-collapse:collapse'>");
            Response.Write("<tr style='background:#0078d4;color:#fff'>"
                +"<th style='padding:11px 14px;text-align:left'>ID</th>"
                +"<th style='padding:11px 14px;text-align:left'>Product</th>"
                +"<th style='padding:11px 14px;text-align:left'>Price</th>"
                +"<th style='padding:11px 14px;text-align:left'>Category</th>"
                +"<th style='padding:11px 14px;text-align:left'>Stock</th></tr>");
            bool alt=false;
            while(reader.Read()){
                string cat=reader["Category"].ToString();
                string bg=alt?"#f5f9ff":"#fff";
                string tag=(cat=="Electronics")?"background:#ddf4ff;color:#0550ae":"background:#dafbe1;color:#1a7f37";
                Response.Write(string.Format(
                    "<tr style='background:{5}'>"
                    +"<td style='padding:11px 14px;border-bottom:1px solid #edf0f5'><strong>#{0}</strong></td>"
                    +"<td style='padding:11px 14px;border-bottom:1px solid #edf0f5'>{1}</td>"
                    +"<td style='padding:11px 14px;border-bottom:1px solid #edf0f5'><strong>${2:F2}</strong></td>"
                    +"<td style='padding:11px 14px;border-bottom:1px solid #edf0f5'>"
                    +"<span style='padding:2px 9px;border-radius:10px;font-size:12px;font-weight:600;{4}'>{3}</span></td>"
                    +"<td style='padding:11px 14px;border-bottom:1px solid #edf0f5'>{6} units</td></tr>",
                    reader["ID"],reader["Name"],reader["Price"],cat,tag,bg,reader["Stock"]));
                alt=!alt;
            }
            Response.Write("</table>");
        }
        retries=-1;
    }catch(Exception ex){
        if(retries==0) Response.Write("<p style='color:red;padding:10px'>DB Error: "
            +System.Web.HttpUtility.HtmlEncode(ex.Message)+"</p>");
        else System.Threading.Thread.Sleep(5000);
    }
}
%>
'@

$api = $api -replace "__SQL_FQDN__",  $SqlFqdn
$api = $api -replace "__SQL_USER__",  $SqlAdminUser
$api = $api -replace "__SQL_PASS__",  $SqlAdminPass
Set-Content "C:\inetpub\wwwroot\api\data.aspx" -Value $api -Encoding UTF8
Log "api/data.aspx deployed."

iisreset /restart | Out-Null
Log "=== App VM Setup Completed ==="