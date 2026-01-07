# Infra/infra-setup.ps1
# Azure Infrastructure Setup Script
# Creates Resource Group, VNet, NSG, VMs, ACR, and Service Principal
az login --use-device-code --tenant ec7789f0-7ef2-4ff6-89b1-a74d3fc8f81c
# ====== Config ======
$RG = "cbaov-rg"
$LOCATION = "NorthEurope"
$VNET_NAME = "cbaov-vnet"
$SUBNET_NAME = "cbaov-subnet"
$VNET_CIDR = "10.0.0.0/16"
$SUBNET_CIDR = "10.0.1.0/24"
$NSG = "core-nsg"
$VM_SIZE = "Standard_B2s"
$ADMIN_USER = "vinadmin"
$SSH_PUB = "$HOME\.ssh\id_rsa.pub"
$SSH_KEY = "$HOME\.ssh\id_rsa"
$ACR_NAME = "cbaovregistry"   # must be globally unique in Azure
$SP_NAME = "AZURE_CLIENT_ID"
$AppServicePlan = "cbaov-plan"
$WebAppName     = "cbaov-webapp"         # must be globally unique in the Azure region
$GHCRUser    = "vince-cbaov"             # your GitHub org/user that owns the GHCR repo
$GHCRToken   = ""                        # PAT with read:packages (and write:packages if 
$VM_LIST = @("nginx","docker","jenkins")

# Image to deploy
$Image = "ghcr.io/$GHCRUser/cbaov-app:v1"

# ====== Pre-flight ======
Write-Host "[Pre-flight] Validating prerequisites..."
if (!(Test-Path $SSH_PUB) -or !(Test-Path $SSH_KEY)) {
    Write-Error "Missing SSH keys. Generate with: ssh-keygen -t rsa -b 4096 -C 'vinlabs-key'"
    exit 1
}

Write-Host "Azure account:"
az account show --output table
if ($LASTEXITCODE -ne 0) { Write-Error "Run 'az login' and retry."; exit 1 }

$SUBSCRIPTION_ID = az account show --query id -o tsv

# ====== Resource Group ======
Write-Host "[RG] Creating resource group: $RG in $LOCATION"
az group create --name $RG --location $LOCATION | Out-Null

# ====== NSG + Rules ======
Write-Host "[NSG] Creating NSG and rules..."
az network nsg create --resource-group $RG --name $NSG --location $LOCATION | Out-Null

az network nsg rule create --resource-group $RG --nsg-name $NSG --name allow-ssh `
  --priority 1000 --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 22 `
  --source-address-prefixes "*" | Out-Null

az network nsg rule create --resource-group $RG --nsg-name $NSG --name allow-http-https `
  --priority 1010 --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 80 443 `
  --source-address-prefixes "*" | Out-Null

az network nsg rule create --resource-group $RG --nsg-name $NSG --name allow-jenkins `
  --priority 1020 --access Allow --protocol Tcp --direction Inbound --destination-port-ranges 8080 `
  --source-address-prefixes "*" | Out-Null

# Restrict SSH to current public IP
Write-Host "[NSG] Restricting SSH rule to your current public IP..."
try {
    $MY_IP = (Invoke-RestMethod -Uri "https://ifconfig.me")
    if ($MY_IP) {
        az network nsg rule update --resource-group $RG --nsg-name $NSG --name allow-ssh `
          --source-address-prefixes $MY_IP | Out-Null
    }
} catch {
    Write-Warning "Could not detect public IP. SSH remains open to '*' temporarily."
}

# ====== VNet + Subnet ======
Write-Host "[Network] Creating VNet and subnet..."
az network vnet create --resource-group $RG --name $VNET_NAME `
  --address-prefix $VNET_CIDR --subnet-name $SUBNET_NAME --subnet-prefix $SUBNET_CIDR | Out-Null

# ====== Public IPs + NICs ======
Write-Host "[Network] Creating public IPs and NICs..."
foreach ($vm in $VM_LIST) {
    az network public-ip create --resource-group $RG --name "$vm-ip" --sku Standard --location $LOCATION | Out-Null
    az network nic create --resource-group $RG --name "$vm-nic" --location $LOCATION `
      --subnet $SUBNET_NAME --vnet-name $VNET_NAME --network-security-group $NSG `
      --public-ip-address "$vm-ip" | Out-Null
}

# ====== VMs ======
Write-Host "[Compute] Provisioning VMs..."
foreach ($vm in $VM_LIST) {
    az vm create --resource-group $RG --name "$vm-server" --location $LOCATION `
      --nics "$vm-nic" --image Ubuntu2204 --admin-username $ADMIN_USER `
      --ssh-key-values $SSH_PUB --size $VM_SIZE | Out-Null
}

# -----------------------------------------------------------------------------
# Azure Web App (Linux, Docker)
# -----------------------------------------------------------------------------
Write-Host "Creating App Service Plan..."
az appservice plan create `
  --name $AppServicePlan `
  --resource-group $RG `
  --sku B1 `
  --is-linux | Out-Null

Write-Host "Creating Web App..."
az webapp create `
  --resource-group $RG `
  --plan $AppServicePlan `
  --name $WebAppName `
  --deployment-container-image-name $Image | Out-Null


if ($GHCRPrivate -and ($GHCRToken -ne "")) {
  Write-Host "Configuring Web App registry credentials for private GHCR..."
  az webapp config appsettings set `
    --resource-group $RG `
    --name $WebAppName `
    --settings DOCKER_REGISTRY_SERVER_URL="https://ghcr.io" `
               DOCKER_REGISTRY_SERVER_USERNAME="$GHCRUser" `
               DOCKER_REGISTRY_SERVER_PASSWORD="$GHCRToken" `
    | Out-Null
} else {
  Write-Host "Skipping registry credentials (GHCRPrivate=$GHCRPrivate)."
}
# -----------------------------------------------------------------------------

# ====== Azure Container Registry (ACR) ======
Write-Host "[ACR] Creating Azure Container Registry: $ACR_NAME"
az acr create --name $ACR_NAME --resource-group $RG --sku Basic --location $LOCATION --admin-enabled false | Out-Null
$ACR_LOGIN_SERVER = az acr show -n $ACR_NAME --query loginServer -o tsv
Write-Host "[ACR] Registry created: $ACR_LOGIN_SERVER"

# ====== Service Principal for CI/CD ======
Write-Host "[SP] Creating Service Principal scoped to RG '$RG'..."
$SP_JSON = az ad sp create-for-rbac --name $SP_NAME --role AcrPush `
  --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG"
$SP_JSON | Out-File -FilePath "sp_credentials.json" -Encoding utf8

$AZURE_CLIENT_ID = ($SP_JSON | ConvertFrom-Json).appId
$AZURE_TENANT_ID = ($SP_JSON | ConvertFrom-Json).tenant
Write-Host "[SP] Created: clientId=$AZURE_CLIENT_ID tenantId=$AZURE_TENANT_ID (secret stored in sp_credentials.json)"

# Explicit ACR role assignment
Write-Host "[SP] Assigning ACR roles (AcrPush) to Service Principal..."
$ACR_ID = az acr show -n $ACR_NAME --query id -o tsv
az role assignment create --assignee $AZURE_CLIENT_ID --role "AcrPush" --scope $ACR_ID | Out-Null

# ====== Collect IPs ======
Write-Host "[Info] VM Public IPs:"
az vm list-ip-addresses --resource-group $RG --output table

$NGINX_IP = az network public-ip show -g $RG -n nginx-ip --query "ipAddress" -o tsv
$DOCKER_IP = az network public-ip show -g $RG -n docker-ip --query "ipAddress" -o tsv
$JENKINS_IP = az network public-ip show -g $RG -n jenkins-ip --query "ipAddress" -o tsv
$webAppUrl = az webapp show `
  --resource-group $RG `
  --name $WebAppName `
  --query "defaultHostName" `
  --output tsv
Write-Host "Web App URL: http://$webAppUrl"

Write-Host "NGINX:  $NGINX_IP"
Write-Host "Docker: $DOCKER_IP"
Write-Host "Jenkins:$JENKINS_IP"

# ====== Output for CI/CD wiring ======
Write-Host "========================================"
Write-Host "[Complete] Infra ready."
Write-Host "Region:     $LOCATION"
Write-Host "RG:         $RG"
Write-Host "ACR:        $ACR_LOGIN_SERVER"
Write-Host "SP file:    sp_credentials.json (import into Jenkins)"
Write-Host "SP details: clientId=$AZURE_CLIENT_ID tenantId=$AZURE_TENANT_ID"
Write-Host "NGINX IP:   $NGINX_IP"
Write-Host "Docker IP:  $DOCKER_IP"
Write-Host "Jenkins IP: $JENKINS_IP"
Write-Host "Next: Update DNS A record for app.cbaov.com -> $NGINX_IP"
Write-Host "Then run: ./app_and_proxy_deploy.sh"
Write-Host "========================================"
