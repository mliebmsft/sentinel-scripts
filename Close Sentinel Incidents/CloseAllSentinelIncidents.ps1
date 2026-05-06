param(
    [ValidateSet('ClientSecret', 'Interactive', 'ManagedIdentity')]
    [string]$authMode = "ClientSecret",
    [string]$tenantId = "",
    [string]$clientId = "",
    [string]$clientSecret = "",
    [string]$subscriptionId = "",
    [string]$resourceGroupName = "",
    [string]$workspaceName = "",
    [string]$incidentAgeFilter = "30"
)

# Example:
# Client secret auth:
# powershell .\CloseAllSentinelIncidents.ps1 -authMode ClientSecret -tenantId "<tenant-id>" -clientId "<client-id>" -clientSecret "<client-secret>" -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>" -incidentAgeFilter 90
# Interactive auth:
# powershell .\CloseAllSentinelIncidents.ps1 -authMode Interactive -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>"
# Managed identity auth:
# powershell .\CloseAllSentinelIncidents.ps1 -authMode ManagedIdentity -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>"
# Use -incidentAgeFilter all to remove the date filter entirely.

# Get a token
if (-not $subscriptionId) {
    throw "subscriptionId is required."
}
if (-not $resourceGroupName) {
    throw "resourceGroupName is required."
}
if (-not $workspaceName) {
    throw "workspaceName is required."
}

switch ($authMode) {
    'ClientSecret' {
        if (-not $tenantId) {
            throw "tenantId is required when authMode is ClientSecret."
        }
        if (-not $clientId) {
            throw "clientId is required when authMode is ClientSecret."
        }
        if (-not $clientSecret) {
            throw "clientSecret is required when authMode is ClientSecret."
        }

        $tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/token"
        $tokenBody = @{
            'resource'      = "https://management.azure.com/"
            'client_id'     = $clientId
            'client_secret' = $clientSecret
            'grant_type'    = "client_credentials"
        }
        $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody
        $accessToken = $tokenResponse.access_token
    }
    'Interactive' {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            throw "Az.Accounts module is required for Interactive auth. Install it with: Install-Module Az.Accounts -Scope CurrentUser"
        }

        if ($tenantId) {
            Connect-AzAccount -Tenant $tenantId | Out-Null
        }
        else {
            Connect-AzAccount | Out-Null
        }

        Set-AzContext -Subscription $subscriptionId | Out-Null
        $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
        if ($token.Token -is [System.Security.SecureString]) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token.Token)
            try {
                $accessToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        else {
            $accessToken = $token.Token
        }
    }
    'ManagedIdentity' {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            throw "Az.Accounts module is required for ManagedIdentity auth. Install it with: Install-Module Az.Accounts -Scope CurrentUser"
        }

        Connect-AzAccount -Identity | Out-Null
        Set-AzContext -Subscription $subscriptionId | Out-Null
        $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
        if ($token.Token -is [System.Security.SecureString]) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token.Token)
            try {
                $accessToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        else {
            $accessToken = $token.Token
        }
    }
}

$processedIncidents = 0

# Get all incidents
$dateClause = $null
if ($incidentAgeFilter -ne 'all') {
    $dateClause = (Get-Date).AddDays(-[int]$incidentAgeFilter).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$filterClause = "&" + "$" + "filter=properties/status eq 'New'"
if ($dateClause) {
    $filterClause += " and properties/createdTimeUtc le " + $dateClause
}
$uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/incidents?api-version=2024-03-01" + $filterClause
#Write-Host "URI: $uri"
$headers = @{
    'Authorization' = "Bearer $accessToken"
}
do {
    try{
$response = Invoke-RestMethod -Uri $uri -Headers $headers
$incidents = $response.value

# Loop through each incident and close it
foreach ($incident in $incidents) {

    #$incidentDate = $incident.properties.createdTimeUtc.ToString()
    #$incidentStatus = $incident.properties.status.ToString()
    $targetUri = $incident.id.ToString()
    $title = $incident.properties.title.ToString() 
    $escapedTitle = $title -replace "'", ""
    $severity = $incident.properties.severity.ToString()

    $uri = "https://management.azure.com/" + $targetUri +"?api-version=2024-03-01"
    #Write-Host "Title: $escapedTitle"
    #Write-Host "Incident Status: $incidentStatus"
    #Write-Host "Incident Date: $incidentDate"
    $body = "{'properties':{'status': 'Closed','title': '"+ $escapedTitle +"','severity': '"+ $severity +"','classification':'Undetermined','classificationComment':'Closed by script'}}"
    #Write-Host "Body: $body"
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body $body -ContentType "application/json" 
    $processedIncidents++
    Write-Host "$processedIncidents incidents closed"
}
    }
    catch {
        # If a rate limit error occurs, wait for 60 seconds before retrying
        if ($_.Exception.Message -like "*rate limit*") {
            Start-Sleep -Seconds 60
        } else {
            throw $_
        }
    }
    Write-Host "Next link: $($response.nextLink)"
    $uri = $response.nextLink

}
while ($uri)
