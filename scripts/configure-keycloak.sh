#!/bin/bash

# Keycloak Configuration Script
# This script configures Keycloak for Kafka OAuth authentication

set -e

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-qkk.apps.ocp4.klaassen.click}"
REALM_NAME="${REALM_NAME:-kafka}"
CLIENT_ID="${CLIENT_ID:-quarkus-kafka-client}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
NAMESPACE="${NAMESPACE:-qkk}"

echo "========================================="
echo "Keycloak Configuration Script"
echo "========================================="
echo "Keycloak URL: $KEYCLOAK_URL"
echo "Realm: $REALM_NAME"
echo "Client ID: $CLIENT_ID"
echo ""

# Get admin access token
echo "Getting admin access token..."
ADMIN_TOKEN=$(curl -k -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ "$ADMIN_TOKEN" == "null" ] || [ -z "$ADMIN_TOKEN" ]; then
    echo "ERROR: Failed to get admin token. Please check credentials."
    exit 1
fi

echo "Admin token obtained successfully!"

# Create realm
echo "Creating realm: $REALM_NAME"
REALM_EXISTS=$(curl -k -s -o /dev/null -w "%{http_code}" \
  -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

if [ "$REALM_EXISTS" == "404" ]; then
    curl -k -s -X POST "${KEYCLOAK_URL}/admin/realms" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"realm\": \"${REALM_NAME}\",
        \"enabled\": true,
        \"displayName\": \"Kafka Realm\",
        \"accessTokenLifespan\": 300,
        \"ssoSessionIdleTimeout\": 1800,
        \"ssoSessionMaxLifespan\": 36000
      }" > /dev/null
    echo "Realm created successfully!"
else
    echo "Realm already exists, skipping creation."
fi

# Create client for Kafka
echo "Creating Kafka client: $CLIENT_ID"
CLIENT_RESPONSE=$(curl -k -s \
  -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${CLIENT_ID}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

CLIENT_COUNT=$(echo "$CLIENT_RESPONSE" | jq '. | length')

if [ "$CLIENT_COUNT" -gt 0 ]; then
    echo "Client already exists, updating..."
    CLIENT_UUID=$(echo "$CLIENT_RESPONSE" | jq -r '.[0].id')
    
    UPDATE_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\": \"${CLIENT_ID}\",
        \"enabled\": true,
        \"clientAuthenticatorType\": \"client-secret\",
        \"redirectUris\": [],
        \"webOrigins\": [],
        \"protocol\": \"openid-connect\",
        \"publicClient\": false,
        \"standardFlowEnabled\": false,
        \"directAccessGrantsEnabled\": true,
        \"serviceAccountsEnabled\": true,
        \"authorizationServicesEnabled\": true
      }")
    HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -n1)
    UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')
    if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
        echo "WARNING: Client update returned HTTP $HTTP_CODE"
    fi
else
    echo "Creating new client..."
    CREATE_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\": \"${CLIENT_ID}\",
        \"enabled\": true,
        \"clientAuthenticatorType\": \"client-secret\",
        \"redirectUris\": [],
        \"webOrigins\": [],
        \"protocol\": \"openid-connect\",
        \"publicClient\": false,
        \"standardFlowEnabled\": false,
        \"directAccessGrantsEnabled\": true,
        \"serviceAccountsEnabled\": true,
        \"authorizationServicesEnabled\": true
      }")
    HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')
    if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "204" ]; then
        echo "ERROR: Client creation failed with HTTP $HTTP_CODE"
        echo "Response: $RESPONSE_BODY"
        exit 1
    fi
    echo "Client created successfully!"
    
    # Get the client UUID after creation
    CLIENT_UUID=$(curl -k -s \
      -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${CLIENT_ID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.[0].id')
fi

# Verify client UUID was obtained
if [ "$CLIENT_UUID" == "null" ] || [ -z "$CLIENT_UUID" ]; then
    echo "ERROR: Failed to get client UUID. Client may not have been created properly."
    exit 1
fi

echo "Client UUID: $CLIENT_UUID"

# Get client secret
echo "Retrieving client secret..."
CLIENT_SECRET_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
  -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

HTTP_CODE=$(echo "$CLIENT_SECRET_RESPONSE" | tail -n1)
SECRET_BODY=$(echo "$CLIENT_SECRET_RESPONSE" | sed '$d')
CLIENT_SECRET=$(echo "$SECRET_BODY" | jq -r '.value')

if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: Failed to get client secret. HTTP code: $HTTP_CODE"
    echo "Response: $SECRET_BODY"
    exit 1
fi

if [ "$CLIENT_SECRET" == "null" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "Client secret is null, regenerating..."
    REGEN_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
      -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/client-secret" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}")
    REGEN_HTTP_CODE=$(echo "$REGEN_RESPONSE" | tail -n1)
    REGEN_BODY=$(echo "$REGEN_RESPONSE" | sed '$d')
    
    if [ "$REGEN_HTTP_CODE" != "200" ] && [ "$REGEN_HTTP_CODE" != "204" ]; then
        echo "ERROR: Failed to regenerate client secret. HTTP code: $REGEN_HTTP_CODE"
        echo "Response: $REGEN_BODY"
        exit 1
    fi
    
    # Get the secret again after regeneration
    CLIENT_SECRET_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
      -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/client-secret" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}")
    HTTP_CODE=$(echo "$CLIENT_SECRET_RESPONSE" | tail -n1)
    SECRET_BODY=$(echo "$CLIENT_SECRET_RESPONSE" | sed '$d')
    CLIENT_SECRET=$(echo "$SECRET_BODY" | jq -r '.value')
    
    if [ "$CLIENT_SECRET" == "null" ] || [ -z "$CLIENT_SECRET" ]; then
        echo "ERROR: Client secret is still null after regeneration."
        echo "Response: $SECRET_BODY"
        exit 1
    fi
    echo "Client secret regenerated successfully!"
fi

# Get service account user ID
echo "Getting service account user ID..."
SERVICE_ACCOUNT_USER=$(curl -k -s \
  -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/service-account-user" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

SERVICE_ACCOUNT_USER_ID=$(echo "$SERVICE_ACCOUNT_USER" | jq -r '.id')

if [ "$SERVICE_ACCOUNT_USER_ID" == "null" ] || [ -z "$SERVICE_ACCOUNT_USER_ID" ]; then
    echo "WARNING: Could not get service account user ID. Roles may need to be configured manually."
else
    echo "Service account user ID: $SERVICE_ACCOUNT_USER_ID"
    
    # Create client role for Kafka access
    echo "Creating Kafka client role..."
    ROLE_NAME="kafka-access"
    ROLE_EXISTS=$(curl -k -s -o /dev/null -w "%{http_code}" \
      -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles/${ROLE_NAME}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}")
    
    if [ "$ROLE_EXISTS" == "404" ]; then
        curl -k -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{
            \"name\": \"${ROLE_NAME}\",
            \"description\": \"Kafka access role\"
          }" > /dev/null
        echo "Role created successfully!"
    else
        echo "Role already exists, skipping creation."
    fi
    
    # Get the role ID
    ROLE_RESPONSE=$(curl -k -s \
      -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles/${ROLE_NAME}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}")
    ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.id')
    
    # Assign role to service account
    echo "Assigning role to service account..."
    ASSIGN_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
      -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users/${SERVICE_ACCOUNT_USER_ID}/role-mappings/clients/${CLIENT_UUID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "[{
        \"id\": \"${ROLE_ID}\",
        \"name\": \"${ROLE_NAME}\"
      }]")
    ASSIGN_HTTP_CODE=$(echo "$ASSIGN_RESPONSE" | tail -n1)
    
    if [ "$ASSIGN_HTTP_CODE" == "204" ] || [ "$ASSIGN_HTTP_CODE" == "200" ]; then
        echo "Role assigned successfully!"
    else
        echo "WARNING: Role assignment returned HTTP $ASSIGN_HTTP_CODE"
        echo "Response: $(echo "$ASSIGN_RESPONSE" | sed '$d')"
    fi
fi

# Clean up default authorization resource if it exists
# Keycloak creates a "Default Resource" when authorization is enabled, but Strimzi doesn't support it
echo "Checking for default authorization resources..."
AUTHZ_RESOURCES=$(curl -k -s \
  -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/authz/resource-server/resource" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

if [ "$AUTHZ_RESOURCES" != "null" ] && [ -n "$AUTHZ_RESOURCES" ]; then
    DEFAULT_RESOURCE_ID=$(echo "$AUTHZ_RESOURCES" | jq -r '.[] | select(.name == "Default Resource") | ._id' | head -1)
    
    if [ "$DEFAULT_RESOURCE_ID" != "null" ] && [ -n "$DEFAULT_RESOURCE_ID" ]; then
        echo "Removing default authorization resource (not supported by Strimzi)..."
        DELETE_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
          -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/authz/resource-server/resource/${DEFAULT_RESOURCE_ID}" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}")
        DELETE_HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -n1)
        
        if [ "$DELETE_HTTP_CODE" == "204" ] || [ "$DELETE_HTTP_CODE" == "200" ]; then
            echo "Default resource removed successfully!"
        else
            echo "WARNING: Failed to remove default resource. HTTP code: $DELETE_HTTP_CODE"
            echo "You may need to manually remove it from the Keycloak admin console."
        fi
    else
        echo "No default resource found, skipping cleanup."
    fi
fi

# Create a minimal authorization resource and permission to ensure grants endpoint returns valid JSON
# Kafka's Keycloak authorizer expects a JSON array from the grants endpoint
# When there are no resources/permissions, the endpoint returns an error instead of []
# Creating a resource with a permission ensures the endpoint returns a valid array
echo "Checking authorization resources for grants endpoint..."
AUTHZ_RESOURCES=$(curl -k -s \
  -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/authz/resource-server/resource" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

# Check if there are any resources (excluding Default Resource which we already removed)
RESOURCE_COUNT=$(echo "$AUTHZ_RESOURCES" | jq -r 'if type == "array" then [.[] | select(.name != "Default Resource")] | length else 0 end' 2>/dev/null || echo "0")

if [ "$RESOURCE_COUNT" == "0" ] || [ "$AUTHZ_RESOURCES" == "null" ] || [ -z "$AUTHZ_RESOURCES" ] || [ "$AUTHZ_RESOURCES" == "[]" ]; then
    echo "No authorization resources found. Creating minimal resource and permission for grants endpoint..."
    
    # Create a minimal resource
    CREATE_RESOURCE_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
      -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/authz/resource-server/resource" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\": \"Cluster:kafka\",
        \"type\": \"kafka-cluster\",
        \"displayName\": \"Kafka Cluster Resource\"
      }")
    CREATE_HTTP_CODE=$(echo "$CREATE_RESOURCE_RESPONSE" | tail -n1)
    RESOURCE_RESPONSE_BODY=$(echo "$CREATE_RESOURCE_RESPONSE" | sed '$d')
    
    if [ "$CREATE_HTTP_CODE" == "201" ] || [ "$CREATE_HTTP_CODE" == "200" ]; then
        RESOURCE_ID=$(echo "$RESOURCE_RESPONSE_BODY" | jq -r '._id // .id // empty')
        echo "Minimal authorization resource created successfully! (ID: $RESOURCE_ID)"
        
        # Create a role-based policy using the service account role (for grants endpoint to return valid JSON)
        if [ -n "$RESOURCE_ID" ] && [ "$RESOURCE_ID" != "null" ]; then
            # Get the role ID we created earlier
            ROLE_RESPONSE=$(curl -k -s \
              -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/roles/${ROLE_NAME}" \
              -H "Authorization: Bearer ${ADMIN_TOKEN}")
            ROLE_ID=$(echo "$ROLE_RESPONSE" | jq -r '.id // empty')
            
            if [ -n "$ROLE_ID" ] && [ "$ROLE_ID" != "null" ]; then
                echo "Creating role-based policy using service account role..."
                CREATE_POLICY_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
                  -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/authz/resource-server/policy/role" \
                  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                  -H "Content-Type: application/json" \
                  -d "{
                    \"name\": \"Service Account Role Policy\",
                    \"description\": \"Policy that allows service account with kafka-access role\",
                    \"roles\": [{
                      \"id\": \"${ROLE_ID}\"
                    }]
                  }")
                POLICY_HTTP_CODE=$(echo "$CREATE_POLICY_RESPONSE" | tail -n1)
                POLICY_RESPONSE_BODY=$(echo "$CREATE_POLICY_RESPONSE" | sed '$d')
                
                if [ "$POLICY_HTTP_CODE" == "201" ] || [ "$POLICY_HTTP_CODE" == "200" ]; then
                    POLICY_ID=$(echo "$POLICY_RESPONSE_BODY" | jq -r '._id // .id // empty')
                    echo "Policy created successfully! (ID: $POLICY_ID)"
                    
                    # Create a permission for the resource using the policy
                    if [ -n "$POLICY_ID" ] && [ "$POLICY_ID" != "null" ]; then
                        echo "Creating permission for the resource..."
                        CREATE_PERMISSION_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
                          -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/authz/resource-server/permission/resource" \
                          -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                          -H "Content-Type: application/json" \
                          -d "{
                            \"name\": \"Kafka Cluster Permission\",
                            \"resources\": [\"${RESOURCE_ID}\"],
                            \"policies\": [\"${POLICY_ID}\"]
                          }")
                        PERMISSION_HTTP_CODE=$(echo "$CREATE_PERMISSION_RESPONSE" | tail -n1)
                        
                        if [ "$PERMISSION_HTTP_CODE" == "201" ] || [ "$PERMISSION_HTTP_CODE" == "200" ]; then
                            echo "Permission created successfully!"
                            echo "This ensures the grants endpoint returns a valid JSON array."
                        else
                            echo "WARNING: Failed to create permission. HTTP code: $PERMISSION_HTTP_CODE"
                            echo "Response: $(echo "$CREATE_PERMISSION_RESPONSE" | sed '$d')"
                            echo "The resource and policy were created, but permission creation failed."
                        fi
                    else
                        echo "WARNING: Could not extract policy ID. Permission not created."
                    fi
                else
                    echo "WARNING: Failed to create policy. HTTP code: $POLICY_HTTP_CODE"
                    echo "Response: $POLICY_RESPONSE_BODY"
                    echo "The resource was created, but grants endpoint might still return errors."
                fi
            else
                echo "WARNING: Could not find service account role. Policy and permission not created."
                echo "The resource was created, but grants endpoint might still return errors."
            fi
        else
            echo "WARNING: Could not extract resource ID. Policy and permission not created."
        fi
    else
        echo "WARNING: Failed to create minimal resource. HTTP code: $CREATE_HTTP_CODE"
        echo "Response: $RESOURCE_RESPONSE_BODY"
        echo ""
        echo "If you see 'Invalid grants: not a JSON array' errors in Kafka logs,"
        echo "the grants endpoint might be returning invalid JSON. You may need to:"
        echo "1. Manually create an authorization resource and permission in Keycloak admin console"
        echo "2. Or configure Kafka to not use Keycloak authorization (use 'simple' instead)"
    fi
else
    echo "Authorization resources exist ($RESOURCE_COUNT found). Grants endpoint should work correctly."
fi

echo ""
echo "========================================="
echo "Configuration Summary"
echo "========================================="
echo "Realm: $REALM_NAME"
echo "Client ID: $CLIENT_ID"
echo "Client Secret: $CLIENT_SECRET"
echo "Token Endpoint: ${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token"
echo ""
echo "IMPORTANT: Save the client secret above!"
echo "You'll need it for Kafka and Quarkus configuration."
echo ""
echo "Authorization Services: Enabled"
echo "The client has been configured with authorization services enabled"
echo "to support Kafka's Keycloak authorization."
echo ""
echo "Note: With Keycloak authorization, the client is configured"
echo "as a super user in Kafka, which should grant all permissions."
echo "If you see 'Client does not support permissions' errors, ensure"
echo "authorization services are enabled in the Keycloak admin console."
echo ""
echo "Export these variables:"
echo "export KAFKA_CLIENT_SECRET=\"$CLIENT_SECRET\""
echo "export KEYCLOAK_TOKEN_ENDPOINT=\"${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token\""
echo "========================================="

