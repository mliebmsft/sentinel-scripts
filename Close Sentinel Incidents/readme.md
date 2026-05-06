# CloseAllSentinelIncidents.ps1

This script authenticates to Azure, queries Microsoft Sentinel incidents in a Log Analytics workspace, and closes matching incidents automatically.

It is designed for bulk cleanup workflows (for example, closing stale `New` incidents).

## What the Script Does

- Authenticates to Azure using one of three modes: `ClientSecret`, `Interactive`, or `ManagedIdentity`.
- Calls the Azure Management API for Microsoft Sentinel incidents.
- Filters incidents where status is `New`.
- Optionally applies an age filter based on `createdTimeUtc`.
- Closes each matching incident by setting:
  - `status`: `Closed`
  - `classification`: `Undetermined`
  - `classificationComment`: `Closed by script`
- Follows pagination using `nextLink` until all results are processed.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+.
- Network access to:
  - `https://login.microsoftonline.com`
  - `https://management.azure.com`
- An Azure AD app registration (service principal) with:
  - `tenantId`
  - `clientId`
  - `clientSecret`
- If using `Interactive` or `ManagedIdentity` mode:
  - Az PowerShell module with `Az.Accounts` available.
  - Valid signed-in user context (`Interactive`) or managed identity-enabled host (`ManagedIdentity`).
- RBAC permissions in Azure for the target Sentinel workspace (or broader scope) that allow reading and updating incidents.

## Setup

1. Choose an auth mode:
  - `ClientSecret`: service principal and secret
  - `Interactive`: user sign-in
  - `ManagedIdentity`: Azure resource identity
2. Ensure the chosen identity has Azure RBAC rights to read and update Sentinel incidents.
3. Collect the required values:
   - Tenant ID
   - Subscription ID
   - Resource Group Name
   - Log Analytics Workspace Name

For `ClientSecret`, also collect Client ID and Client Secret.

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `authMode` | string | No | `"ClientSecret"` | Authentication mode: `ClientSecret`, `Interactive`, or `ManagedIdentity`. |
| `tenantId` | string | Yes | `""` | Azure AD tenant ID used to request an access token. |
| `clientId` | string | Yes | `""` | App registration (service principal) client ID. |
| `clientSecret` | string | Yes | `""` | Client secret for the app registration. |
| `subscriptionId` | string | Yes | `""` | Azure subscription containing the Sentinel workspace. |
| `resourceGroupName` | string | Yes | `""` | Resource group that contains the workspace. |
| `workspaceName` | string | Yes | `""` | Log Analytics workspace name linked to Sentinel. |
| `incidentAgeFilter` | string | No | `"30"` | Number of days for age filtering, or `all` to disable date filtering. |
| `incidentTitle` | string | No | `""` | Exact incident title filter (case-insensitive). Only incidents with this title are closed. |
| `NoPrompt` | switch | No | not set | If set, missing required parameters throw immediately instead of prompting interactively. |

Parameter requirements by auth mode:

- `ClientSecret`: requires `tenantId`, `clientId`, `clientSecret`, `subscriptionId`, `resourceGroupName`, `workspaceName`.
- `Interactive`: requires `subscriptionId`, `resourceGroupName`, `workspaceName`; `tenantId` optional.
- `ManagedIdentity`: requires `subscriptionId`, `resourceGroupName`, `workspaceName`.

## Usage

### ClientSecret mode (default auth mode)

```powershell
powershell .\CloseAllSentinelIncidents.ps1 \
  -authMode ClientSecret \
  -tenantId "<tenant-id>" \
  -clientId "<client-id>" \
  -clientSecret "<client-secret>" \
  -subscriptionId "<subscription-id>" \
  -resourceGroupName "<resource-group-name>" \
  -workspaceName "<workspace-name>"
```

### Interactive mode (no app registration required)

```powershell
powershell .\CloseAllSentinelIncidents.ps1 \
  -authMode Interactive \
  -subscriptionId "<subscription-id>" \
  -resourceGroupName "<resource-group-name>" \
  -workspaceName "<workspace-name>" \
  -incidentAgeFilter 90
```

### ManagedIdentity mode (no app registration required)

```powershell
powershell .\CloseAllSentinelIncidents.ps1 \
  -authMode ManagedIdentity \
  -subscriptionId "<subscription-id>" \
  -resourceGroupName "<resource-group-name>" \
  -workspaceName "<workspace-name>"
```

### Close all `New` incidents (no date filter)

```powershell
powershell .\CloseAllSentinelIncidents.ps1 \
  -authMode ClientSecret \
  -tenantId "<tenant-id>" \
  -clientId "<client-id>" \
  -clientSecret "<client-secret>" \
  -subscriptionId "<subscription-id>" \
  -resourceGroupName "<resource-group-name>" \
  -workspaceName "<workspace-name>" \
  -incidentAgeFilter all
```

### Close only incidents with a specific title

```powershell
powershell .\CloseAllSentinelIncidents.ps1 \
  -authMode Interactive \
  -subscriptionId "<subscription-id>" \
  -resourceGroupName "<resource-group-name>" \
  -workspaceName "<workspace-name>" \
  -incidentTitle "Impossible travel activity detected"
```

### Non-interactive mode for automation

```powershell
powershell .\CloseAllSentinelIncidents.ps1 \
  -authMode ManagedIdentity \
  -subscriptionId "<subscription-id>" \
  -resourceGroupName "<resource-group-name>" \
  -workspaceName "<workspace-name>" \
  -NoPrompt
```

## Example Output

```text
1 incidents closed
2 incidents closed
3 incidents closed
Next link: https://management.azure.com/subscriptions/.../incidents?api-version=2024-03-01&$skipToken=...
4 incidents closed
Next link:
```

## Notes and Behavior Details

- Only incidents currently in `New` status are targeted.
- If `incidentTitle` is provided, only `New` incidents with an exact title match are targeted (case-insensitive).
- The script updates incidents with a full `PUT` request for selected properties.
- Incident titles have single quotes removed before update to avoid malformed request bodies.
- If an API rate-limit error message is detected, the script waits 60 seconds and retries.

## Troubleshooting

- Authentication failures:
  - For `ClientSecret`, validate `tenantId`, `clientId`, and `clientSecret`.
  - Confirm the secret is not expired.
  - For `Interactive` and `ManagedIdentity`, confirm `Az.Accounts` is installed.
- Authorization failures (403):
  - Ensure RBAC permissions are assigned at the correct scope.
- No incidents closed:
  - Confirm incidents are in `New` state.
  - Check `incidentAgeFilter` is not too restrictive.
  - If `incidentTitle` is set, confirm it exactly matches the incident title text.
- API throttling:
  - The script retries after 60 seconds on rate-limit errors.

## Security Guidance

- Avoid hardcoding secrets in scripts checked into source control.
- Prefer secure secret storage (for example, environment variables or Azure Key Vault).
- Use least-privilege RBAC for the service principal.
