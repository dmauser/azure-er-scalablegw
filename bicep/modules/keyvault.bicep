// Key Vault with access policy for the deploying principal.
// Stores the admin password and username as secrets.
// Soft-delete is enabled to protect against accidental deletion.

param location string
param kvName string
param adminUsername string
@secure()
param adminPassword string
@description('Object ID of the deploying principal. Leave empty to skip access policy.')
param deployerObjectId string = ''

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    accessPolicies: empty(deployerObjectId) ? [] : [
      {
        tenantId: subscription().tenantId
        objectId: deployerObjectId
        permissions: {
          secrets: [
            'get'
            'list'
            'set'
            'delete'
            'recover'
            'backup'
            'restore'
          ]
        }
      }
    ]
  }
}

resource adminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'admin-password'
  properties: {
    value: adminPassword
    attributes: {
      enabled: true
    }
  }
}

resource adminUsernameSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'admin-username'
  properties: {
    value: adminUsername
    attributes: {
      enabled: true
    }
  }
}

output kvId string = keyVault.id
output kvName string = keyVault.name
// Secret URIs are Key Vault reference URLs, not secret values themselves.
// Linter warnings on these outputs can be suppressed — the URI is safe to output.
#disable-next-line outputs-should-not-contain-secrets
output adminPasswordKvUri string = adminPasswordSecret.properties.secretUri
#disable-next-line outputs-should-not-contain-secrets
output adminUsernameKvUri string = adminUsernameSecret.properties.secretUri
