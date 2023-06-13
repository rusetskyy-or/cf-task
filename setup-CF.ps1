Clear-Host
write-host "Starting script at $(Get-Date)"

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Az.Synapse -Force

# Handle cases where the user has multiple subscriptions
$subs = Get-AzSubscription | Select-Object
if($subs.GetType().IsArray -and $subs.length -gt 1){
    Write-Host "You have multiple Azure subscriptions - please select the one you want to use:"
    for($i = 0; $i -lt $subs.length; $i++)
    {
            Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
    }
    $selectedIndex = -1
    $selectedValidIndex = 0
    while ($selectedValidIndex -ne 1)
    {
            $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
            if (-not ([string]::IsNullOrEmpty($enteredValue)))
            {
                if ([int]$enteredValue -in (0..$($subs.Length - 1)))
                {
                    $selectedIndex = [int]$enteredValue
                    $selectedValidIndex = 1
                }
                else
                {
                    Write-Output "Please enter a valid subscription number."
                }
            }
            else
            {
                Write-Output "Please enter a valid subscription number."
            }
    }
    $selectedSub = $subs[$selectedIndex].Id
    Select-AzSubscription -SubscriptionId $selectedSub
    az account set --subscription $selectedSub
}

# Prompt user for a password for the SQL Database
$sqlUser = "SQLUser"
write-host ""
$sqlPassword = ""
$sqlPasswordName = "sqlPassword"
$complexPassword = 0


while ($complexPassword -ne 1)
{
    $SqlPassword = Read-Host "Enter a password to use for the $sqlUser login.
    `The password must meet complexity requirements:
    ` - Minimum 8 characters. 
    ` - At least one upper case English letter [A-Z]
    ` - At least one lower case English letter [a-z]
    ` - At least one digit [0-9]
    ` - At least one special character (!,@,#,%,^,&,$)
    ` "

    if(($SqlPassword -cmatch '[a-z]') -and ($SqlPassword -cmatch '[A-Z]') -and ($SqlPassword -match '\d') -and ($SqlPassword.length -ge 8) -and ($SqlPassword -match '!|@|#|%|\^|&|\$'))
    {
        $complexPassword = 1
	    Write-Output "Password $SqlPassword accepted. Make sure you remember this!"
    }
    else
    {
        Write-Output "$SqlPassword does not meet the complexity requirements."
    }
}

# Register resource providers
Write-Host "Registering resource providers...";
$provider_list = "Microsoft.Synapse", "Microsoft.Sql", "Microsoft.Storage", "Microsoft.Compute"
foreach ($provider in $provider_list){
    $result = Register-AzResourceProvider -ProviderNamespace $provider
    $status = $result.RegistrationState
    Write-Host "$provider : $status"
}

# Generate unique random suffix
[string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
Write-Host "Your randomly-generated suffix for Azure resources is $suffix"
$resourceGroupName = "cf-assessment-$suffix"

# Choose a random region
Write-Host "Finding an available region. This may take several minutes...";
$delay = 0, 30, 60, 90, 120 | Get-Random
Start-Sleep -Seconds $delay # random delay to stagger requests from multi-student classes
$preferred_list = "australiaeast","centralus","southcentralus","eastus2","northeurope","southeastasia","uksouth","westeurope","westus","westus2"
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Synapse" -and
    $_.Providers -contains "Microsoft.Sql" -and
    $_.Providers -contains "Microsoft.Storage" -and
    $_.Providers -contains "Microsoft.Compute" -and
    $_.Location -in $preferred_list
}
$max_index = $locations.Count - 1
$rand = (0..$max_index) | Get-Random
$Region = $locations.Get($rand).Location

# Test for subscription Azure SQL capacity constraints in randomly selected regions
# (for some subsription types, quotas are adjusted dynamically based on capacity)
 $success = 0
 $tried_list = New-Object Collections.Generic.List[string]

 while ($success -ne 1){
    write-host "Trying $Region"
    $capability = Get-AzSqlCapability -LocationName $Region
    if($capability.Status -eq "Available")
    {
        $success = 1
        write-host "Using $Region"
    }
    else
    {
        $success = 0
        $tried_list.Add($Region)
        $locations = $locations | Where-Object {$_.Location -notin $tried_list}
        if ($locations.Count -ne 1)
        {
            $rand = (0..$($locations.Count - 1)) | Get-Random
            $Region = $locations.Get($rand).Location
        }
        else {
            Write-Host "Couldn't find an available region for deployment."
            Write-Host "Sorry! Try again later."
            Exit
        }
    }
}
Write-Host "Creating $resourceGroupName resource group in $Region ..."
New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null

# Create Synapse workspace
$synapseWorkspaceName = "synapse$suffix"
$dataLakeAccountName = "datalake$suffix"
$sparkPool = "spark$suffix"
$sqlDatabaseName = "sql$suffix"

write-host "Creating $synapseWorkspace Synapse Analytics workspace in $resourceGroupName resource group..."
write-host "(This may take some time!)"
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
  -TemplateFile "setup.json" `
  -Mode Complete `
  -workspaceName $synapseWorkspaceName `
  -dataLakeAccountName $dataLakeAccountName `
  -sparkPoolName $sparkPool `
  -sqlDatabaseName $sqlDatabaseName `
  -sqlUser $sqlUser `
  -sqlPassword $sqlPassword `
  -uniqueSuffix $suffix `
  -Force

# Make the current user and the Synapse service principal owners of the data lake blob store
write-host "Granting permissions on the $dataLakeAccountName storage account..."
write-host "(you can ignore any warnings!)"
$subscriptionId = (Get-AzContext).Subscription.Id
$userName = ((az ad signed-in-user show) | ConvertFrom-JSON).UserPrincipalName
$id = (Get-AzADServicePrincipal -DisplayName $synapseWorkspaceName).id
New-AzRoleAssignment -Objectid $id -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
New-AzRoleAssignment -SignInName $userName -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;


# Upload files
write-host "Uploading files..."
$containerName = "files"
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
#$storageContext = $storageAccount.Context
#Get-ChildItem "./data/*.csv" -File | Foreach-Object {
#    write-host ""
#    $file = $_.Name
#    Write-Host $file
#    $blobPath = "data/$file"
#    Set-AzStorageBlobContent -File $_.FullName -Container $containerName -Blob $blobPath -Context $storageContext
#}
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName).Value[0]

# Create database
write-host "Creating the $sqlDatabaseName database..."
sqlcmd -S "$synapseWorkspaceName.sql.azuresynapse.net" -U $sqlUser -P $sqlPassword -d $sqlDatabaseName -I -i setup.sql

# Create KeyVault
$KeyVaultName ="kvdwfc$suffix"
write-host "Creating the $KeyVaultName Azure Key Vault..."
az KeyVault Create --name $KeyVaultName --resource-group $resourceGroupName --location $Region

#replace suffix in Synapse pipeline files
#Get-ChildItem "./pipelines/*." -File | Foreach-Object {
#    write-host ""
#    $file = $_.Name
#    Write-Host $file
#    $blobPath = "pipelines/$file"
#    $content = Get-Content -Path $blobPath
#    $NewContent = $content | ForEach-Object {$_ -replace "suffix", $suffix}
#    $NewContent | Set-Content -Path $blobPath  
#}

#create DataSets in the Azure Synapse Pipelines

$synapseWorkspace = Get-AzSynapseWorkspace -Name $synapseWorkspaceName -ResourceGroupName $resourceGroupName
Get-ChildItem "./pipelines/dataset/*.json" -File | Foreach-Object {
    $file = $_.Name
    write-host "Creating the $file Azure Synapse Pipelines dataset..."
    $blobPath = "pipelines/dataset/$file"
    $content = Get-Content -Path $blobPath
    $NewContent = $content | ForEach-Object {$_ -replace "suffix", $suffix}
    write-host $NewContent
    $NewContent | Set-Content -Path $blobPath 
    New-AzSynapseDataset -File $blobPath -Name $file.Replace(".json","") -WorkspaceName $synapseWorkspaceName 
}

#create Pipelines in the Azure Synapse Pipelines

Get-ChildItem "./pipelines/pipeline/*.json" -File | Foreach-Object {
    $file = $_.Name
    write-host "Creating the $file Azure Synapse Pipelines pipeline..."
    $blobPath = "pipelines/pipeline/$file"
    $content = Get-Content -Path $blobPath
    $NewContent = $content | ForEach-Object {$_ -replace "suffix", $suffix}
    write-host $NewContent
    $NewContent | Set-Content -Path $blobPath 
    New-AzSynapsePipeline -File $blobPath -Name $file.Replace(".json","") -WorkspaceName $synapseWorkspaceName 
}

#create Pipelines in the Azure Synapse Pipelines

Get-ChildItem "./pipelines/trigger/*.json" -File | Foreach-Object {
    $file = $_.Name
    write-host "Creating the $file Azure Synapse Pipelines trigger..."
    $blobPath = "pipelines/trigger/$file"
    $content = Get-Content -Path $blobPath
    $NewContent = $content | ForEach-Object {$_ -replace "suffix", $suffix}
    $NewContent = $content | ForEach-Object {$_ -replace "&subscription&", $subscriptionId}
    write-host $NewContent
    $NewContent | Set-Content -Path $blobPath 
    New-AzSynapsePipeline -File $blobPath -Name $file.Replace(".json","") -WorkspaceName $synapseWorkspaceName 
}



$sourceSasToken = "https://couponfollowdehiring.blob.core.windows.net/hiring/Data.zip?sv=2021-10-04&st=2023-05-26T16%3A27%3A33Z&se=2024-05-27T16%3A27%3A00Z&sr=b&sp=r&sig=0rPNqOglARvrvLEr6CmY3V6LcYGi9yxSmoW73UloYis%3D"
$sourceSasTokenName = "sourceSasToken"
$sourceFileName = "Data.zip"
az keyvault secret set --name $sourceSasTokenName --value $sourceSasToken --vault-name $KeyVaultName
write-host "SAS Token $sourceSasTokenName is stored into the $KeyVaultName"

$CurrentDate = Get-Date
$ExpiryDate = $CurrentDate.AddDays(7).ToString("yyyy-MM-dd")
$SasToken = az storage container generate-sas --account-name $dataLakeAccountName --name $containerName `
--https-only --permissions racw --expiry $ExpiryDate --account-key $storageAccountKey
$SasToken = $SasToken.Trim('"')
#$SasTokenName = "stoken$suffix"
$SasTokenName = "stoken"
az keyvault secret set --name $sqlPasswordName --value $sqlPassword --vault-name $KeyVaultName
write-host "SAS Token $sqlPasswordName is stored into the $KeyVaultName"
az keyvault secret set --name $SasTokenName --value $SasToken --vault-name $KeyVaultName
write-host "SAS Token $SasTokenName, stored into the $KeyVaultName, will expire at $ExpiryDate"

$targetSasToken = "https://$dataLakeAccountName.blob.core.windows.net/$ContainerName/$sourceFileName"+"?"+$SasToken

write-host $targetSasToken

write-host "Copying the source file $sourceFileName"
azcopy copy "$sourceSasToken" "$targetSasToken" --recursive=true



write-host "Script completed at $(Get-Date)"
