#!/bin/bash

# Application details
appid="81ee680a-2a71-45df-be9d-332b720b9785"

# Parse command line arguments
VERBOSE=false
if [[ "$1" == "-v" ]] || [[ "$1" == "--verbose" ]]; then
    VERBOSE=true
fi

# Logging functions
log() {
    if [ "$VERBOSE" = true ]; then
        echo "$1"
    fi
}

log_always() {
    echo "$1"
}

# Get tenant and user info
tenantid=$(az account show --query "homeTenantId" --output tsv)
userid=$(az ad signed-in-user show --query id --output tsv)

log_always "Starting MSP onboarding for tenant $tenantid..."

# Step 1: Register application
log "Checking if application is registered..."
spexists=$(az ad sp show --id "$appid" --query "id" --output tsv 2>/dev/null)

if [ -z "$spexists" ]; then
    log "Registering application..."
    spid=$(az ad sp create --id "$appid" --query "id" --output tsv 2>&1)
    log "Application registered."
else
    log "Application already registered."
    spid=$(az ad sp show --id "$appid" --query "id" --output tsv)
fi

# Step 2: Admin consent
log "Processing admin consent..."
graphsp=$(az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query "[0].id" --output tsv 2>/dev/null)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spid/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$spid\",\"resourceId\":\"$graphsp\",\"appRoleId\":\"df021288-bdef-4463-88db-98f22de89214\"}" \
  > /dev/null 2>&1 && log "Graph permissions granted." || log "Graph permissions may require manual consent."

# Step 3: Check/elevate access
log "Checking elevated access..."
elevated_by_script=false
has_elevated_access=$(az role assignment list --scope "/" --assignee "$userid" --query "[?roleDefinitionName=='User Access Administrator' || roleDefinitionName=='Owner'].roleDefinitionName" --output tsv 2>/dev/null)

if [ -z "$has_elevated_access" ]; then
    log "Elevating access..."
    if az rest --method post --url "/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01" > /dev/null 2>&1; then
        elevated_by_script=true
        sleep 15
        has_elevated_access=$(az role assignment list --scope "/" --assignee "$userid" --query "[?roleDefinitionName=='User Access Administrator' || roleDefinitionName=='Owner'].roleDefinitionName" --output tsv 2>/dev/null)
        if [ -z "$has_elevated_access" ]; then
            log_always "ERROR: Failed to elevate access."
            exit 1
        fi
        log "Elevated access granted."
    else
        log_always "ERROR: Cannot elevate access. Must be Global Administrator."
        exit 1
    fi
else
    log "Elevated access confirmed."
fi

# Step 4: Assign roles
log "Assigning roles..."
rootmg=$(az account management-group list --query "[?displayName=='Tenant Root Group'].name | [0]" --output tsv 2>/dev/null)

# ABAC condition to prevent privileged role assignments
condition='((!(ActionMatches{'\''Microsoft.Authorization/roleAssignments/write'\''})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, 8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168})) AND ((!(ActionMatches{'\''Microsoft.Authorization/roleAssignments/delete'\''})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, 8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168}))'

# Owner on root MG with condition
az role assignment create \
  --assignee "$appid" \
  --role Owner \
  --scope "/providers/Microsoft.Management/managementGroups/$rootmg" \
  --condition "$condition" \
  --condition-version "2.0" > /dev/null 2>&1
log "Owner role assigned on root management group."

# User Access Administrator on Capacity
az role assignment create \
  --assignee "$appid" \
  --role "User Access Administrator" \
  --scope "/providers/Microsoft.Capacity" > /dev/null 2>&1
log "User Access Administrator assigned on Microsoft.Capacity."

# Reservations Administrator on Capacity
az role assignment create \
  --assignee "$appid" \
  --role "Reservations Administrator" \
  --scope "/providers/Microsoft.Capacity" > /dev/null 2>&1
log "Reservations Administrator assigned on Microsoft.Capacity."

# Step 5: Clean up elevated access
if [ "$elevated_by_script" = true ]; then
    log "Removing elevated access..."
    roleassignmentid=$(az role assignment list --scope "/" --assignee "$userid" --query "[?roleDefinitionName=='User Access Administrator'].id" --output tsv 2>/dev/null)
    if [ ! -z "$roleassignmentid" ]; then
        az role assignment delete --ids "$roleassignmentid" > /dev/null 2>&1
        log "Elevated access removed."
    fi
fi

# Step 6: Verify and display results
log_always ""
log_always "=========================================="
log_always "ONBOARDING SUMMARY"
log_always "=========================================="
log_always ""
log_always "Application ID: $appid"
log_always "Service Principal ID: $spid"
log_always "Tenant ID: $tenantid"
log_always "Root Management Group: $rootmg"
log_always ""

# Verify role assignments
log_always "Verifying role assignments:"
log_always ""

# Check Owner on root MG
owner_check=$(az role assignment list --assignee "$appid" --scope "/providers/Microsoft.Management/managementGroups/$rootmg" --query "[?roleDefinitionName=='Owner'].id" --output tsv 2>/dev/null)
if [ ! -z "$owner_check" ]; then
    log_always "✓ Owner on Root Management Group: ASSIGNED"
    # Check if condition exists
    condition_check=$(az role assignment list --assignee "$appid" --scope "/providers/Microsoft.Management/managementGroups/$rootmg" --query "[?roleDefinitionName=='Owner'].condition" --output tsv 2>/dev/null)
    if [ ! -z "$condition_check" ]; then
        log_always "  └─ ABAC Condition: ACTIVE"
    else
        log_always "  └─ ABAC Condition: MISSING"
    fi
else
    log_always "✗ Owner on Root Management Group: NOT FOUND"
fi

# Check User Access Administrator on Capacity
uaa_check=$(az role assignment list --assignee "$appid" --scope "/providers/Microsoft.Capacity" --query "[?roleDefinitionName=='User Access Administrator'].id" --output tsv 2>/dev/null)
if [ ! -z "$uaa_check" ]; then
    log_always "✓ User Access Administrator on Microsoft.Capacity: ASSIGNED"
else
    log_always "✗ User Access Administrator on Microsoft.Capacity: NOT FOUND"
fi

# Check Reservations Administrator on Capacity
res_check=$(az role assignment list --assignee "$appid" --scope "/providers/Microsoft.Capacity" --query "[?roleDefinitionName=='Reservations Administrator'].id" --output tsv 2>/dev/null)
if [ ! -z "$res_check" ]; then
    log_always "✓ Reservations Administrator on Microsoft.Capacity: ASSIGNED"
else
    log_always "✗ Reservations Administrator on Microsoft.Capacity: NOT FOUND"
fi

log_always ""
log_always "⚠  MANUAL ACTION REQUIRED:"
log_always "   Grant admin consent by visiting:"
log_always "   https://login.microsoftonline.com/$tenantid/adminconsent?client_id=$appid"
log_always ""
log_always "=========================================="
