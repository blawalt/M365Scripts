# Azure App Registration Secret & Certificate Monitor & Alerter

When expiring secrets or certificates are detected (e.g., within 30 days), it sends an email alert to a specified administrator. This solution utilized the **Gmail API** to send all messages for those of us in a Gmail-only environment.
 
## Architecture

* **Platform:** Azure Automation Account (PowerShell 7.2 Runbook)
* **Authentication (Azure):** System-Assigned Managed Identity (Zero maintenance; no hardcoded client secrets).
* **Authentication (Google):** OAuth 2.0 Refresh Token (Permanent "offline" access).
* **Permissions:**
    * **Azure:** `Application.Read.All` (Granted via Graph API).
    * **Google:** `https://www.googleapis.com/auth/gmail.send`.

---

## Setup Guide

### Phase 1: Google Cloud Setup
*Goal: Create an OAuth "App" to allow the script to send emails as a specific Google user.*

1.  **Create Project:** Go to the [Google Cloud Console](https://console.cloud.google.com/) and create a new project (e.g., `Azure-Auto-Mailer`).
2.  **Enable API:** Navigate to **APIs & Services > Enable APIs and services**, search for **Gmail API**, and enable it.
3.  **Configure OAuth Consent Screen (CRITICAL):**
    * Go to **APIs & Services > OAuth consent screen** and click **Get Started**.
    * **App Information:**
        * **App Name:** `AzureMonitor`
        * **User support email:** (Select an email you have access to)
        * **Audience:** Internal
        * **Contact information:** (Enter email to receive project alerts)
    * Click **Create**.
    * **Data Access (Scopes):**
        * Click **Add or Remove Scopes**.
        * In the filter box, type `Gmail API`.
        * Check the box for `.../auth/gmail.send` and click **Update**.
        
        <img src="https://github.com/user-attachments/assets/cd898eb0-275a-40d0-a0eb-74dd9a7d7e96" width="700" alt="Gmail API Scope Selection">
4.  **Create Credentials:**
    * Go to **Credentials > Create Credentials > OAuth client ID**.
    * **Application Type:** Desktop App.
    * **Name:** `Azure Automation Runbook`.
    * **Download:** Copy your **Client ID** and **Client Secret**.

### Phase 2: Generate Google Refresh Token
*Goal: Perform a one-time human login to generate a permanent "Refresh Token" for the automation.*

Run the following script **locally on your workstation** (PowerShell) to perform the OAuth handshake:

```powershell
# --- ONE-TIME SETUP SCRIPT ---
$clientId     = "YOUR_GOOGLE_CLIENT_ID"
$clientSecret = "YOUR_GOOGLE_CLIENT_SECRET"
$redirectUri  = "http://localhost"

# 1. Build Auth URL
$scope = "[https://www.googleapis.com/auth/gmail.send](https://www.googleapis.com/auth/gmail.send)"
$authUrl = "[https://accounts.google.com/o/oauth2/v2/auth?client_id=$clientId&redirect_uri=$redirectUri&response_type=code&scope=$scope&access_type=offline&prompt=consent](https://accounts.google.com/o/oauth2/v2/auth?client_id=$clientId&redirect_uri=$redirectUri&response_type=code&scope=$scope&access_type=offline&prompt=consent)"

# 2. Launch Browser
Start-Process $authUrl

# 3. Exchange Code
$code = Read-Host "Paste the 'code' parameter from the browser URL (everything after code=)"
$tokenUri = "[https://oauth2.googleapis.com/token](https://oauth2.googleapis.com/token)"
$body = @{
    client_id = $clientId; client_secret = $clientSecret; code = $code;
    grant_type = "authorization_code"; redirect_uri = $redirectUri
}
$response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body

Write-Host "--- SAVE THIS REFRESH TOKEN ---" -ForegroundColor Green
Write-Host $response.refresh_token
```

### Phase 3: Azure Automation Setup

1.  **Create Automation Account:**
    * Create a new resource in the Azure Portal.
    * Ensure **"System Assigned Identity"** is enabled (under **Account Settings > Identity**).
2.  **Store Secrets (Variables):**
    * Go to **Shared Resources > Variables** in your Automation Account.
    * Create the following variables (Set "Encrypted" to **Yes** for secrets):
        * `GoogleClientId`: (String)
        * `GoogleClientSecret`: (String, Encrypted)
        * `GoogleRefreshToken`: (String, Encrypted - The token from Phase 2)

### Phase 4: Assign Azure Permissions
*Goal: Grant the Automation Account's identity permission to read all App Registrations. This cannot be done in the Portal UI.*

Run this PowerShell script **locally** as a Global Admin or Privileged Role Admin:

```powershell
# Prerequisites: Install-Module Microsoft.Graph
$TenantID = "YOUR_TENANT_ID"
# Find this in Azure Portal > Automation Account > Identity > Object (principal) ID
$ManagedIdentityObjectId = "OBJECT_ID_FROM_AUTOMATION_IDENTITY_BLADE"

Connect-MgGraph -TenantId $TenantID -Scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All"

$GraphAppId = "00000003-0000-0000-c000-000000000000"
$GraphSP = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'"
$Permission = $GraphSP.AppRoles | Where-Object { $_.Value -eq "Application.Read.All" }

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId `
    -PrincipalId $ManagedIdentityObjectId `
    -ResourceId $GraphSP.Id `
    -AppRoleId $Permission.Id

Write-Host "Permission 'Application.Read.All' granted successfully."

```

### Phase 5: Deployment

1.  **Create a new Runbook** in Azure Automation.
2.  **Runtime:** PowerShell 7.2 (Recommended) or 5.1.
3.  **Code:** Import or paste the contents of [`ClientSecretExpirationRunbook.ps1`](https://github.com/blawalt/M365Scripts/blob/main/Entra/ClientSecretExpirationRunbook.ps1).
4.  **Schedule:** Link the Runbook to a recurring schedule (e.g., Weekly).

## How It Works

* **Azure Login:** The script executes `Connect-AzAccount -Identity`. It uses the System-Assigned Identity to authenticate to Azure without managing credentials.
* **Scan:** It queries Microsoft Graph (`/applications`) using pagination to retrieve all App Registrations.
* **Filter:** It checks both the `passwordCredentials` (client secrets) and `keyCredentials` (certificates) of every app. If `endDateTime` is within the `$DaysThreshold` (default 30 days), it adds the credential to the alert list.
* **Google Login:** It takes the stored `GoogleRefreshToken` and exchanges it for a temporary Access Token via `oauth2.googleapis.com/token`.
* **Alert:** It constructs a MIME email message (HTML) and sends it using the Gmail API (`users/me/messages/send`).

## Troubleshooting

* **"Invalid Grant" Error:** Your Google Refresh Token has expired or been revoked. Check that your Google Cloud App status is **"In Production"**. If it was "Testing", tokens die after 7 days.
* **"Authorization_RequestDenied" Error:** The Azure Managed Identity lacks permission. Re-run the Phase 4 script to grant `Application.Read.All`.
* **404 on Google API:** Ensure the sender email defined in the script matches the account that originally authorized the Refresh Token.
