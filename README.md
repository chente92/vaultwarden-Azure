# Vaultwarden on Azure - Deployment Guide

This guide deploys a secure, cost-effective Vaultwarden (Bitwarden-compatible) password manager on Azure.

## Architecture

- **Azure Container Apps**: Hosts Vaultwarden container (Consumption plan)
- **PostgreSQL Flexible Server**: Database backend (Standard_B1ms)
- **Azure Files**: Persistent storage for Vaultwarden data
- **Virtual Network**: All resources secured within VNET with no public endpoints
- **Private Endpoints**: Storage accessible only via private network

**Estimated Cost**: ~$22-25/month

## Prerequisites

- Azure CLI installed ([Install Guide](https://docs.microsoft.com/cli/azure/install-azure-cli))
- An active Azure subscription
- Logged in to Azure CLI: `az login`

## Deployment Steps

### 1. Create Resource Group

```powershell
az group create --name vaultwarden-app --location swedencentral
```

### 2. Deploy Complete Infrastructure

Replace the credentials with your own secure values:

```powershell
az deployment group create `
  --resource-group vaultwarden-app `
  --template-file vaultwarden-complete.bicep `
  --parameters postgresAdminUser='youradminname' `
               postgresPassword='YourSecurePassword123!' `
               signupsAllowed=true
```

**Important Notes:**
- `postgresAdminUser`: Choose your PostgreSQL admin username (no special characters)
- `postgresPassword`: Use a strong password (min 8 chars, uppercase, lowercase, numbers, special chars)
- `signupsAllowed=true`: Allows you to create your first account

⏱️ **Deployment time**: ~8-10 minutes

### 3. Get Your Vaultwarden URL

After deployment completes:

```powershell
az deployment group show `
  --resource-group vaultwarden-app `
  --name vaultwarden-complete `
  --query "properties.outputs.vaultwardenUrl.value" `
  --output tsv
```

Copy this URL and open it in your browser.

### 4. Create Your Account

1. Open the Vaultwarden URL in your browser
2. Click **Create Account**
3. Enter your email and master password
4. Complete registration

### 5. Disable Signups (Security)

After creating your account, prevent others from registering:

```powershell
az containerapp update `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --set-env-vars "SIGNUPS_ALLOWED=false"
```

⏱️ **Wait ~30 seconds** for the new revision to deploy.

## Post-Deployment

### Check Deployment Status

```powershell
# View all deployed resources
az resource list --resource-group vaultwarden-app --output table

# Check container app health
az containerapp revision list `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --query "[?properties.active].{Name:name, Health:properties.healthState, Traffic:properties.trafficWeight}" `
  --output table
```

### View Container Logs

```powershell
az containerapp logs show `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --tail 50 `
  --follow false
```

### Verify Security (No Public Endpoints)

```powershell
# Check PostgreSQL - should show publicNetworkAccess: Disabled
az postgres flexible-server show `
  --resource-group vaultwarden-app `
  --name $(az postgres flexible-server list --resource-group vaultwarden-app --query "[0].name" -o tsv) `
  --query "network.publicNetworkAccess"

# Check Storage - should show publicNetworkAccess: Disabled
az storage account show `
  --resource-group vaultwarden-app `
  --name $(az storage account list --resource-group vaultwarden-app --query "[0].name" -o tsv) `
  --query "publicNetworkAccess"
```

## Management Commands

### Update Environment Variables

```powershell
az containerapp update `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --set-env-vars "VARIABLE_NAME=value"
```

### Restart Container

```powershell
az containerapp revision restart `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --revision $(az containerapp show --name vaultwarden --resource-group vaultwarden-app --query "properties.latestRevisionName" -o tsv)
```

### Scale Container Apps

```powershell
az containerapp update `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --min-replicas 1 `
  --max-replicas 5
```

### Reset PostgreSQL Password

If you lose your database password:

```powershell
# Reset the password
az postgres flexible-server update `
  --resource-group vaultwarden-app `
  --name $(az postgres flexible-server list --resource-group vaultwarden-app --query "[0].name" -o tsv) `
  --admin-password 'NewSecurePassword123!'

# Update Container App secret
$pgServer = az postgres flexible-server list --resource-group vaultwarden-app --query "[0].fullyQualifiedDomainName" -o tsv
$pgUser = az postgres flexible-server list --resource-group vaultwarden-app --query "[0].administratorLogin" -o tsv

az containerapp secret set `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --secrets "db-url=postgresql://${pgUser}:NewSecurePassword123!@${pgServer}:5432/vaultwarden"

# Force new revision
az containerapp update `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --cpu 0.25 `
  --memory 0.5Gi
```

## Backup Strategy

### Automated Backups (Included)

- **PostgreSQL**: 7-day automated backups (configured in deployment)
- **Storage**: 7-day soft delete for file shares (configured in deployment)

### Manual Database Backup

```powershell
# Export database backup
$pgServer = az postgres flexible-server list --resource-group vaultwarden-app --query "[0].name" -o tsv
$pgUser = az postgres flexible-server list --resource-group vaultwarden-app --query "[0].administratorLogin" -o tsv

# Note: Requires PostgreSQL client tools installed locally
pg_dump -h ${pgServer}.postgres.database.azure.com -U ${pgUser} -d vaultwarden > vaultwarden_backup_$(Get-Date -Format 'yyyyMMdd').sql
```

## Troubleshooting

### Container Not Starting

Check logs for errors:
```powershell
az containerapp logs show --name vaultwarden --resource-group vaultwarden-app --tail 100
```

### Database Connection Issues

Verify DATABASE_URL secret:
```powershell
az containerapp secret show `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --secret-name db-url `
  --query "value" `
  --output tsv
```

### Can't Access Vaultwarden URL

1. Verify ingress is enabled:
```powershell
az containerapp show `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --query "properties.configuration.ingress.external"
```

2. Check revision health:
```powershell
az containerapp revision list `
  --name vaultwarden `
  --resource-group vaultwarden-app `
  --query "[?properties.active]" `
  --output table
```

## Cleanup

To delete all resources:

```powershell
az group delete --name vaultwarden-app --yes --no-wait
```

**Warning**: This will permanently delete your Vaultwarden instance and all data!

## Security Best Practices

✅ **Implemented in this deployment:**
- PostgreSQL accessible only via VNET (no public endpoint)
- Storage Account with Private Endpoint only
- HTTPS-only ingress for Container Apps
- TLS 1.2 minimum for Storage Account
- Automated backups enabled
- Signups disabled after initial account creation

✅ **Recommended:**
- Store credentials in Azure Key Vault
- Enable Azure Monitor alerts for container restarts
- Review PostgreSQL logs periodically
- Keep Vaultwarden Docker image updated
- Use strong master password for your vault

## Support

- **Vaultwarden**: https://github.com/dani-garcia/vaultwarden
- **Azure Container Apps**: https://learn.microsoft.com/azure/container-apps/
- **Azure PostgreSQL**: https://learn.microsoft.com/azure/postgresql/

## License

This deployment template is provided as-is. Vaultwarden is licensed under GPL-3.0.
