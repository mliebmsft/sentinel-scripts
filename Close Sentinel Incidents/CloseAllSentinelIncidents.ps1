param(
    [ValidateSet('ClientSecret', 'Interactive', 'ManagedIdentity')]
    [string]$authMode = "ClientSecret",
    [string]$tenantId = "",
    [string]$clientId = "",
    [string]$clientSecret = "",
    [string]$subscriptionId = "",
    [string]$resourceGroupName = "",
    [string]$workspaceName = "",
    [string]$incidentAgeFilter = "30",
    [string]$incidentTitle = "",
    [switch]$NoPrompt
)

# Example:
# Client secret auth:
# powershell .\CloseAllSentinelIncidents.ps1 -authMode ClientSecret -tenantId "<tenant-id>" -clientId "<client-id>" -clientSecret "<client-secret>" -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>" -incidentAgeFilter 90
# Interactive auth:
# powershell .\CloseAllSentinelIncidents.ps1 -authMode Interactive -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>"
# Managed identity auth:
# powershell .\CloseAllSentinelIncidents.ps1 -authMode ManagedIdentity -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>"
# Use -incidentAgeFilter all to remove the date filter entirely.
# Use -incidentTitle "<incident title text>" to only close incidents with titles matching that text.

function Get-PlainTextFromSecureString {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureValue
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Resolve-RequiredParam {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$CurrentValue,
        [switch]$AsSecure
    )

    if ($CurrentValue) {
        return $CurrentValue
    }

    if ($NoPrompt) {
        throw "$Name is required."
    }

    if ($AsSecure) {
        $secureInput = Read-Host "Enter $Name" -AsSecureString
        return Get-PlainTextFromSecureString -SecureValue $secureInput
    }

    return Read-Host "Enter $Name"
}

# Get a token
$subscriptionId = Resolve-RequiredParam -Name "subscriptionId" -CurrentValue $subscriptionId
$resourceGroupName = Resolve-RequiredParam -Name "resourceGroupName" -CurrentValue $resourceGroupName
$workspaceName = Resolve-RequiredParam -Name "workspaceName" -CurrentValue $workspaceName

switch ($authMode) {
    'ClientSecret' {
        $tenantId = Resolve-RequiredParam -Name "tenantId" -CurrentValue $tenantId
        $clientId = Resolve-RequiredParam -Name "clientId" -CurrentValue $clientId
        $clientSecret = Resolve-RequiredParam -Name "clientSecret" -CurrentValue $clientSecret -AsSecure

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
        try {
            if ($tenantId) {
                Connect-AzAccount -Tenant $tenantId -AuthScope "https://management.azure.com/" -ErrorAction Stop | Out-Null
            }
            else {
                Connect-AzAccount -AuthScope "https://management.azure.com/" -ErrorAction Stop | Out-Null
            }

            Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null
            $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop
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
        catch {
            throw $_
        }
    }
    'ManagedIdentity' {
        try {
            Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
            Set-AzContext -Subscription $subscriptionId -ErrorAction Stop | Out-Null
            $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop
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
        catch {
            throw $_
        }
    }
}

if (-not $accessToken) {
    throw "Failed to acquire an Azure access token."
}

$processedIncidents = 0

# Get all incidents
$dateClause = $null
if ($incidentAgeFilter -ne 'all') {
    $dateClause = (Get-Date).AddDays(-[int]$incidentAgeFilter).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$filterClause = "&" + "$" + "filter=properties/status ne 'Closed'"
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
    $incidentStatus = [string]$incident.properties.status
    $incidentStatus = $incidentStatus.Trim()
    if ($incidentStatus.Equals('Closed', [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    $targetUri = $incident.id.ToString()
    $title = $incident.properties.title.ToString() 
    $escapedTitle = $title -replace "'", ""
    $severity = $incident.properties.severity.ToString()
    $targetUriWithProvider = "https://management.azure.com/" + $targetUri

    if ($incidentTitle -and -not $title.Equals($incidentTitle, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
    }

    # Final safety gate: do not send PUT for incidents that are already closed.
    if ($incidentStatus.Equals('Closed', [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
    }

    $uri = $targetUriWithProvider +"?api-version=2024-03-01"
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
            Write-Host "Rate limit hit. Waiting for 60 seconds before retrying..."
            Start-Sleep -Seconds 60
        } else {
            throw $_
        }
    }
    Write-Host "Checking for more incidents to process..."
    $uri = $response.nextLink

}
while ($uri)
