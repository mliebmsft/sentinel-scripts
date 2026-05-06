param(
    [string]$tenantId = "",
    [string]$clientId = "",
    [string]$clientSecret = "",
    [string]$subscriptionId = "",
    [string]$resourceGroupName = "",
    [string]$workspaceName = "",
    [string]$incidentAgeFilter = "30"
)

# Example:
# powershell .\CloseAllSentinelIncidents.ps1 -tenantId "<tenant-id>" -clientId "<client-id>" -clientSecret "<client-secret>" -subscriptionId "<subscription-id>" -resourceGroupName "<resource-group-name>" -workspaceName "<workspace-name>" -incidentAgeFilter 90
# Use -incidentAgeFilter all to remove the date filter entirely.

# Get a token
$tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/token"
$tokenBody = @{
    'resource'      = "https://management.azure.com/"
    'client_id'     = $clientId
    'client_secret' = $clientSecret
    'grant_type'    = "client_credentials"
}
$tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody
$accessToken = $tokenResponse.access_token
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
    $targetUri = $incident.id.ToString()
    $title = $incident.properties.title.ToString() 
    $escapedTitle = $title -replace "'", ""
    $severity = $incident.properties.severity.ToString()
    $uri = "https://management.azure.com/" + $targetUri +"?api-version=2024-03-01"
    $body = "{'properties':{'status': 'Closed','title': '"+ $escapedTitle +"','severity': '"+ $severity +"','classification':'Undetermined','classificationComment':'Closed by script'}}"
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
