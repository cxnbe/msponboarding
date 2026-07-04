#!/bin/bash
# GitHub Actions Azure OIDC Complete Setup
# Usage: curl -s https://raw.githubusercontent.com/CXNSMB/onboarding/main/setup-app-registration.sh | bash -s -- "subscription-id" [verbose|management-group] [management-group-name]
# For dev version: curl -s https://raw.githubusercontent.com/CXNSMB/onboarding/dev/setup-app-registration.sh | bash -s -- "subscription-id" [verbose|management-group] [management-group-name]

# Check for verbose mode and management group mode
VERBOSE=""
MANAGEMENT_GROUP_MODE=""
MANAGEMENT_GROUP_NAME=""
APP_ID="03130519-c919-4db6-b784-49672aeadbdb" #cxn dev
# Process optional parameters from argument 2 onward
for param in "${@:2}"; do
    if [[ "$param" == "verbose" || "$param" == "-v" || "$param" == "--verbose" ]]; then
        VERBOSE="true"
    elif [[ "$param" == "management-group" || "$param" == "mg" || "$param" == "--management-group" ]]; then
        MANAGEMENT_GROUP_MODE="true"
    elif [[ "$MANAGEMENT_GROUP_MODE" == "true" && ! -z "$param" && "$param" != "verbose" && "$param" != "-v" && "$param" != "--verbose" ]]; then
        # This is a management group name
        MANAGEMENT_GROUP_NAME="$param"
    fi
done

# Verbose logging function
log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "🔍 [VERBOSE] $1"
    fi
}

echo "🚀 GitHub Actions Azure OIDC Complete Setup"
echo "=============================================="

# Quick Azure CLI connectivity check
echo "🔍 Checking Azure CLI connectivity..."
if ! az account show >/dev/null 2>&1; then
    echo "❌ FAILED - Not logged into Azure CLI"
    echo "Please run: az login"
    exit 1
fi

# Get tenant ID for later outputs/secrets
TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null)
if [ -z "$TENANT_ID" ]; then
    echo "❌ FAILED - Could not retrieve tenant ID"
    exit 1
fi

# Parameters
SUBSCRIPTION_ID="${1}"

# App name is resolved after service principal creation
APP_NAME=""

# Check subscription logic
if [[ ! -z "$SUBSCRIPTION_ID" ]]; then
    # Subscription ID provided, validate and use it
    echo "🔄 Setting subscription to: $SUBSCRIPTION_ID"
    log_verbose "Switching to subscription: $SUBSCRIPTION_ID"
    
    # Verify subscription exists and user has access
    SUBSCRIPTION_NAME=$(az account show --subscription "$SUBSCRIPTION_ID" --query name -o tsv 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$SUBSCRIPTION_NAME" ]; then
        echo "❌ FAILED - Cannot access subscription: $SUBSCRIPTION_ID"
        echo "Please check if:"
        echo "   1. The subscription ID is correct"
        echo "   2. You have access to this subscription"
        echo "   3. The subscription is active"
        exit 1
    fi
    
    # Set the subscription
    if [[ "$VERBOSE" == "true" ]]; then
        az account set --subscription "$SUBSCRIPTION_ID"
        SET_STATUS=$?
    else
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1
        SET_STATUS=$?
    fi
    
    if [ $SET_STATUS -ne 0 ]; then
        echo "❌ FAILED - Could not switch to subscription: $SUBSCRIPTION_ID"
        echo "Please check your permissions for this subscription"
        exit 1
    fi
    
    echo "✅ Successfully switched to subscription: $SUBSCRIPTION_NAME"
    log_verbose "Active subscription is now: $SUBSCRIPTION_NAME (ID: $SUBSCRIPTION_ID)"
else
    # No subscription ID provided, check available subscriptions
    log_verbose "No subscription ID provided, checking available subscriptions..."
    
    # Get list of subscriptions
    mapfile -t SUBSCRIPTIONS < <(az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o tsv)
    
    if [ ${#SUBSCRIPTIONS[@]} -eq 0 ]; then
        echo "❌ FAILED - No subscriptions found"
        echo "Please check your Azure access permissions"
        exit 1
    elif [ ${#SUBSCRIPTIONS[@]} -eq 1 ]; then
        # Only one subscription, use it automatically
        IFS=$'\t' read -r name id isDefault <<< "${SUBSCRIPTIONS[0]}"
        echo "📝 Only one subscription found, using: $name"
        log_verbose "Automatically using single subscription: $name (ID: $id)"
        
        if [[ "$isDefault" != "true" ]]; then
            # Set as active if not already active
            if [[ "$VERBOSE" == "true" ]]; then
                az account set --subscription "$id"
                SET_STATUS=$?
            else
                az account set --subscription "$id" >/dev/null 2>&1
                SET_STATUS=$?
            fi
            
            if [ $SET_STATUS -ne 0 ]; then
                echo "❌ FAILED - Could not switch to subscription: $name"
                echo "Please check your permissions for this subscription"
                exit 1
            fi
            
            echo "✅ Successfully switched to subscription: $name"
            log_verbose "Active subscription is now: $name (ID: $id)"
        else
            echo "✅ Using current subscription: $name"
            log_verbose "Subscription was already active: $name (ID: $id)"
        fi
    else
        # Multiple subscriptions found, show options with curl syntax
        echo ""
        echo "📋 Multiple Azure Subscriptions Found"
        echo "======================================"
        echo ""
        echo "Please run the script again with a specific subscription ID:"
        echo ""
        
        # Build rerun command from current script invocation when available
        SCRIPT_INVOCATION="$0"
        if [[ -n "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "/dev/stdin" && "${BASH_SOURCE[0]}" != /dev/fd/* ]]; then
            SCRIPT_INVOCATION="${BASH_SOURCE[0]}"
        fi
        if [[ "$SCRIPT_INVOCATION" == "bash" || "$SCRIPT_INVOCATION" == "-bash" || "$SCRIPT_INVOCATION" == "-" ]]; then
            SCRIPT_INVOCATION="setup-app-registration.sh"
        fi
        
        # Generate curl command for each subscription
        for i in "${!SUBSCRIPTIONS[@]}"; do
            IFS=$'\t' read -r name id isDefault <<< "${SUBSCRIPTIONS[i]}"
            echo "🔹 $name"
            if [[ "$isDefault" == "true" ]]; then
                echo "   [CURRENT]"
            fi
            
            # Build rerun command with subscription ID as first parameter
            CURL_CMD="bash \"$SCRIPT_INVOCATION\" \"$id\""
            
            # Add verbose if it was specified
            if [[ "$VERBOSE" == "true" ]]; then
                CURL_CMD="$CURL_CMD \"verbose\""
            fi
            
            # Add management group options if specified
            if [[ "$MANAGEMENT_GROUP_MODE" == "true" ]]; then
                CURL_CMD="$CURL_CMD \"management-group\""
                if [[ ! -z "$MANAGEMENT_GROUP_NAME" ]]; then
                    CURL_CMD="$CURL_CMD \"$MANAGEMENT_GROUP_NAME\""
                fi
            fi
            
            echo "   $CURL_CMD"
            echo ""
        done
        
        echo "💡 Tip: Copy and paste one of the commands above to run with your desired subscription."
        echo ""
        exit 0
    fi
fi
echo ""

echo "📋 Configuration:"
echo "   App Name: (will be resolved after Service Principal creation)"
if [[ "$VERBOSE" == "true" ]]; then
    echo "   Verbose Mode: ENABLED"
fi
if [[ "$MANAGEMENT_GROUP_MODE" == "true" ]]; then
    if [[ ! -z "$MANAGEMENT_GROUP_NAME" ]]; then
        echo "   Scope: Management Group ($MANAGEMENT_GROUP_NAME)"
    else
        echo "   Scope: Management Group (root level)"
    fi
else
    echo "   Scope: Current Subscription"
fi
echo ""

log_verbose "Current Azure context:"
if [[ "$VERBOSE" == "true" ]]; then
    CURRENT_SUB=$(az account show --query name -o tsv 2>/dev/null)
    CURRENT_TENANT=$(az account show --query tenantDisplayName -o tsv 2>/dev/null)
    echo "🔍 [VERBOSE]   Subscription: $CURRENT_SUB"
    echo "🔍 [VERBOSE]   Tenant: $CURRENT_TENANT"
    echo ""
fi

# Register required Azure Resource Providers
register_required_providers() {
    echo "📌 Registering Azure Resource Providers..."
    log_verbose "Registering required resource providers for Azure services"

    PROVIDERS=(
        "Microsoft.Batch"
        "Microsoft.Compute"
        "Microsoft.Capacity"
        "Microsoft.ManagedIdentity"
        "Microsoft.ManagedServices"
    )

    for provider in "${PROVIDERS[@]}"; do
        log_verbose "Registering provider: $provider"
        PROVIDER_OUTPUT=$(az provider register --namespace "$provider" 2>&1)
        PROVIDER_STATUS=$?
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$PROVIDER_OUTPUT"
        fi

        if [ $PROVIDER_STATUS -eq 0 ]; then
            echo "✅ Registered: $provider"
        else
            echo "⚠️  WARNING - Could not register provider: $provider"
            log_verbose "Provider registration failed for $provider: $PROVIDER_OUTPUT"
        fi
    done
    echo ""
}


# Step 2: Service Principal
echo "🔄 Step 2/4: Creating Service Principal..."
log_verbose "Checking for existing Service Principal first..."

# Check if Service Principal already exists using different approach
EXISTING_SP=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>/dev/null)
if [ ! -z "$EXISTING_SP" ]; then
    echo "✅ Service Principal already exists: $EXISTING_SP"
    SP_ID="$EXISTING_SP"
    log_verbose "Found existing Service Principal, reusing it"
else
    log_verbose "Creating new Service Principal for App ID: $APP_ID"
    # Try multiple approaches due to Azure CLI bugs
    SP_CREATE_STATUS=1
    
    # Method 1: Try az ad sp create (may fail with JSON decode error)
    for attempt in {1..3}; do
        log_verbose "Attempt $attempt to create Service Principal using az ad sp create..."
        
        if [[ "$VERBOSE" == "true" ]]; then
            CREATE_OUTPUT=$(az ad sp create --id $APP_ID 2>&1)
            SP_CREATE_STATUS=$?
            echo "🔍 [VERBOSE] Create output: $CREATE_OUTPUT"
        else
            CREATE_OUTPUT=$(az ad sp create --id $APP_ID 2>/dev/null)
            SP_CREATE_STATUS=$?
        fi
        
        # Check for the specific JSON decoding error and treat it as transient
        if [[ "$CREATE_OUTPUT" == *"JSONDecodeError"* ]] || [[ "$CREATE_OUTPUT" == *"Expecting value: line 1 column 1"* ]]; then
            log_verbose "Detected Azure CLI JSON decoding error - will try REST API method"
            SP_CREATE_STATUS=1
            break  # Skip retries and go to REST API method
        fi
        
        if [ $SP_CREATE_STATUS -eq 0 ]; then
            # Get the SP ID after successful creation
            SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>/dev/null)
            if [ ! -z "$SP_ID" ]; then
                break
            fi
        fi
        
        if [ $attempt -lt 3 ]; then
            log_verbose "Service Principal creation failed, waiting 5 seconds before retry..."
            sleep 5
        fi
    done
    
    # Final fallback: check if Service Principal was created despite any errors
    if [ $SP_CREATE_STATUS -ne 0 ] || [ -z "$SP_ID" ]; then
        log_verbose "Service Principal creation failed, checking if it was created anyway..."
        SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv 2>/dev/null)
        if [ ! -z "$SP_ID" ]; then
            log_verbose "Service Principal found despite creation error - continuing"
            SP_CREATE_STATUS=0
        fi
    fi

    if [ $SP_CREATE_STATUS -ne 0 ] || [ -z "$SP_ID" ]; then
        echo "❌ FAILED - Could not create Service Principal after trying multiple methods"
        log_verbose "Error details: Azure AD propagation issue, Azure CLI bug, or permissions problem"
        log_verbose "Common solutions:"
        log_verbose "  1. Try running the script again after a few minutes"
        log_verbose "  2. Update Azure CLI: az upgrade"
        log_verbose "  3. Clear Azure CLI cache: az cache purge"
        log_verbose "  4. Create Service Principal manually: az ad sp create --id $APP_ID"
        log_verbose "  5. Check if you have permission to create Service Principals"
        exit 1
    fi
    echo "✅ Service Principal created: $SP_ID"
fi
log_verbose "Service Principal will be used for RBAC assignments"

# Resolve display name only after service principal exists
APP_NAME=$(az ad sp show --id "$SP_ID" --query "displayName" -o tsv 2>/dev/null)
if [ -z "$APP_NAME" ] || [ "$APP_NAME" == "null" ]; then
    APP_NAME="$APP_ID"
    log_verbose "Could not resolve Service Principal display name; using APP_ID as app name"
else
    log_verbose "Resolved app name from Service Principal: $APP_NAME"
fi

echo ""

# Wait for Service Principal to be ready
echo "⏳ Waiting for Service Principal to be ready (5 seconds)..."
log_verbose "Service Principal needs time to become available for role assignments"
if [[ "$VERBOSE" == "true" ]]; then
    for i in {5..1}; do
        echo "🔍 [VERBOSE] Waiting... $i seconds remaining"
        sleep 1
    done
else
    sleep 5
fi
log_verbose "Service Principal readiness wait completed"
echo ""

# Step 3: Microsoft Graph App Role Assignments on Service Principal
echo "🔑 Step 3/5: Assigning Microsoft Graph App Roles to Service Principal..."
log_verbose "Assigning Microsoft Graph application roles directly to Service Principal"

# Well-known Microsoft Graph App ID
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
log_verbose "Microsoft Graph App ID: $GRAPH_APP_ID"

# Define required Microsoft Graph application permissions by name
REQUIRED_APP_PERMISSIONS=(
    "Application.ReadWrite.All"
    "Directory.ReadWrite.All"
    "AppRoleAssignment.ReadWrite.All"
)

# Define required Microsoft Graph delegated permissions by name
REQUIRED_DELEGATED_PERMISSIONS=(
    "User.Read"
)

echo "📝 Checking Microsoft Graph app role assignments on Service Principal..."
log_verbose "Looking up application app role IDs for: ${REQUIRED_APP_PERMISSIONS[*]}"
log_verbose "Configuring delegated scopes for: ${REQUIRED_DELEGATED_PERMISSIONS[*]}"

# Get Microsoft Graph Service Principal ID
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query "id" -o tsv 2>/dev/null)
if [ -z "$GRAPH_SP_ID" ] || [ "$GRAPH_SP_ID" == "null" ]; then
    echo "⚠️  WARNING - Could not retrieve Microsoft Graph Service Principal information"
    echo "   📝 Please verify Microsoft Graph Service Principal exists in this tenant"
else
    log_verbose "Microsoft Graph Service Principal ID: $GRAPH_SP_ID"
    log_verbose "Cross-tenant mode: all Microsoft Graph permissions are handled through the local service principal"

    # Read existing assignments from client Service Principal to Microsoft Graph
    EXISTING_ASSIGNMENTS=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
        --query "value[?resourceId=='$GRAPH_SP_ID'].appRoleId" -o tsv 2>/dev/null)
    log_verbose "Existing app role assignments: $(echo $EXISTING_ASSIGNMENTS | tr '\n' ' ')"

    ASSIGN_SUCCESS_COUNT=0
    TOTAL_APP_PERMISSIONS=${#REQUIRED_APP_PERMISSIONS[@]}

    for PERMISSION_NAME in "${REQUIRED_APP_PERMISSIONS[@]}"; do
        log_verbose "Looking up app role ID for: $PERMISSION_NAME"

        # Only application roles are valid for service principal assignment
        PERMISSION_ID=$(az ad sp show --id "$GRAPH_APP_ID" \
            --query "appRoles[?value=='$PERMISSION_NAME' && contains(allowedMemberTypes, 'Application')].id | [0]" \
            -o tsv 2>/dev/null)

        if [ -z "$PERMISSION_ID" ] || [ "$PERMISSION_ID" == "null" ]; then
            echo "⚠️  WARNING - Could not find app role ID for: $PERMISSION_NAME"
            log_verbose "App role $PERMISSION_NAME not found in Microsoft Graph app roles"
            continue
        fi

        log_verbose "Found app role ID for $PERMISSION_NAME: $PERMISSION_ID"

        if echo "$EXISTING_ASSIGNMENTS" | grep -q "$PERMISSION_ID"; then
            echo "✅ $PERMISSION_NAME app role already assigned"
            log_verbose "$PERMISSION_NAME already assigned to Service Principal"
            ((ASSIGN_SUCCESS_COUNT++))
            continue
        fi

        ASSIGNMENT_BODY=$(printf '{"principalId":"%s","resourceId":"%s","appRoleId":"%s"}' "$SP_ID" "$GRAPH_SP_ID" "$PERMISSION_ID")
        log_verbose "Creating app role assignment for $PERMISSION_NAME"

        if [[ "$VERBOSE" == "true" ]]; then
            echo "🔍 [VERBOSE] Executing app role assignment for $PERMISSION_NAME"
            ASSIGN_OUTPUT=$(az rest --method POST \
                --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
                --headers "Content-Type=application/json" \
                --body "$ASSIGNMENT_BODY" 2>&1)
            ASSIGN_STATUS=$?
            echo "🔍 [VERBOSE] $PERMISSION_NAME assignment output: $ASSIGN_OUTPUT"
        else
            ASSIGN_OUTPUT=$(az rest --method POST \
                --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
                --headers "Content-Type=application/json" \
                --body "$ASSIGNMENT_BODY" 2>/dev/null)
            ASSIGN_STATUS=$?
        fi

        if [ $ASSIGN_STATUS -eq 0 ]; then
            echo "✅ $PERMISSION_NAME app role assigned"
            log_verbose "$PERMISSION_NAME successfully assigned to Service Principal"
            ((ASSIGN_SUCCESS_COUNT++))
        elif [[ "$ASSIGN_OUTPUT" == *"already exists"* ]] || [[ "$ASSIGN_OUTPUT" == *"Conflict"* ]]; then
            echo "✅ $PERMISSION_NAME app role already assigned"
            log_verbose "$PERMISSION_NAME assignment already existed"
            ((ASSIGN_SUCCESS_COUNT++))
        else
            echo "⚠️  WARNING - Could not assign $PERMISSION_NAME app role"
            log_verbose "$PERMISSION_NAME assignment failed: $ASSIGN_OUTPUT"
        fi
    done

    if [ $ASSIGN_SUCCESS_COUNT -eq $TOTAL_APP_PERMISSIONS ]; then
        echo "✅ All required Microsoft Graph app roles assigned to Service Principal ($ASSIGN_SUCCESS_COUNT/$TOTAL_APP_PERMISSIONS)"
        log_verbose "Service Principal is fully configured without separate admin consent step"
    elif [ $ASSIGN_SUCCESS_COUNT -gt 0 ]; then
        echo "⚠️  Partial Microsoft Graph app role assignment ($ASSIGN_SUCCESS_COUNT/$TOTAL_APP_PERMISSIONS)"
        echo "   📝 Please validate directory role permissions and retry"
    else
        echo "⚠️  WARNING - Could not assign Microsoft Graph app roles"
        echo "   📝 Please verify your permissions to create app role assignments in Microsoft Graph"
    fi

    echo "📝 Checking Microsoft Graph delegated permission grants on the Service Principal..."
    TOTAL_DELEGATED_PERMISSIONS=${#REQUIRED_DELEGATED_PERMISSIONS[@]}

    if [ $TOTAL_DELEGATED_PERMISSIONS -gt 0 ]; then
        DELEGATED_SCOPE_STRING=$(printf '%s ' "${REQUIRED_DELEGATED_PERMISSIONS[@]}")
        DELEGATED_SCOPE_STRING=${DELEGATED_SCOPE_STRING% }
        log_verbose "Requested delegated scopes: $DELEGATED_SCOPE_STRING"

        echo "ℹ️  Delegated permissions in cross-tenant mode are stored as oauth2PermissionGrants on the local service principal"

        EXISTING_GRANT_QUERY_URL="https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId%20eq%20'$SP_ID'%20and%20resourceId%20eq%20'$GRAPH_SP_ID'%20and%20consentType%20eq%20'AllPrincipals'"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "🔍 [VERBOSE] Existing delegated grant query URL: $EXISTING_GRANT_QUERY_URL"
        fi

        mapfile -t EXISTING_GRANT_IDS < <(az rest --method GET \
            --url "$EXISTING_GRANT_QUERY_URL" \
            --query "value[].id" -o tsv 2>/dev/null)

        if [ ${#EXISTING_GRANT_IDS[@]} -gt 0 ]; then
            echo "🧹 Removing existing delegated permission grants before recreate..."
            for GRANT_ID in "${EXISTING_GRANT_IDS[@]}"; do
                [ -z "$GRANT_ID" ] && continue
                DELETE_GRANT_URL="https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$GRANT_ID"
                if [[ "$VERBOSE" == "true" ]]; then
                    echo "🔍 [VERBOSE] Deleting delegated grant URL: $DELETE_GRANT_URL"
                fi

                if az rest --method DELETE --url "$DELETE_GRANT_URL" >/dev/null 2>&1; then
                    log_verbose "Deleted existing delegated grant: $GRANT_ID"
                else
                    echo "⚠️  WARNING - Could not remove existing delegated grant: $GRANT_ID"
                    echo "   📝 The delegated grant recreate may fail if this grant still exists"
                fi
            done
        fi

        GRANT_URL="https://graph.microsoft.com/v1.0/oauth2PermissionGrants"
        GRANT_BODY=$(printf '{"clientId":"%s","consentType":"AllPrincipals","resourceId":"%s","scope":"%s"}' "$SP_ID" "$GRAPH_SP_ID" "$DELEGATED_SCOPE_STRING")

        if [[ "$VERBOSE" == "true" ]]; then
            echo "🔍 [VERBOSE] Delegated grant URL: $GRANT_URL"
            echo "🔍 [VERBOSE] Delegated grant body: $GRANT_BODY"
            GRANT_OUTPUT=$(az rest --method POST \
                --url "$GRANT_URL" \
                --headers "Content-Type=application/json" \
                --body "$GRANT_BODY" 2>&1)
            GRANT_STATUS=$?
            echo "🔍 [VERBOSE] Delegated grant create output: $GRANT_OUTPUT"
        else
            GRANT_OUTPUT=$(az rest --method POST \
                --url "$GRANT_URL" \
                --headers "Content-Type=application/json" \
                --body "$GRANT_BODY" 2>/dev/null)
            GRANT_STATUS=$?
        fi

        if [ $GRANT_STATUS -eq 0 ]; then
            echo "✅ Delegated grant configured on service principal: $DELEGATED_SCOPE_STRING"
        elif [[ "$GRANT_OUTPUT" == *"already exists"* ]] || [[ "$GRANT_OUTPUT" == *"Conflict"* ]]; then
            echo "✅ Delegated grant already present on service principal"
        else
            echo "⚠️  WARNING - Could not configure delegated grant on service principal"
            log_verbose "Delegated permission grant failed: $GRANT_OUTPUT"
        fi
    fi
fi

log_verbose "Azure AD directory permissions assignment completed"
echo ""


# Step 4: Check/elevate access
echo "🔐 Step 4/6: Checking elevated access..."
USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null)
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
if [ -z "$USER_ID" ] || [ "$USER_ID" == "null" ]; then
    echo "❌ FAILED - Could not determine signed-in user"
    echo "   Ensure you are logged in with a user account (not only service principal)"
    exit 1
fi
if [ -z "$SUBSCRIPTION_ID" ] || [ "$SUBSCRIPTION_ID" == "null" ]; then
    echo "❌ FAILED - Could not determine active subscription"
    exit 1
fi

ELEVATED_BY_SCRIPT="false"
TEMP_CONTRIBUTOR_ASSIGNED="false"
TEMP_CONTRIBUTOR_ASSIGNMENT_ID=""
NEEDS_PROPAGATION_WAIT="false"
CLEANUP_DONE="false"

cleanup_temporary_access() {
    local source="${1:-trap}"

    if [ "$CLEANUP_DONE" = "true" ]; then
        return
    fi

    if [ "$TEMP_CONTRIBUTOR_ASSIGNED" != "true" ] && [ "$ELEVATED_BY_SCRIPT" != "true" ]; then
        return
    fi

    if [ "$source" = "trap" ]; then
        echo "🧹 Cleaning up temporary access before exit..."
    fi

    if [ "$TEMP_CONTRIBUTOR_ASSIGNED" = "true" ] && [ ! -z "$TEMP_CONTRIBUTOR_ASSIGNMENT_ID" ] && [ "$TEMP_CONTRIBUTOR_ASSIGNMENT_ID" != "null" ]; then
        if az role assignment delete --ids "$TEMP_CONTRIBUTOR_ASSIGNMENT_ID" >/dev/null 2>&1; then
            echo "✅ Temporary Contributor access removed"
        else
            echo "⚠️  WARNING - Could not remove temporary Contributor access automatically"
            echo "   📝 Please remove Contributor role on subscription '$SUBSCRIPTION_ID' for your user manually"
        fi
    fi

    if [ "$ELEVATED_BY_SCRIPT" = "true" ]; then
        mapfile -t ROOT_UAA_ASSIGNMENT_IDS < <(az role assignment list --scope "/" --assignee "$USER_ID" \
            --query "[?roleDefinitionName=='User Access Administrator'].id" -o tsv 2>/dev/null)

        if [ ${#ROOT_UAA_ASSIGNMENT_IDS[@]} -gt 0 ]; then
            ROOT_UAA_DELETE_FAILED="false"
            for assignment_id in "${ROOT_UAA_ASSIGNMENT_IDS[@]}"; do
                if ! az role assignment delete --ids "$assignment_id" >/dev/null 2>&1; then
                    ROOT_UAA_DELETE_FAILED="true"
                fi
            done

            if [ "$ROOT_UAA_DELETE_FAILED" = "false" ]; then
                echo "✅ Temporary elevated access removed"
            else
                echo "⚠️  WARNING - Could not fully remove temporary elevated access automatically"
                echo "   📝 Please remove User Access Administrator role on scope '/' for your user manually"
            fi
        else
            echo "⚠️  WARNING - Temporary elevated access assignment not found for cleanup"
        fi
    fi

    CLEANUP_DONE="true"
}

trap 'cleanup_temporary_access trap' EXIT

HAS_ELEVATED_ACCESS=$(az role assignment list --scope "/" --assignee "$USER_ID" \
    --query "[?roleDefinitionName=='User Access Administrator' || roleDefinitionName=='Owner'].roleDefinitionName" \
    -o tsv 2>/dev/null)

if [ -z "$HAS_ELEVATED_ACCESS" ]; then
    log_verbose "No elevated access found, trying elevateAccess API..."
    if az rest --method POST --url "/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01" >/dev/null 2>&1; then
        ELEVATED_BY_SCRIPT="true"
        NEEDS_PROPAGATION_WAIT="true"
        echo "✅ Elevated access requested"
        HAS_ELEVATED_ACCESS=$(az role assignment list --scope "/" --assignee "$USER_ID" \
            --query "[?roleDefinitionName=='User Access Administrator' || roleDefinitionName=='Owner'].roleDefinitionName" \
            -o tsv 2>/dev/null)
        if [ -z "$HAS_ELEVATED_ACCESS" ]; then
            echo "❌ FAILED - Elevated access request did not become active"
            exit 1
        fi
        echo "✅ Elevated access confirmed"
    else
        echo "❌ FAILED - Cannot elevate access"
        echo "   You likely need Global Administrator privileges"
        exit 1
    fi
else
    echo "✅ Elevated access already available"
fi

# Ensure provider registration rights at subscription scope.
HAS_SUBSCRIPTION_WRITE=$(az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID" --assignee "$USER_ID" \
    --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].id | [0]" -o tsv 2>/dev/null)

if [ -z "$HAS_SUBSCRIPTION_WRITE" ] || [ "$HAS_SUBSCRIPTION_WRITE" == "null" ]; then
    echo "🔐 No Owner/Contributor role found on subscription, assigning temporary Contributor..."
    TEMP_CONTRIBUTOR_ASSIGNMENT_ID=$(az role assignment create \
        --assignee "$USER_ID" \
        --role "Contributor" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --query id -o tsv 2>&1)
    TEMP_CONTRIBUTOR_STATUS=$?
    if [[ "$VERBOSE" == "true" ]]; then
        echo "🔍 [VERBOSE] Contributor assignment output: $TEMP_CONTRIBUTOR_ASSIGNMENT_ID"
    fi

    if [ $TEMP_CONTRIBUTOR_STATUS -eq 0 ]; then
        TEMP_CONTRIBUTOR_ASSIGNED="true"
        NEEDS_PROPAGATION_WAIT="true"
        echo "✅ Temporary Contributor role assigned"
    elif [[ "$TEMP_CONTRIBUTOR_ASSIGNMENT_ID" == *"RoleAssignmentExists"* ]] || [[ "$TEMP_CONTRIBUTOR_ASSIGNMENT_ID" == *"already exists"* ]]; then
        echo "✅ Contributor role already present"
    else
        echo "⚠️  WARNING - Could not assign temporary Contributor role"
        log_verbose "Temporary Contributor assignment failed: $TEMP_CONTRIBUTOR_ASSIGNMENT_ID"
    fi
else
    echo "✅ Subscription write access already available"
fi

if [ "$NEEDS_PROPAGATION_WAIT" = "true" ]; then
    echo "⏳ Waiting for RBAC propagation (15 seconds)..."
    sleep 15
fi

# Provider registration now runs after elevated access checks/temporary permissions.
register_required_providers
echo ""

# Step 5: Assign roles
echo "🔓 Step 5/6: Assigning RBAC permissions..."

# Get current tenant
TENANT_ID=$(az account show --query tenantId -o tsv)

# Determine scope for Owner assignment
if [[ "$MANAGEMENT_GROUP_MODE" == "true" ]]; then
    if [[ ! -z "$MANAGEMENT_GROUP_NAME" ]]; then
        DEFAULT_MG_NAME="$MANAGEMENT_GROUP_NAME"
        SPECIFIED_MG_ID=$(az account management-group list --query "[?displayName=='$DEFAULT_MG_NAME'].name | [0]" -o tsv 2>/dev/null)

        if [ -z "$SPECIFIED_MG_ID" ] || [ "$SPECIFIED_MG_ID" == "null" ]; then
            echo "📁 Creating '$DEFAULT_MG_NAME' management group..."
            if [[ "$VERBOSE" == "true" ]]; then
                CREATE_MG_OUTPUT=$(az account management-group create --name "$DEFAULT_MG_NAME" --display-name "$DEFAULT_MG_NAME" 2>&1)
                CREATE_MG_STATUS=$?
                echo "🔍 [VERBOSE] Create management group output: $CREATE_MG_OUTPUT"
            else
                CREATE_MG_OUTPUT=$(az account management-group create --name "$DEFAULT_MG_NAME" --display-name "$DEFAULT_MG_NAME" 2>/dev/null)
                CREATE_MG_STATUS=$?
            fi

            if [ $CREATE_MG_STATUS -eq 0 ] || [[ "$CREATE_MG_OUTPUT" == *"already exists"* ]] || [[ "$CREATE_MG_OUTPUT" == *"AlreadyExists"* ]]; then
                TARGET_MG_ID="$DEFAULT_MG_NAME"
            else
                echo "❌ FAILED - Could not create management group '$DEFAULT_MG_NAME'"
                log_verbose "Management group creation failed: $CREATE_MG_OUTPUT"
                exit 1
            fi
        else
            TARGET_MG_ID="$SPECIFIED_MG_ID"
        fi
    else
        TARGET_MG_ID=$(az account management-group list --query "[?displayName=='Tenant Root Group' || name=='$TENANT_ID'].name | [0]" -o tsv 2>/dev/null)
        if [ -z "$TARGET_MG_ID" ] || [ "$TARGET_MG_ID" == "null" ]; then
            TARGET_MG_ID=$(az account management-group list --query "[0].name" -o tsv 2>/dev/null)
        fi
    fi
else
    # Current-subscription mode prefers subscription scope.
    TARGET_MG_ID=""
fi

if [ ! -z "$TARGET_MG_ID" ] && [ "$TARGET_MG_ID" != "null" ]; then
    OWNER_SCOPE="/providers/Microsoft.Management/managementGroups/$TARGET_MG_ID"
    SCOPE_NAME="Management Group ($TARGET_MG_ID)"
else
    OWNER_SCOPE="/subscriptions/$SUBSCRIPTION_ID"
    SCOPE_NAME="Subscription ($SUBSCRIPTION_ID)"

    if [[ "$MANAGEMENT_GROUP_MODE" == "true" ]]; then
        echo "⚠️  WARNING - Could not determine management group, falling back to subscription scope"
        log_verbose "Management group lookup failed; using subscription scope instead"
    fi
fi

# ABAC condition to prevent privileged role assignments
CONDITION='((!(ActionMatches{'\''Microsoft.Authorization/roleAssignments/write'\''})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168})) AND ((!(ActionMatches{'\''Microsoft.Authorization/roleAssignments/delete'\''})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168}))'

# Role 1: Owner on management group with condition
OWNER_OUTPUT=$(az role assignment create \
    --assignee "$SP_ID" \
    --role "Owner" \
    --scope "$OWNER_SCOPE" \
    --condition "$CONDITION" \
    --condition-version "2.0" 2>&1)
OWNER_STATUS=$?
if [[ "$VERBOSE" == "true" ]]; then
        echo "🔍 [VERBOSE] Owner role assignment output: $OWNER_OUTPUT"
fi

if [ $OWNER_STATUS -eq 0 ] || [[ "$OWNER_OUTPUT" == *"already exists"* ]] || [[ "$OWNER_OUTPUT" == *"RoleAssignmentExists"* ]]; then
    echo "✅ Owner role assigned on $SCOPE_NAME"
else
    echo "❌ FAILED - Could not assign Owner role on $SCOPE_NAME"
    log_verbose "Owner assignment failed: $OWNER_OUTPUT"
    exit 1
fi

# Role 2: User Access Administrator on Microsoft.Capacity
UAA_OUTPUT=$(az role assignment create \
    --assignee "$SP_ID" \
    --role "User Access Administrator" \
    --scope "/providers/Microsoft.Capacity" 2>&1)
UAA_STATUS=$?
if [[ "$VERBOSE" == "true" ]]; then
        echo "🔍 [VERBOSE] User Access Administrator assignment output: $UAA_OUTPUT"
fi

if [ $UAA_STATUS -eq 0 ] || [[ "$UAA_OUTPUT" == *"already exists"* ]] || [[ "$UAA_OUTPUT" == *"RoleAssignmentExists"* ]]; then
    echo "✅ User Access Administrator assigned on Microsoft.Capacity"
else
    echo "❌ FAILED - Could not assign User Access Administrator on Microsoft.Capacity"
    log_verbose "User Access Administrator assignment failed: $UAA_OUTPUT"
    exit 1
fi

# Role 3: Reservations Administrator on Microsoft.Capacity
RES_OUTPUT=$(az role assignment create \
    --assignee "$SP_ID" \
    --role "Reservations Administrator" \
    --scope "/providers/Microsoft.Capacity" 2>&1)
RES_STATUS=$?
if [[ "$VERBOSE" == "true" ]]; then
        echo "🔍 [VERBOSE] Reservations Administrator assignment output: $RES_OUTPUT"
fi

if [ $RES_STATUS -eq 0 ] || [[ "$RES_OUTPUT" == *"already exists"* ]] || [[ "$RES_OUTPUT" == *"RoleAssignmentExists"* ]]; then
    echo "✅ Reservations Administrator assigned on Microsoft.Capacity"
else
    echo "❌ FAILED - Could not assign Reservations Administrator on Microsoft.Capacity"
    log_verbose "Reservations Administrator assignment failed: $RES_OUTPUT"
    exit 1
fi
echo ""

# Step 6: Clean up temporary permissions added by this script
if [ "$TEMP_CONTRIBUTOR_ASSIGNED" = "true" ] || [ "$ELEVATED_BY_SCRIPT" = "true" ]; then
    echo "🧹 Step 6/6: Removing temporary access..."
    cleanup_temporary_access step6
    trap - EXIT

    echo ""
fi






echo "🎉 SETUP COMPLETED SUCCESSFULLY!"
echo "================================="
echo ""
echo "🎯 GitHub Secrets to add:"
echo "   AZURE_CLIENT_ID=$APP_ID"
echo "   AZURE_TENANT_ID=$TENANT_ID"
echo "   AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
echo ""
echo "📝 Next steps:"
echo "   1. Add the secrets above to your GitHub repository"
echo "   2. Use 'azure/login@v1' action with OIDC in your workflows"
echo "   3. Reference: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure"
echo ""

if [[ "$VERBOSE" == "true" ]]; then
    echo "🔧 Troubleshooting info:"
    echo "   - App Registration ID: $APP_ID"
    echo "   - Service Principal ID: $SP_ID" 
    echo "   - RBAC Roles: Owner (with security restrictions) + Azure AD roles"
    echo "   - Azure AD Permissions: Microsoft Graph API permissions"
    echo "   - RBAC Scope: $SCOPE_NAME"
    echo "   - Owner GUID: 8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    echo "   - Security Condition: Blocks Owner/RBAC Admin role assignments"
    echo ""
    echo "🆘 If you encounter issues:"
    echo "   1. Azure CLI JSON errors: Try 'az cache purge' and 'az upgrade'"
    echo "   2. Service Principal creation fails: Wait 5 minutes and retry"
    echo "   3. RBAC assignment fails: Check if you have Owner permissions"
    echo "   4. Run with 'verbose' mode for detailed debugging"
    echo ""
fi

echo "🔒 Security: Service Principal CANNOT assign these roles:"
echo "   ❌ Owner (8e3af657-a8ff-443c-a75c-2fe8c4bcb635)"
echo "   ❌ RBAC Administrator (f58310d9-a9f6-439a-9e8d-f62e7b41a168)"
echo ""
echo "✅ Service Principal HAS these RBAC roles:"
echo "   ✅ Owner (with security restrictions - cannot assign/delete Owner and RBAC Admin roles)"
echo ""
echo "✅ Service Principal HAS these Azure AD permissions:"
for PERMISSION_NAME in "${REQUIRED_APP_PERMISSIONS[@]}"; do
    case "$PERMISSION_NAME" in
        "Application.ReadWrite.All")
            echo "   ✅ $PERMISSION_NAME (application permission on service principal for app management)"
            ;;
        "Directory.ReadWrite.All")
            echo "   ✅ $PERMISSION_NAME (application permission on service principal for directory operations)"
            ;;
        "AppRoleAssignment.ReadWrite.All")
            echo "   ✅ $PERMISSION_NAME (application permission on service principal for role assignments)"
            ;;
        *)
            echo "   ✅ $PERMISSION_NAME (application permission on service principal)"
            ;;
    esac
done
for PERMISSION_NAME in "${REQUIRED_DELEGATED_PERMISSIONS[@]}"; do
    echo "   ✅ $PERMISSION_NAME (delegated grant stored via service principal oauth2PermissionGrant)"
done
echo ""

if [[ "$VERBOSE" == "true" ]]; then
    echo "🔍 [VERBOSE] Summary of created resources:"
    echo "🔍 [VERBOSE]   App Registration: $APP_NAME (ID: $APP_ID)"
    echo "🔍 [VERBOSE]   Service Principal: $SP_ID"
    echo "🔍 [VERBOSE]   RBAC Role: Owner (with security conditions)"
    echo "🔍 [VERBOSE]   Azure AD Permissions: Microsoft Graph API permissions"
    echo "🔍 [VERBOSE]   RBAC Scope: $SCOPE_NAME"
    echo "🔍 [VERBOSE]   Subscription: $SUBSCRIPTION_ID"
    echo "🔍 [VERBOSE]   Tenant: $TENANT_ID"
    echo ""
fi

echo "✅ Ready for GitHub Actions!"