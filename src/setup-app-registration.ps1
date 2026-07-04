#!/usr/bin/env pwsh
# GitHub Actions Azure OIDC Complete Setup (PowerShell)
# Usage:
#   ./setup-app-registration.ps1 -SubscriptionId <subscription-id> [-VerboseMode] [-ManagementGroupMode] [-ManagementGroupName <name>]
#   pwsh ./setup-app-registration.ps1 -SubscriptionId <subscription-id> [-VerboseMode] [-ManagementGroupMode] [-ManagementGroupName <name>]
#   ./setup-app-registration.ps1 -All [-ManagementGroupMode] [-ManagementGroupName <name>] [-VerboseMode]
#   pwsh ./setup-app-registration.ps1 -All [-ManagementGroupMode] [-ManagementGroupName <name>] [-VerboseMode]

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SubscriptionId,
    [switch]$All,
    [switch]$VerboseMode,
    [switch]$ManagementGroupMode,
    [string]$ManagementGroupName
)

$ErrorActionPreference = "Stop"

$AppId = "03130519-c919-4db6-b784-49672aeadbdb"
$AppName = ""

$TempContributorAssignmentIds = @()
$TempUserAccessAdministratorAssignmentIds = @()
$CleanupDone = $false
$CurrentUserId = ""
$CurrentPrincipalType = ""
$CurrentSubscriptionId = ""
$OnboardedSubscriptions = @()

if (-not $ManagementGroupMode -and -not [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
    $ManagementGroupMode = $true
}

function Write-VerboseLog {
    param([string]$Message)

    if ($script:VerboseMode) {
        Write-Host "[VERBOSE] $Message"
    }
}

function Get-OutputString {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [System.Array]) {
        return (($Value | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }

    return ([string]$Value).Trim()
}

function Split-NonEmptyLines {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Invoke-Cleanup {
    param([string]$Source = "finally")

    if ($script:CleanupDone) {
        return
    }

    if ($script:TempContributorAssignmentIds.Count -eq 0 -and $script:TempUserAccessAdministratorAssignmentIds.Count -eq 0) {
        return
    }

    if ($Source -eq "finally") {
        Write-Host "Cleaning up temporary access before exit..."
    }

    foreach ($assignmentId in @($script:TempContributorAssignmentIds)) {
        if ([string]::IsNullOrWhiteSpace($assignmentId)) {
            continue
        }

        & az role assignment delete --ids $assignmentId 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Temporary Contributor access removed ($assignmentId)"
        }
        else {
            Write-Host "WARNING - Could not remove temporary Contributor access automatically ($assignmentId)"
        }
    }

    foreach ($assignmentId in @($script:TempUserAccessAdministratorAssignmentIds)) {
        if ([string]::IsNullOrWhiteSpace($assignmentId)) {
            continue
        }

        & az role assignment delete --ids $assignmentId 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Temporary User Access Administrator access removed ($assignmentId)"
        }
        else {
            Write-Host "WARNING - Could not remove temporary User Access Administrator access automatically ($assignmentId)"
        }
    }

    $script:CleanupDone = $true
}

function Register-RequiredProviders {
    Write-Host "Registering Azure Resource Providers..."
    Write-VerboseLog "Registering required resource providers for Azure services"

    $providers = @(
        "Microsoft.Batch",
        "Microsoft.Compute",
        "Microsoft.Capacity",
        "Microsoft.ManagedIdentity",
        "Microsoft.ManagedServices"
    )

    foreach ($provider in $providers) {
        Write-VerboseLog "Registering provider: $provider"
        $providerOutput = az provider register --namespace $provider 2>&1
        $providerStatus = $LASTEXITCODE
        $providerText = Get-OutputString $providerOutput

        if ($VerboseMode -and -not [string]::IsNullOrWhiteSpace($providerText)) {
            Write-Host $providerText
        }

        if ($providerStatus -eq 0) {
            Write-Host "Registered: $provider"
        }
        else {
            Write-Host "WARNING - Could not register provider: $provider"
            Write-VerboseLog "Provider registration failed for ${provider}: $providerText"
        }
    }

    Write-Host ""
}

function Show-ManagementGroupSelection {
    param(
        [string]$ScriptInvocation,
        [bool]$IncludeAll,
        [string]$SelectedSubscriptionId,
        [bool]$IncludeVerbose
    )

    $mgRaw = Get-OutputString (az account management-group list --query "[].{displayName:displayName,name:name}" -o tsv 2>$null)
    $mgLines = Split-NonEmptyLines $mgRaw

    if ($mgLines.Count -eq 0) {
        throw "FAILED - No management groups found"
    }

    Write-Host ""
    Write-Host "Management Groups Found"
    Write-Host "======================="
    Write-Host ""
    Write-Host "Please run the script again with a specific management group name:"
    Write-Host ""

    foreach ($line in $mgLines) {
        $parts = $line -split "`t"
        $displayName = $parts[0]
        $name = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }

        Write-Host "- $displayName ($name)"

        $rerun = "pwsh ./$ScriptInvocation"
        if ($IncludeAll) {
            $rerun += " -All"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($SelectedSubscriptionId)) {
            $rerun += " -SubscriptionId `"$SelectedSubscriptionId`""
        }

        $rerun += " -ManagementGroupMode -ManagementGroupName `"$name`""
        if ($IncludeVerbose) {
            $rerun += " -VerboseMode"
        }

        Write-Host "  $rerun"
        Write-Host ""
    }
}

function Get-ManagementGroupSubscriptionIds {
    param([string]$ManagementGroupId)

    $mgTreeJson = Get-OutputString (az account management-group show --name $ManagementGroupId --expand --recurse -o json 2>$null)
    if ([string]::IsNullOrWhiteSpace($mgTreeJson)) {
        return @()
    }

    $mgTree = $mgTreeJson | ConvertFrom-Json
    $subscriptionIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Add-SubscriptionIdsFromNode {
        param(
            [object]$Node,
            [System.Collections.Generic.HashSet[string]]$Set
        )

        if ($null -eq $Node) {
            return
        }

        $nodeType = Get-OutputString $Node.type
        $nodeName = Get-OutputString $Node.name
        $nodeId = Get-OutputString $Node.id

        if ($nodeId -match "/subscriptions/([0-9a-fA-F-]{36})") {
            [void]$Set.Add($Matches[1])
        }
        elseif (($nodeType -eq "/subscriptions" -or $nodeType -match "subscriptions") -and $nodeName -match "^[0-9a-fA-F-]{36}$") {
            [void]$Set.Add($nodeName)
        }

        if ($null -ne $Node.children) {
            foreach ($child in @($Node.children)) {
                Add-SubscriptionIdsFromNode -Node $child -Set $Set
            }
        }
    }

    Add-SubscriptionIdsFromNode -Node $mgTree -Set $subscriptionIdSet
    return @($subscriptionIdSet)
}

function Get-CurrentPrincipalId {
    param(
        [string]$PrincipalType,
        [string]$PrincipalName
    )

    if ($PrincipalType -eq "user") {
        return Get-OutputString (az ad signed-in-user show --query id -o tsv 2>$null)
    }

    if ($PrincipalType -eq "serviceprincipal") {
        $principalId = Get-OutputString (az ad sp show --id $PrincipalName --query id -o tsv 2>$null)
        if ([string]::IsNullOrWhiteSpace($principalId) -or $principalId -eq "null") {
            $principalId = Get-OutputString (az ad sp list --filter "appId eq '$PrincipalName'" --query "[0].id" -o tsv 2>$null)
        }

        return $principalId
    }

    $fallbackUserId = Get-OutputString (az ad signed-in-user show --query id -o tsv 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($fallbackUserId) -and $fallbackUserId -ne "null") {
        return $fallbackUserId
    }

    return Get-OutputString (az ad sp show --id $PrincipalName --query id -o tsv 2>$null)
}

try {
    Write-Host "GitHub Actions Azure OIDC Complete Setup"
    Write-Host "========================================="
    Write-Host ""

    Write-Host "Checking Azure CLI connectivity..."
    & az account show 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "FAILED - Not logged into Azure CLI. Please run: az login"
    }

    $tenantId = Get-OutputString (az account show --query tenantId -o tsv 2>$null)
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        throw "FAILED - Could not retrieve tenant ID"
    }

    if ($PSBoundParameters.Count -eq 0 -and [string]::IsNullOrWhiteSpace($SubscriptionId) -and -not $All -and -not $ManagementGroupMode -and [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
        $envSubscriptionId = [System.Environment]::GetEnvironmentVariable("AZURE_SUBSCRIPTION_ID")
        if ([string]::IsNullOrWhiteSpace($envSubscriptionId)) {
            $envSubscriptionId = [System.Environment]::GetEnvironmentVariable("azure_subscription_id")
        }

        if (-not [string]::IsNullOrWhiteSpace($envSubscriptionId)) {
            Write-Host "No parameters provided, using AZURE_SUBSCRIPTION_ID from environment"
            $SubscriptionId = $envSubscriptionId.Trim()
        }
    }

    if ($ManagementGroupMode -and [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
        $scriptInvocation = $MyInvocation.MyCommand.Name
        if ([string]::IsNullOrWhiteSpace($scriptInvocation)) {
            $scriptInvocation = "setup-app-registration.ps1"
        }

        Show-ManagementGroupSelection -ScriptInvocation $scriptInvocation -IncludeAll $All.IsPresent -SelectedSubscriptionId $SubscriptionId -IncludeVerbose $VerboseMode.IsPresent
        return
    }

    $subscriptionIds = @()
    $targetMgId = ""

    if ($All) {
        if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
            throw "FAILED - Use either -All or -SubscriptionId, not both"
        }

        Write-Host "All mode enabled: collecting subscriptions..."

        if ($ManagementGroupMode) {
            if (-not [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
                $targetMgId = Get-OutputString (az account management-group list --query "[?displayName=='$ManagementGroupName' || name=='$ManagementGroupName'].name | [0]" -o tsv 2>$null)
                if ([string]::IsNullOrWhiteSpace($targetMgId) -or $targetMgId -eq "null") {
                    throw "FAILED - Management group '$ManagementGroupName' not found"
                }
            }
            else {
                $targetMgId = Get-OutputString (az account management-group list --query "[?displayName=='Tenant Root Group' || name=='$tenantId'].name | [0]" -o tsv 2>$null)
                if ([string]::IsNullOrWhiteSpace($targetMgId) -or $targetMgId -eq "null") {
                    $targetMgId = Get-OutputString (az account management-group list --query "[0].name" -o tsv 2>$null)
                }
            }

            if ([string]::IsNullOrWhiteSpace($targetMgId) -or $targetMgId -eq "null") {
                throw "FAILED - Could not determine management group for -All mode"
            }

            Write-VerboseLog "Collecting subscriptions under management group recursively: $targetMgId"
            $subscriptionIds = Get-ManagementGroupSubscriptionIds -ManagementGroupId $targetMgId
        }
        else {
            Write-VerboseLog "Collecting all subscriptions from tenant"
            $allSubsRaw = Get-OutputString (az account list --query "[].id" -o tsv 2>$null)
            $subscriptionIds = Split-NonEmptyLines $allSubsRaw
        }

        if ($subscriptionIds.Count -eq 0) {
            throw "FAILED - No subscriptions found for -All mode"
        }
    }

    if (-not $All) {
        if ($ManagementGroupMode) {
            if (-not [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
                $targetMgId = Get-OutputString (az account management-group list --query "[?displayName=='$ManagementGroupName' || name=='$ManagementGroupName'].name | [0]" -o tsv 2>$null)
                if ([string]::IsNullOrWhiteSpace($targetMgId) -or $targetMgId -eq "null") {
                    throw "FAILED - Management group '$ManagementGroupName' not found"
                }
            }
            else {
                $targetMgId = Get-OutputString (az account management-group list --query "[?displayName=='Tenant Root Group' || name=='$tenantId'].name | [0]" -o tsv 2>$null)
                if ([string]::IsNullOrWhiteSpace($targetMgId) -or $targetMgId -eq "null") {
                    $targetMgId = Get-OutputString (az account management-group list --query "[0].name" -o tsv 2>$null)
                }
            }

            if ([string]::IsNullOrWhiteSpace($targetMgId) -or $targetMgId -eq "null") {
                throw "FAILED - Could not determine management group subscriptions"
            }

            Write-VerboseLog "Collecting subscriptions under management group recursively: $targetMgId"
            $subscriptionIds = Get-ManagementGroupSubscriptionIds -ManagementGroupId $targetMgId
        }
        elseif (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
            Write-Host "Validating subscription: $SubscriptionId"
            $subscriptionName = Get-OutputString (az account show --subscription $SubscriptionId --query name -o tsv 2>$null)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionName)) {
                throw "FAILED - Cannot access subscription: $SubscriptionId"
            }
            $subscriptionIds = @($SubscriptionId)
        }
        else {
            Write-VerboseLog "No subscription ID provided, checking available subscriptions..."

            $subscriptionRaw = Get-OutputString (az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o tsv 2>$null)
            $subscriptionLines = Split-NonEmptyLines $subscriptionRaw

            if ($subscriptionLines.Count -eq 0) {
                throw "FAILED - No subscriptions found"
            }

            Write-Host ""
            Write-Host "Multiple Azure Subscriptions Found"
            Write-Host "=================================="
            Write-Host ""
            Write-Host "Please run the script again with a specific subscription ID:"
            Write-Host ""

            $scriptInvocation = $MyInvocation.MyCommand.Name
            if ([string]::IsNullOrWhiteSpace($scriptInvocation)) {
                $scriptInvocation = "setup-app-registration.ps1"
            }

            foreach ($line in $subscriptionLines) {
                $parts = $line -split "`t"
                $name = $parts[0]
                $id = $parts[1]
                $isDefault = if ($parts.Count -gt 2) { $parts[2] } else { "false" }

                Write-Host "- $name"
                if ($isDefault -eq "true") {
                    Write-Host "  [CURRENT]"
                }

                $rerun = "pwsh ./$scriptInvocation -SubscriptionId `"$id`""
                if ($VerboseMode) {
                    $rerun += " -VerboseMode"
                }
                if ($ManagementGroupMode) {
                    $rerun += " -ManagementGroupMode"
                    if (-not [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
                        $rerun += " -ManagementGroupName `"$ManagementGroupName`""
                    }
                }

                Write-Host "  $rerun"
                Write-Host ""
            }

            return
        }
    }

    if ($subscriptionIds.Count -eq 0) {
        throw "FAILED - No subscriptions found to onboard"
    }

    Write-Host ""
    Write-Host "Configuration:"
    Write-Host "  App Name: (will be resolved after Service Principal creation)"
    if ($VerboseMode) {
        Write-Host "  Verbose Mode: ENABLED"
    }
    if ($ManagementGroupMode) {
        if (-not [string]::IsNullOrWhiteSpace($ManagementGroupName)) {
            Write-Host "  Scope: Management Group ($ManagementGroupName)"
        }
        else {
            Write-Host "  Scope: Management Group (root level)"
        }
    }
    else {
        Write-Host "  Scope: Current Subscription"
    }
    Write-Host ""

    if ($VerboseMode) {
        $currentSub = Get-OutputString (az account show --query name -o tsv 2>$null)
        $currentTenant = Get-OutputString (az account show --query tenantDisplayName -o tsv 2>$null)
        Write-Host "[VERBOSE] Subscription: $currentSub"
        Write-Host "[VERBOSE] Tenant: $currentTenant"
        Write-Host ""
    }

    $CurrentPrincipalType = (Get-OutputString (az account show --query user.type -o tsv 2>$null)).ToLowerInvariant()
    $currentPrincipalName = Get-OutputString (az account show --query user.name -o tsv 2>$null)

    $CurrentUserId = Get-CurrentPrincipalId -PrincipalType $CurrentPrincipalType -PrincipalName $currentPrincipalName

    if ([string]::IsNullOrWhiteSpace($CurrentUserId) -or $CurrentUserId -eq "null") {
        throw "FAILED - Could not determine signed-in principal object ID (user or service principal)"
    }

    $spId = ""
    Write-Host "Step 2/6: Creating Service Principal..."
    Write-VerboseLog "Checking for existing Service Principal first..."

    $existingSp = Get-OutputString (az ad sp list --filter "appId eq '$AppId'" --query "[0].id" -o tsv 2>$null)
    $spAlreadyExisted = -not [string]::IsNullOrWhiteSpace($existingSp)

    if (-not [string]::IsNullOrWhiteSpace($existingSp)) {
        Write-Host "Service Principal already exists: $existingSp"
        $spId = $existingSp
        Write-VerboseLog "Found existing Service Principal, reusing it"
    }
    else {
        Write-VerboseLog "Creating new Service Principal for App ID: $AppId"
        $spCreateStatus = 1

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-VerboseLog "Attempt $attempt to create Service Principal using az ad sp create..."

            if ($VerboseMode) {
                $createOutput = Get-OutputString (az ad sp create --id $AppId 2>&1)
                $spCreateStatus = $LASTEXITCODE
                Write-Host "[VERBOSE] Create output: $createOutput"
            }
            else {
                $createOutput = Get-OutputString (az ad sp create --id $AppId 2>$null)
                $spCreateStatus = $LASTEXITCODE
            }

            if ($createOutput -match "JSONDecodeError|Expecting value: line 1 column 1") {
                Write-VerboseLog "Detected Azure CLI JSON decoding error"
                $spCreateStatus = 1
                break
            }

            if ($spCreateStatus -eq 0) {
                $spId = Get-OutputString (az ad sp list --filter "appId eq '$AppId'" --query "[0].id" -o tsv 2>$null)
                if (-not [string]::IsNullOrWhiteSpace($spId)) {
                    break
                }
            }

            if ($attempt -lt 3) {
                Start-Sleep -Seconds 5
            }
        }

        if ($spCreateStatus -ne 0 -or [string]::IsNullOrWhiteSpace($spId)) {
            Write-VerboseLog "Service Principal creation failed, checking if it was created anyway..."
            $spId = Get-OutputString (az ad sp list --filter "appId eq '$AppId'" --query "[0].id" -o tsv 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($spId)) {
                $spCreateStatus = 0
                Write-VerboseLog "Service Principal found despite creation error - continuing"
            }
        }

        if ($spCreateStatus -ne 0 -or [string]::IsNullOrWhiteSpace($spId)) {
            throw "FAILED - Could not create Service Principal after trying multiple methods"
        }

        Write-Host "Service Principal created: $spId"
    }

    Write-VerboseLog "Service Principal will be used for RBAC assignments"

        $AppName = Get-OutputString (az ad sp show --id $spId --query displayName -o tsv 2>$null)
        if ([string]::IsNullOrWhiteSpace($AppName) -or $AppName -eq "null") {
            $AppName = $AppId
            Write-VerboseLog "Could not resolve Service Principal display name; using APP_ID as app name"
        }
        else {
            Write-VerboseLog "Resolved app name from Service Principal: $AppName"
        }

        if (-not $spAlreadyExisted) {
            Write-Host ""
            Write-Host "Waiting for Service Principal to be ready (15 seconds)..."
            Start-Sleep -Seconds 15
            Write-Host ""
        }

        Write-Host "Step 3/6: Assigning Microsoft Graph permissions to Service Principal..."

        $graphAppId = "00000003-0000-0000-c000-000000000000"
        $requiredAppPermissions = @(
            "Application.ReadWrite.All",
            "Directory.ReadWrite.All",
            "AppRoleAssignment.ReadWrite.All"
        )
        $requiredDelegatedPermissions = @("User.Read")

        $graphSpId = Get-OutputString (az ad sp show --id $graphAppId --query id -o tsv 2>$null)
        if ([string]::IsNullOrWhiteSpace($graphSpId) -or $graphSpId -eq "null") {
            Write-Host "WARNING - Could not retrieve Microsoft Graph Service Principal information"
        }
        else {
        $existingAssignmentsRaw = Get-OutputString (az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" --query "value[?resourceId=='$graphSpId'].appRoleId" -o tsv 2>$null)
        $existingAssignments = Split-NonEmptyLines $existingAssignmentsRaw

        $assignSuccess = 0
        foreach ($permissionName in $requiredAppPermissions) {
            $permissionId = Get-OutputString (az ad sp show --id $graphAppId --query "appRoles[?value=='$permissionName' && contains(allowedMemberTypes, 'Application')].id | [0]" -o tsv 2>$null)
            if ([string]::IsNullOrWhiteSpace($permissionId) -or $permissionId -eq "null") {
                Write-Host "WARNING - Could not find app role ID for: $permissionName"
                continue
            }

            if ($existingAssignments -contains $permissionId) {
                Write-Host "$permissionName app role already assigned"
                $assignSuccess++
                continue
            }

            $assignmentBody = @{ principalId = $spId; resourceId = $graphSpId; appRoleId = $permissionId } | ConvertTo-Json -Compress
            $assignOutput = Get-OutputString (az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" --headers "Content-Type=application/json" --body $assignmentBody 2>&1)
            $assignStatus = $LASTEXITCODE

            if ($VerboseMode) {
                Write-Host "[VERBOSE] $permissionName assignment output: $assignOutput"
            }

            if ($assignStatus -eq 0 -or $assignOutput -match "already exists|Conflict") {
                Write-Host "$permissionName app role assigned"
                $assignSuccess++
            }
            else {
                Write-Host "WARNING - Could not assign $permissionName app role"
            }
        }

        if ($assignSuccess -eq $requiredAppPermissions.Count) {
            Write-Host "All required Microsoft Graph app roles assigned to Service Principal ($assignSuccess/$($requiredAppPermissions.Count))"
        }
        elseif ($assignSuccess -gt 0) {
            Write-Host "Partial Microsoft Graph app role assignment ($assignSuccess/$($requiredAppPermissions.Count))"
        }
        else {
            Write-Host "WARNING - Could not assign Microsoft Graph app roles"
        }

        if ($requiredDelegatedPermissions.Count -gt 0) {
            $delegatedScopeString = ($requiredDelegatedPermissions -join " ")
            Write-VerboseLog "Requested delegated scopes: $delegatedScopeString"

            $existingGrantQueryUrl = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId%20eq%20'$spId'%20and%20resourceId%20eq%20'$graphSpId'%20and%20consentType%20eq%20'AllPrincipals'"
            $existingGrantRaw = Get-OutputString (az rest --method GET --url $existingGrantQueryUrl --query "value[].id" -o tsv 2>$null)
            $existingGrantIds = Split-NonEmptyLines $existingGrantRaw

            if ($existingGrantIds.Count -gt 0) {
                Write-Host "Removing existing delegated permission grants before recreate..."
                foreach ($grantId in $existingGrantIds) {
                    if ([string]::IsNullOrWhiteSpace($grantId)) {
                        continue
                    }
                    & az rest --method DELETE --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$grantId" 1>$null 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "WARNING - Could not remove existing delegated grant: $grantId"
                    }
                }
            }

            $grantBody = @{ clientId = $spId; consentType = "AllPrincipals"; resourceId = $graphSpId; scope = $delegatedScopeString } | ConvertTo-Json -Compress
            if ($VerboseMode) {
                Write-Host "[VERBOSE] Delegated grant URL: https://graph.microsoft.com/v1.0/oauth2PermissionGrants"
                Write-Host "[VERBOSE] Delegated grant body: $grantBody"
            }

            $grantOutput = Get-OutputString (az rest --method POST --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" --headers "Content-Type=application/json" --body $grantBody 2>&1)
            $grantStatus = $LASTEXITCODE

            if ($VerboseMode) {
                Write-Host "[VERBOSE] Delegated grant create output: $grantOutput"
            }

            if ($grantStatus -eq 0 -or $grantOutput -match "already exists|Conflict") {
                Write-Host "Delegated grant configured on service principal: $delegatedScopeString"
            }
            else {
                Write-Host "WARNING - Could not configure delegated grant on service principal"
            }
        }
    }
    Write-Host "Assigning Microsoft.Capacity RBAC roles (one-time per run)..."
    $capacityScope = "/providers/Microsoft.Capacity"

    $uaaOutput = Get-OutputString (az role assignment create --assignee $spId --role "User Access Administrator" --scope $capacityScope 2>&1)
    $uaaStatus = $LASTEXITCODE
    if ($VerboseMode) { Write-Host "[VERBOSE] User Access Administrator assignment output: $uaaOutput" }
    if ($uaaStatus -ne 0 -and $uaaOutput -notmatch "already exists|RoleAssignmentExists") {
        Write-Host "WARNING - Could not assign User Access Administrator on Microsoft.Capacity"
    }
    else {
        Write-Host "User Access Administrator assigned on Microsoft.Capacity"
    }

    $resOutput = Get-OutputString (az role assignment create --assignee $spId --role "Reservations Administrator" --scope $capacityScope 2>&1)
    $resStatus = $LASTEXITCODE
    if ($VerboseMode) { Write-Host "[VERBOSE] Reservations Administrator assignment output: $resOutput" }
    if ($resStatus -ne 0 -and $resOutput -notmatch "already exists|RoleAssignmentExists") {
        Write-Host "WARNING - Could not assign Reservations Administrator on Microsoft.Capacity"
    }
    else {
        Write-Host "Reservations Administrator assigned on Microsoft.Capacity"
    }

    Write-Host ""
    Write-Host "Step 5/6: Assigning Azure permissions per subscription..."

    $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168}))"

    foreach ($targetSubscriptionId in $subscriptionIds) {
        Write-Host ""
        Write-Host "Processing subscription: $targetSubscriptionId"

        if ($VerboseMode) {
            & az account set --subscription $targetSubscriptionId
        }
        else {
            & az account set --subscription $targetSubscriptionId 1>$null 2>$null
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING - Could not switch to subscription: $targetSubscriptionId"
            continue
        }

        $CurrentSubscriptionId = $targetSubscriptionId
        $needsSubPropagationWait = $false
        $tempContributorForSub = ""
        $tempUserAccessAdministratorForSub = ""

        $hasContributorAccess = Get-OutputString (az role assignment list --scope "/subscriptions/$CurrentSubscriptionId" --assignee $CurrentUserId --query "[?roleDefinitionName=='Contributor'].id | [0]" -o tsv 2>$null)
        $hasUserAccessAdministrator = Get-OutputString (az role assignment list --scope "/subscriptions/$CurrentSubscriptionId" --assignee $CurrentUserId --query "[?roleDefinitionName=='User Access Administrator'].id | [0]" -o tsv 2>$null)

        if ([string]::IsNullOrWhiteSpace($hasContributorAccess) -or $hasContributorAccess -eq "null") {
            Write-Host "No Contributor role found on subscription, assigning temporary Contributor..."

            $tempContributorOutput = Get-OutputString (az role assignment create --assignee $CurrentUserId --role "Contributor" --scope "/subscriptions/$CurrentSubscriptionId" --query id -o tsv 2>&1)
            $tempContributorStatus = $LASTEXITCODE

            if ($VerboseMode) {
                Write-Host "[VERBOSE] Contributor assignment output: $tempContributorOutput"
            }

            if ($tempContributorStatus -eq 0 -and -not [string]::IsNullOrWhiteSpace($tempContributorOutput)) {
                $tempContributorForSub = $tempContributorOutput
                $TempContributorAssignmentIds += $tempContributorForSub
                $needsSubPropagationWait = $true
                Write-Host "Temporary Contributor role assigned"
            }
            elseif ($tempContributorOutput -match "RoleAssignmentExists|already exists") {
                Write-Host "Contributor role already present"
            }
            else {
                Write-Host "WARNING - Could not assign temporary Contributor role"
            }
        }
        else {
            Write-Host "Contributor access already available on subscription"
        }

        if ([string]::IsNullOrWhiteSpace($hasUserAccessAdministrator) -or $hasUserAccessAdministrator -eq "null") {
            Write-Host "No User Access Administrator role found on subscription, assigning temporary User Access Administrator..."

            $tempUserAccessAdministratorOutput = Get-OutputString (az role assignment create --assignee $CurrentUserId --role "User Access Administrator" --scope "/subscriptions/$CurrentSubscriptionId" --query id -o tsv 2>&1)
            $tempUserAccessAdministratorStatus = $LASTEXITCODE

            if ($VerboseMode) {
                Write-Host "[VERBOSE] User Access Administrator assignment output: $tempUserAccessAdministratorOutput"
            }

            if ($tempUserAccessAdministratorStatus -eq 0 -and -not [string]::IsNullOrWhiteSpace($tempUserAccessAdministratorOutput)) {
                $tempUserAccessAdministratorForSub = $tempUserAccessAdministratorOutput
                $TempUserAccessAdministratorAssignmentIds += $tempUserAccessAdministratorForSub
                $needsSubPropagationWait = $true
                Write-Host "Temporary User Access Administrator role assigned"
            }
            elseif ($tempUserAccessAdministratorOutput -match "RoleAssignmentExists|already exists") {
                Write-Host "User Access Administrator role already present"
            }
            else {
                Write-Host "WARNING - Could not assign temporary User Access Administrator role"
            }
        }
        else {
            Write-Host "User Access Administrator access already available on subscription"
        }

        if ($needsSubPropagationWait) {
            Write-Host "Waiting for RBAC propagation (15 seconds)..."
            Start-Sleep -Seconds 15
        }

        Register-RequiredProviders

        if ($ManagementGroupMode -and -not [string]::IsNullOrWhiteSpace($targetMgId) -and $targetMgId -ne "null") {
            $ownerScope = "/providers/Microsoft.Management/managementGroups/$targetMgId"
            $scopeName = "Management Group ($targetMgId)"
        }
        else {
            $ownerScope = "/subscriptions/$CurrentSubscriptionId"
            $scopeName = "Subscription ($CurrentSubscriptionId)"
        }

        $ownerStatus = 1
        $ownerOutput = ""
        $ownerAssigned = $false

        for ($ownerAttempt = 1; $ownerAttempt -le 4; $ownerAttempt++) {
            $ownerOutput = Get-OutputString (az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal --role "Owner" --scope $ownerScope --condition $condition --condition-version "2.0" 2>&1)
            $ownerStatus = $LASTEXITCODE

            if ($VerboseMode) { Write-Host "[VERBOSE] Owner role assignment output (attempt ${ownerAttempt}/4): $ownerOutput" }

            if ($ownerStatus -eq 0 -or $ownerOutput -match "already exists|RoleAssignmentExists") {
                $ownerAssigned = $true
                break
            }

            if ($ownerAttempt -lt 4) {
                Write-Host "Owner role assignment failed on attempt $ownerAttempt/4. Retrying in 20 seconds..."
                Start-Sleep -Seconds 20
            }
        }

        if (-not $ownerAssigned) {
            Write-Host "WARNING - Could not assign Owner role on $scopeName after 4 attempts"
        }
        else {
            Write-Host "Owner role assigned on $scopeName for Service Principal ($AppName)"
        }

        if (-not [string]::IsNullOrWhiteSpace($tempUserAccessAdministratorForSub)) {
            & az role assignment delete --ids $tempUserAccessAdministratorForSub 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Temporary User Access Administrator access removed for subscription: $CurrentSubscriptionId"
                $TempUserAccessAdministratorAssignmentIds = @($TempUserAccessAdministratorAssignmentIds | Where-Object { $_ -ne $tempUserAccessAdministratorForSub })
            }
            else {
                Write-Host "WARNING - Could not remove temporary User Access Administrator access for subscription: $CurrentSubscriptionId"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($tempContributorForSub)) {
            & az role assignment delete --ids $tempContributorForSub 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Temporary Contributor access removed for subscription: $CurrentSubscriptionId"
                $TempContributorAssignmentIds = @($TempContributorAssignmentIds | Where-Object { $_ -ne $tempContributorForSub })
            }
            else {
                Write-Host "WARNING - Could not remove temporary Contributor access for subscription: $CurrentSubscriptionId"
            }
        }

        $OnboardedSubscriptions += $CurrentSubscriptionId
    }

    if ($TempContributorAssignmentIds.Count -gt 0 -or $TempUserAccessAdministratorAssignmentIds.Count -gt 0) {
        Write-Host ""
        Write-Host "Step 6/6: Removing temporary access..."
        Invoke-Cleanup -Source "step6"
        Write-Host ""
    }

    Write-Host "SETUP COMPLETED SUCCESSFULLY!"
    Write-Host "============================="
    Write-Host ""
    Write-Host "Details to add to database"
    Write-Host "  AZURE_TENANT_ID=$tenantId"
    Write-Host "  ONBOARDED_SUBSCRIPTIONS=$($OnboardedSubscriptions -join ',')"
    Write-Host ""
    Write-Host "Ready for registration in database"

    $result = @{
        tenantId = $tenantId
        onboardedSubscriptions = $OnboardedSubscriptions
    }

    Write-Host ""
    Write-Host "Onboarding result JSON:"
    $result | ConvertTo-Json -Depth 5
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    Invoke-Cleanup -Source "finally"
}
