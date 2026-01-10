<#
    .SYNOPSIS
    Monitors Azure App Registrations for expiring secrets and certificates and alerts via Gmail API.
    .DESCRIPTION
    1. Connects to MS Graph via System-Assigned Managed Identity.
    2. Scans ALL apps (paginated) for secrets and certificates expiring in <30 days.
    3. Authenticates to Google via Refresh Token + Client Secret.
    4. Sends an HTML email report if secrets or certificates are found.
#>

# ==============================================================================
# 1. SETUP & CONFIGURATION
# ==============================================================================
try {
    # Retrieve secure variables from Azure Automation
    # (Ensure these exist in 'Shared Resources' -> 'Variables')
    $G_ClientId     = Get-AutomationVariable -Name 'GoogleClientId'
    $G_ClientSecret = Get-AutomationVariable -Name 'GoogleClientSecret'
    $G_RefreshToken = Get-AutomationVariable -Name 'GoogleRefreshToken'
}
catch {
    Write-Error "CRITICAL: Missing Automation Variables. Please ensure GoogleClientId, GoogleClientSecret, and GoogleRefreshToken are set."
    exit
}

# Notification Settings
$SenderEmail    = "alerts@fabrikam.org"      # Must match the Google account that created the token
$RecipientEmail = "recipient@fabrikam.org" 
$DaysThreshold  = 30

# ==============================================================================
# 2. AZURE AUTHENTICATION (MANAGED IDENTITY)
# ==============================================================================
Write-Output "1. Connecting to Microsoft Graph (Managed Identity)..."

try {
    # Connect using the system-assigned identity
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    
    # Get a raw token specifically for Graph
    $azAccessToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
    Write-Output "   SUCCESS: Authenticated as System Identity."
}
catch {
    Write-Error "   FAILED: Could not login with Managed Identity. Did you run the permission grant script?"
    Write-Error $_.Exception.Message
    exit
}

# ==============================================================================
# 3. SCAN APPLICATIONS (PAGINATED)
# ==============================================================================
Write-Output "2. Scanning App Registrations..."

$graphUri = "https://graph.microsoft.com/v1.0/applications?`$select=id,displayName,appId"
$headers  = @{ Authorization = "Bearer $azAccessToken" }

$expiringApps     = @()
$totalAppsScanned = 0
$today            = Get-Date

do {
    # Fetch page of apps
    # Note: Using Invoke-RestMethod for raw speed and simple object handling
    $response = Invoke-RestMethod -Uri $graphUri -Headers $headers -Method GET
    $appsList = $response.value
    $totalAppsScanned += $appsList.Count

    Write-Output "   Processing batch of $($appsList.Count) apps..."

    foreach ($app in $appsList) {
        # Fetch client secrets (passwordCredentials) for this specific app
        $secretUri = "https://graph.microsoft.com/v1.0/applications/$($app.id)/passwordCredentials"
        
        try {
            $secretsResponse = Invoke-RestMethod -Uri $secretUri -Headers $headers -Method GET -ErrorAction Stop
            
            foreach ($secret in $secretsResponse.value) {
                $endDate  = [datetime]$secret.endDateTime
                $daysLeft = ($endDate - $today).Days

                # Check expiration (Alert if within threshold, ignore if already expired > 10 days ago)
                if ($daysLeft -le $DaysThreshold -and $daysLeft -ge -10) {
                    Write-Output "   [!] ALERT: $($app.displayName) secret expires in $daysLeft days"
                    $expiringApps += [PSCustomObject]@{
                        Name     = $app.displayName
                        Days     = $daysLeft
                        Date     = $endDate
                        AppId    = $app.appId
                        Type     = "Client Secret"
                    }
                }
            }
        }
        catch {
            # Permission errors on specific MS-managed apps are normal/expected
            continue 
        }

        # Fetch certificates (keyCredentials) for this specific app
        $certUri = "https://graph.microsoft.com/v1.0/applications/$($app.id)/keyCredentials"
        
        try {
            $certsResponse = Invoke-RestMethod -Uri $certUri -Headers $headers -Method GET -ErrorAction Stop
            
            foreach ($cert in $certsResponse.value) {
                $endDate  = [datetime]$cert.endDateTime
                $daysLeft = ($endDate - $today).Days

                # Check expiration (Alert if within threshold, ignore if already expired > 10 days ago)
                if ($daysLeft -le $DaysThreshold -and $daysLeft -ge -10) {
                    Write-Output "   [!] ALERT: $($app.displayName) certificate expires in $daysLeft days"
                    $expiringApps += [PSCustomObject]@{
                        Name     = $app.displayName
                        Days     = $daysLeft
                        Date     = $endDate
                        AppId    = $app.appId
                        Type     = "Certificate"
                    }
                }
            }
        }
        catch {
            # Permission errors on specific MS-managed apps are normal/expected
            continue 
        }
    }

    # Handle Pagination
    if ($response.'@odata.nextLink') {
        $graphUri = $response.'@odata.nextLink'
    } else {
        $graphUri = $null
    }

} while ($graphUri)

Write-Output "--------------------------------------------------"
Write-Output "Scan Complete. Total Scanned: $totalAppsScanned"
Write-Output "Expiring Credentials Found: $($expiringApps.Count)"
Write-Output "--------------------------------------------------"

if ($expiringApps.Count -eq 0) {
    Write-Output "No action required. Exiting."
    exit
}

# ==============================================================================
# 4. GOOGLE AUTHENTICATION (REFRESH TOKEN FLOW)
# ==============================================================================
Write-Output "3. Authenticating to Google..."

$gTokenUri = "https://oauth2.googleapis.com/token"
$gBody = @{
    client_id     = $G_ClientId
    client_secret = $G_ClientSecret
    refresh_token = $G_RefreshToken
    grant_type    = "refresh_token"
}

try {
    $gResponse = Invoke-RestMethod -Method Post -Uri $gTokenUri -Body $gBody -ErrorAction Stop
    $gAccessToken = $gResponse.access_token
    Write-Output "   SUCCESS: Google Access Token Refreshed."
}
catch {
    Write-Error "   FAILED to refresh Google Token. Check your Client Secret and Refresh Token variables."
    Write-Error $_.Exception.Message
    exit
}

# ==============================================================================
# 5. SEND EMAIL REPORT
# ==============================================================================
Write-Output "4. Sending Email Report..."

# Build HTML List
$listHtml = ""
foreach ($item in $expiringApps) {
    $color = if($item.Days -lt 7){"red"}else{"#e65100"} # Red for urgent, Orange for warning
    $typeIcon = if($item.Type -eq "Certificate"){"🔐"}else{"🔑"}
    $listHtml += "<li style='margin-bottom: 5px;'>$typeIcon <strong style='color:$color'>$($item.Name)</strong><br><span style='font-size:13px;'><b>$($item.Type)</b> expires in <b>$($item.Days) days</b> ($($item.Date))</span><br><span style='font-size:12px;color:gray'>App ID: $($item.AppId)</span></li>"
}

$htmlBody = @"
<html>
<body style="font-family: Segoe UI, Helvetica, Arial, sans-serif; color: #333;">
    <h3 style="color: #d32f2f;">⚠️ Azure Credential Expiration Warning</h3>
    <p>The following applications have client secrets or certificates expiring within <strong>$DaysThreshold days</strong>:</p>
    <ul>
        $listHtml
    </ul>
    <p>Please log in to the <a href="https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps">Azure Portal</a> to rotate these credentials.</p>
    <hr>
    <p style="font-size: 12px; color: gray;">Generated by Azure Automation • Scanned $totalAppsScanned apps</p>
</body>
</html>
"@

# Construct MIME Message
$mimeMessage = "From: $SenderEmail`r`n"
$mimeMessage += "To: $RecipientEmail`r`n"
$mimeMessage += "Subject: Action Required: Azure Credentials Expiring ($($expiringApps.Count))`r`n"
$mimeMessage += "Content-Type: text/html; charset=utf-8`r`n`r`n"
$mimeMessage += "$htmlBody"

# Base64URL Encode (Required by Gmail API)
$bytes = [System.Text.Encoding]::UTF8.GetBytes($mimeMessage)
$base64 = [Convert]::ToBase64String($bytes)
$base64Url = $base64.Replace('+', '-').Replace('/', '_').Replace('=', '')

# Send via Gmail API
$gmailUri = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
$gmailPayload = @{ raw = $base64Url }

try {
    Invoke-RestMethod -Uri $gmailUri -Method Post -Headers @{ Authorization = "Bearer $gAccessToken" } -Body ($gmailPayload | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
    Write-Output "   SUCCESS: Email sent to $RecipientEmail."
}
catch {
    Write-Error "   FAILED to send email."
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        Write-Error "   Google API Error: $($reader.ReadToEnd())"
    }
}
