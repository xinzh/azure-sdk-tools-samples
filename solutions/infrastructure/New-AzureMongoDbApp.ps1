<#
.SYNOPSIS
   Add two virtual machines to Azure subscription, install IIS7 from WebPI to the front end machine, 
   and conect it to the back end mongodb virtual machine by putting them on the same Vnet/subnet.
.DESCRIPTION
   This is a sample script demonstrating how to deploy a virtual machine that will host a product
   published on the Web Platform Installer catalog and will connect to a back end mongodb server.
.EXAMPLE
   .\New-AzureMongoDbApp -ServiceName "mymongoapp" -Location "West US" `
       -FrontEndHostName mongoappfe -FrontEndInstanceSize Small `
       -BackEndHostName mongoappbe -BackEndInstanceSize Small `
       -AffinityGroupName mongoappag1
#>
param (

    # Name of the service the VMs will be deployed to. If the service exists, the VMs 
    # will be deployed ot this service, otherwise, it will be created.
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName,
    
    # The target region the VMs will be deployed to. This is used to create the affinity 
    # group if it does not exist. If the affinity group exists, but in a different
    # region, the commandlet displays a warning.
    [Parameter(Mandatory = $true)]
    [String]
    $Location,
    
    # The host name for the front end web server.
    [Parameter(Mandatory = $true)]
    [String]
    $FrontEndHostName,
    
    # Instance size for the front end web server.
    [Parameter(Mandatory = $true)]
    [String]
    $FrontEndInstanceSize,
    
    # Back end mongodb host name
    [Parameter(Mandatory = $true)]
    [String]
    $BackEndHostName,
    
    # Back end mongodb instance size
    [Parameter(Mandatory = $true)]
    [String]
    $BackEndInstanceSize,
    
    # The affinity group the VNET and the VMs will be in
    [Parameter(Mandatory = $true)]
    [String]
    $AffinityGroupName)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# The script has been tested on Powershell 3.0

# Check if Windows Azure Powershell is avaiable
if ((Get-Module -ListAvailable Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please make sure to install them from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

<#
.SYNOPSIS
  Sends a file to a remote session.
.EXAMPLE
  $remoteSession = New-PSSession -ConnectionUri $remoteWinRmUri.AbsoluteUri -Credential $credential
  Send-File -Source "c:\temp\myappdata.xml" -Destination "c:\temp\myappdata.xml" $remoteSession
#>
function Send-File
{
    param (

        ## The path on the local computer
        [Parameter(Mandatory = $true)]
        $Source,
        
        ## The target path on the remote computer
        [Parameter(Mandatory = $true)]
        $Destination,
        
        ## The session that represents the remote computer
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession] $Session)
    
    $remoteScript =
    {
        param ($destination, $bytes)
        
        # Convert the destination path to a full filesystem path (to supportrelative paths)
        $Destination = $ExecutionContext.SessionState.`
        Path.GetUnresolvedProviderPathFromPSPath($Destination)
        
        # Write the content to the new file
        $file = [IO.File]::Open($Destination, "OpenOrCreate")
        $null = $file.Seek(0, "End")
        $null = $file.Write($bytes, 0, $bytes.Length)
        $file.Close()
    }
    
    # Get the source file, and then start reading its content
    $sourceFile = Get-Item $Source
    
    # Delete the previously-existing file if it exists
    Invoke-Command -Session $Session {
        if (Test-Path $args[0]) 
        { 
            Remove-Item $args[0] 
        }
        
        $destinationDirectory = Split-Path -LiteralPath $args[0]
        if (!(Test-Path $destinationDirectory))
        {
            New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
        }
    } -ArgumentList $Destination
    
    # Now break it into chunks to stream
    Write-Progress -Activity "Sending $Source" -Status "Preparing file"
    $streamSize = 1MB
    $position = 0
    $rawBytes = New-Object byte[] $streamSize
    $file = [IO.File]::OpenRead($sourceFile.FullName)
    while (($read = $file.Read($rawBytes, 0, $streamSize)) -gt 0)
    {
        Write-Progress -Activity "Writing $Destination" `
        -Status "Sending file" `
        -PercentComplete ($position / $sourceFile.Length * 100)
        
        # Ensure that our array is the same size as what we read from disk
        if ($read -ne $rawBytes.Length)
        {
            [Array]::Resize( [ref] $rawBytes, $read)
        }
        
        # And send that array to the remote system
        Invoke-Command -Session $session $remoteScript -ArgumentList $destination, $rawBytes
        
        # Ensure that our array is the same size as what we read from disk
        if ($rawBytes.Length -ne $streamSize)
        {
            [Array]::Resize( [ref] $rawBytes, $streamSize)
        }
        [GC]::Collect()
        $position += $read
    }
    
    $file.Close()
    
    # Show the result
    Invoke-Command -Session $session { Get-Item $args[0] } -ArgumentList $Destination
}

<#
.SYNOPSIS
   Sets the provided values in the VNet file of a subscription's VNet file 
.DESCRIPTION
   It sets the VNetSiteName and AffinityGroup of a given subscription's VNEt configuration file.
.EXAMPLE
    Set-VNetFileValues -FilePath c:\temp\servvnet.xml -VNet testvnet -AffinityGroupName affinityGroup1
.INPUTS
   None
.OUTPUTS
   None
#>
function Set-VNetFileValues
{
    [CmdletBinding()]
    param (

        # The path to the exported VNet file
        [String]$FilePath, 
        
        # Name of the new VNet site
        [String]$VNet, 
        
        # The affinity group the new Vnet site will be associated with
        [String]$AffinityGroupName, 
        
        # Address prefix for the Vnet. For the sake of examples in this scripts, the 
        # smallest address space possible for Azure is default
        [String]$VNetAddressPrefix = "10.0.0.0/8", 
        
        # The name of the subnet to be added to the Vnet
        [String] $DefaultSubnetName = "Subnet-1", 
        
        # Addres space for the Subnet
        [String] $SubnetAddressPrefix = "10.0.0.0/29")
    
    [Xml]$xml = New-Object XML
    $xml.Load($FilePath)
    $vnetSiteNodes = $xml.GetElementsByTagName("VirtualNetworkSite")
    
    $foundVirtualNetworkSite = $null
    if ($vnetSiteNodes -ne $null)
    {
        $foundVirtualNetworkSite = $vnetSiteNodes | Where-Object { $_.name -eq $VNet }
    }

    if ($foundVirtualNetworkSite -ne $null)
    {
        $foundVirtualNetworkSite.AffinityGroup = $AffinityGroupName
    }
    else
    {
        $virtualNetworkSites = $xml.NetworkConfiguration.VirtualNetworkConfiguration.GetElementsByTagName("VirtualNetworkSites")
        if ($null -ne $virtualNetworkSites)
        {
            
            $virtualNetworkElement = $xml.CreateElement("VirtualNetworkSite", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            
            $vNetSiteNameAttribute = $xml.CreateAttribute("name")
            $vNetSiteNameAttribute.InnerText = $VNet
            $virtualNetworkElement.Attributes.Append($vNetSiteNameAttribute) | Out-Null
            
            $affinityGroupAttribute = $xml.CreateAttribute("AffinityGroup")
            $affinityGroupAttribute.InnerText = $AffinityGroupName
            $virtualNetworkElement.Attributes.Append($affinityGroupAttribute) | Out-Null
            
            $addressSpaceElement = $xml.CreateElement("AddressSpace", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")            
            $addressPrefixElement = $xml.CreateElement("AddressPrefix", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $addressPrefixElement.InnerText = $VNetAddressPrefix
            $addressSpaceElement.AppendChild($addressPrefixElement) | Out-Null
            $virtualNetworkElement.AppendChild($addressSpaceElement) | Out-Null
            
            $subnetsElement = $xml.CreateElement("Subnets", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $subnetElement = $xml.CreateElement("Subnet", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $subnetNameAttribute = $xml.CreateAttribute("name")
            $subnetNameAttribute.InnerText = $DefaultSubnetName
            $subnetElement.Attributes.Append($subnetNameAttribute) | Out-Null
            $subnetAddressPrefixElement = $xml.CreateElement("AddressPrefix", "http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration")
            $subnetAddressPrefixElement.InnerText = $SubnetAddressPrefix
            $subnetElement.AppendChild($subnetAddressPrefixElement) | Out-Null
            $subnetsElement.AppendChild($subnetElement) | Out-Null
            $virtualNetworkElement.AppendChild($subnetsElement) | Out-Null
            
            $virtualNetworkSites.AppendChild($virtualNetworkElement) | Out-Null
        }
        else
        {
            throw "Can't find 'VirtualNetworkSite' tag"
        }
    }
    
    $xml.Save($FilePath)
}

<#
.Synopsis
   Create an empty VNet configuration file.
.DESCRIPTION
   Create an empty VNet configuration file.
.EXAMPLE
    Add-AzureVnetConfigurationFile -Path c:\temp\vnet.xml
.INPUTS
   None
.OUTPUTS
   None
#>
function Add-AzureVnetConfigurationFile
{
    param ([String] $Path)
    
    $configFileContent = [Xml] "<?xml version=""1.0"" encoding=""utf-8""?>
    <NetworkConfiguration xmlns:xsd=""http://www.w3.org/2001/XMLSchema"" xmlns:xsi=""http://www.w3.org/2001/XMLSchema-instance"" xmlns=""http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration"">
              <VirtualNetworkConfiguration>
                <Dns />
                <VirtualNetworkSites/>
              </VirtualNetworkConfiguration>
            </NetworkConfiguration>"
    
    $configFileContent.Save($Path)
}

<#
.SYNOPSIS
   Creates a Virtual Network Site if it does not exist and sets the subnet details.
.DESCRIPTION
   Creates the VNet site if it does not exist. It first downloads the neetwork configuration for the subscription.
   If there is no network configuration, it creates an empty one first using the Add-AzureVnetConfigurationFile helper
   function, then updates the network file with the provided Vnet settings also by adding the subnet.
.EXAMPLE
   New-VNetSiteIfNotExists -VNetSiteName testVnet -SubnetName mongoSubnet -AffinityGroupName mongoAffinity
#>
function New-VNetSiteIfNotExists
{
    [CmdletBinding()]
    param
    (

        # Name of the Vnet site
        [Parameter(Mandatory = $true)]
        [String]
        $VNetSiteName,
        
        # Name of the subnet
        [Parameter(Mandatory = $true)]
        [String]
        $SubnetName,
        
        # THe affinity group the vnet will be associated with
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Address prefix for the Vnet. For the sake of examples in this scripts, 

        # the smallest address space possible for Azure is default
        [String]$VNetAddressPrefix = "10.0.0.0/8", 
        
        # The name of the subnet to be added to the Vnet
        [String] $DefaultSubnetName = "Subnet-1", 
        
        # Addres space for the Subnet
        [String] $SubnetAddressPrefix = "10.0.0.0/29")
    
    # Check the VNet site, and add it to the configuration if it does not exist.
    $vNet = Get-AzureVNetSite -VNetName $VNetSiteName -ErrorAction SilentlyContinue
    if ($vNet -eq $null)
    {
        $vNetFilePath = "$env:temp\$AffinityGroupName" + "vnet.xml"
        Get-AzureVNetConfig -ExportToFile $vNetFilePath | Out-Null
        if (!(Test-Path $vNetFilePath))
        {
            Add-AzureVnetConfigurationFile -Path $vNetFilePath
        }
        
        Set-VNetFileValues -FilePath $vNetFilePath -VNet $vNetSiteName `
            -DefaultSubnetName $SubnetName -AffinityGroup $AffinityGroupName `
            -VNetAddressPrefix $VNetAddressPrefix -SubnetAddressPrefix $SubnetAddressPrefix

        Set-AzureVNetConfig -ConfigurationPath $vNetFilePath -ErrorAction SilentlyContinue `
            -ErrorVariable errorVariable | Out-Null
        if (!($?))
        {
            throw "Cannot set the vnet configuration for the subscription, please see the file $vNetFilePath. Error detail is: $errorVariable"
        }
        Write-Verbose "Modified and saved the VNET Configuration for the subscription"
        
        Remove-Item $vNetFilePath
    }
}

<#
.SYNOPSIS
    Adds a new affinity group if it does not exist.
.DESCRIPTION
   Looks up the current subscription's (as set by Set-AzureSubscription cmdlet) affinity groups and creates a new
   affinity group if it does not exist.
.EXAMPLE
   New-AzureAffinityGroupIfNotExists -AffinityGroupNme newAffinityGroup -Locstion "West US"
.INPUTS
   None
.OUTPUTS
   None
#>
function New-AzureAffinityGroupIfNotExists
{
    param
    (

        # Name of the affinity group
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Location where the affinity group will be pointing to
        [Parameter(Mandatory = $true)]
        [String]
        $Location)
    
    $affinityGroup = Get-AzureAffinityGroup -Name $AffinityGroupName -ErrorAction SilentlyContinue
    if ($affinityGroup -eq $null)
    {
        New-AzureAffinityGroup -Name $AffinityGroupName -Location $Location `
            -Label $AffinityGroupName -ErrorVariable lastError -ErrorAction SilentlyContinue | Out-Null
        if (!($?))
        {
            throw "Cannot create the affinity group $AffinityGroupName on $Location"
        }
        Write-Verbose "Created affinity group $AffinityGroupName"
    }
    else
    {
        if ($affinityGroup.Location -ne $Location)
        {
            Write-Warning "Affinity group with name $AffinityGroupName already exists but in location $affinityGroup.Location, not in $Location"
        }
    }
}

<#
.SYNOPSIS
   Installs a WinRm certificate to the local store
.DESCRIPTION
   Gets the WinRM certificate from the Virtual Machine in the Service Name specified, and 
   installs it on the Current User's personal store.
.EXAMPLE
    Install-WinRmCertificate -ServiceName testservice -vmName testVm
.INPUTS
   None
.OUTPUTS
   None
#>
function Install-WinRmCertificate($ServiceName, $VMName)
{
    $vm = Get-AzureVM -ServiceName $ServiceName -Name $VMName
    $winRmCertificateThumbprint = $vm.VM.DefaultWinRMCertificateThumbprint
    
    $winRmCertificate = Get-AzureCertificate -ServiceName $ServiceName `
        -Thumbprint $winRmCertificateThumbprint -ThumbprintAlgorithm sha1
    
    $installedCert = Get-Item Cert:\CurrentUser\My\$winRmCertificateThumbprint -ErrorAction SilentlyContinue
    
    if ($installedCert -eq $null)
    {
        $certBytes = [System.Convert]::FromBase64String($winRmCertificate.Data)
        $x509Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate
        $x509Cert.Import($certBytes)
        
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
        $store.Open("ReadWrite")
        $store.Add($x509Cert)
        $store.Close()
    }
}

<#
.SYNOPSIS
  Returns the latest image for a given image family name filter.
.DESCRIPTION
  Will return the latest image based on a filter match on the ImageFamilyName and
  PublisedDate of the image.  The more specific the filter, the more control you have
  over the object returned.
.EXAMPLE
  The following example will return the latest SQL Server image.  It could be SQL Server
  2014, 2012 or 2008
    
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server*"

  The following example will return the latest SQL Server 2014 image. This function will
  also only select the image from images published by Microsoft.  
   
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server 2014*" -OnlyMicrosoftImages

  The following example will return $null because Microsoft doesn't publish Ubuntu images.
   
    Get-LatestImage -ImageFamilyNameFilter "*Ubuntu*" -OnlyMicrosoftImages
#>

function Get-LatestImage
{
    param
    (
        # A filter for selecting the image family.
        # For example, "Windows Server 2012*", "*2012 Datacenter*", "*SQL*, "Sharepoint*"
        [Parameter(Mandatory = $true)]
        [String]
        $ImageFamilyNameFilter,

        # A switch to indicate whether or not to select the latest image where the publisher is Microsoft.
        # If this switch is not specified, then images from all possible publishers are considered.
        [Parameter(Mandatory = $false)]
        [switch]
        $OnlyMicrosoftImages
    )

    # Get a list of all available images.
    $imageList = Get-AzureVMImage

    if ($OnlyMicrosoftImages.IsPresent)
    {
        $imageList = $imageList |
                         Where-Object { `
                             ($_.PublisherName -ilike "Microsoft*" -and `
                              $_.ImageFamily -ilike $ImageFamilyNameFilter ) }
    }
    else
    {
        $imageList = $imageList |
                         Where-Object { `
                             ($_.ImageFamily -ilike $ImageFamilyNameFilter ) } 
    }

    $imageList = $imageList | 
                     Sort-Object -Unique -Descending -Property ImageFamily |
                     Sort-Object -Descending -Property PublishedDate

    $imageList | Select-Object -First(1)
}
# Create the affinity group
New-AzureAffinityGroupIfNotExists -AffinityGroupName $AffinityGroupName -Location $Location

# Configure the VNET
$vNetSiteName = ($ServiceName + "vnet").ToLower()
$subnetName = "mongosubnet"
New-VnetSiteIfNotExists -VNetSiteName $vNetSiteName -SubnetName $subnetName -AffinityGroupName $AffinityGroupName

$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $FrontEndHostName -ErrorAction SilentlyContinue
if ($existingVm -ne $null)
{
    throw "A VM with name $FrontEndHostName exists on $ServiceName"
}

$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $BackEndHostName -ErrorAction SilentlyContinue
if ($existingVm -ne $null)
{
    throw "A VM with name $BackEndHostName exists on $ServiceName"
}

$existingService = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue
if ($existingService -eq $null -and (Test-AzureName -Service $ServiceName))
{
    throw "The specified DNS name $ServiceName already taken"
}

# Get an image to provision virtual machines from.
$imageFamilyNameFilter = "Windows Server 2012 Datacenter"
$image = Get-LatestImage -ImageFamilyNameFilter $imageFamilyNameFilter -OnlyMicrosoftImages
if ($image -eq $null)
{
    throw "Unable to find an image for $imageFamilyNameFilter to provision Virtual Machine."
}

$vms = @()

Write-Verbose "Prompt user for administrator credentials to use when provisioning the virtual machine(s)."
$credential = Get-Credential
Write-Verbose "Administrator credentials captured.  Use these credentials to login to the virtual machine(s) when the script is complete."

# Configure the IIS Virtual Machine (FrontEnd)
$vms += New-AzureVMConfig -Name $FrontEndHostName -InstanceSize $FrontEndInstanceSize -ImageName $image.ImageName | 
            Add-AzureEndpoint -Name "http" -Protocol tcp -LocalPort 80 -PublicPort 80 | 
            Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().username -Password $credential.GetNetworkCredential().password | 
            Set-AzureSubnet -SubnetNames $subnetName

# Configure the MongoDB Virtual Machine (BackEnd)
$vms += New-AzureVMConfig -Name $BackEndHostName -InstanceSize $BackEndInstanceSize -ImageName $image.ImageName | 
            Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().username -Password $credential.GetNetworkCredential().password | 
            Add-AzureDataDisk -CreateNew -DiskSizeInGB 50 -DiskLabel "DataDrive" -LUN 0 | 
            Add-AzureDataDisk -CreateNew -DiskSizeInGB 50 -DiskLabel "LogDrive" -LUN 1 | 
            Set-AzureSubnet -SubnetNames $subnetName

if ($existingService -ne $null)
{
    New-AzureVM -ServiceName $ServiceName -VMs $vms -VNetName $vNetSiteName -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VMs."
    }
} 
else
{
    New-AzureVM -ServiceName $ServiceName -AffinityGroup $AffinityGroupName -VMs $vms -VNetName $vNetSiteName -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VMs and the cloud service $ServiceName"
    }
}

# prepare to run the remote execution

# Get the RemotePS/WinRM Uri to connect to
$frontEndwinRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $FrontEndHostName
$backEndwinRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $BackEndHostName

Install-WinRmCertificate $ServiceName $FrontEndHostName
Install-WinRmCertificate $ServiceName $BackEndHostName

$IISProductId = "IIS7"
$remoteScriptsDirectory = "c:\"
$remoteScriptFileName = "RemoteScripts.ps1"

# Copy the required files to the remote machine
$remoteSession = New-PSSession -ConnectionUri $frontEndwinRmUri.AbsoluteUri -Credential $credential
$sourcePath = "$PSScriptRoot\$remoteScriptFileName"
$destPath = $remoteScriptsDirectory + $remoteScriptFileName
Send-File $sourcePath $destPath $remoteSession
Remove-PSSession -InstanceId $remoteSession.InstanceId

# Run the install script for the IIS application
$runInstallScript = 
{
    param ([String]$IISProductId, [String]$scriptDirectory, [String]$scriptFile)
    
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    
    # Install .NET 3.5 seperately, as it fails through WebPI dependencies install
    Import-Module ServerManager
    Add-Windowsfeature -Name NET-Framework-Features | Out-Null
    Add-Windowsfeature -Name Web-Asp-Net45 | Out-Null
    
    cd $scriptDirectory
    . .\$scriptFile
    
    Install-WebPiProduct -ProductId $IISProductId
}

Write-Verbose "Running the remote IIS7 install on the front end."
Invoke-Command -ConnectionUri $frontEndwinRmUri.ToString() -Credential $credential -ScriptBlock $runInstallScript -ArgumentList @($IISProductId, $remoteScriptsDirectory, $remoteScriptFileName)

# Install MongoDB
Write-Verbose "Running the remote MongoDb install on the back end."
Invoke-Command -ConnectionUri $backEndwinRmUri.ToString() -Credential $credential -ScriptBlock {
    
    # Prepare the data drive
    Initialize-Disk -Number 2
    New-Partition -DiskNumber 2 -UseMaximumSize -DriveLetter F
    Format-Volume -DriveLetter F -FileSystem NTFS -NewFileSystemLabel "DataDisk" -Force:$true -confirm:$false
    
    # Prepare the log drive
    Initialize-Disk -Number 3
    New-Partition -DiskNumber 3 -UseMaximumSize -DriveLetter G
    Format-Volume -DriveLetter G -FileSystem NTFS -NewFileSystemLabel "Logisk" -Force:$true -confirm:$false
    
    $version = "2.4.5"
    $mongoDbInstallFolder = "F:\MongoDB"
    $logDrive = "G:"
    $configFile = "$mongoDbInstallFolder\mongod.cfg"
    
    $downloadUrl = "http://downloads.mongodb.org/win32/mongodb-win32-x86_64-2008plus-$version.zip" 
    $zipFile = "$mongoDbInstallFolder\mongo.zip" 
    $unzippedFolderContent = "$mongoDbInstallFolder\mongodb-win32-x86_64-2008plus-$version"
    
    if ((Test-Path -path $mongoDbInstallFolder) -eq $true) 
    { 
        Write-Warning "Path $mongoDbInstallFolder already exists"
    }
    
    md $mongoDbInstallFolder | Out-Null
    md "$logDrive\log" | Out-Null
    md "$mongoDbInstallFolder\data" | Out-Null
    md "$mongoDbInstallFolder\data\db" | Out-Null
    
    $configFileContent = "dbpath=$mongoDbInstallFolder\data\db`r`n"
    $configFileContent += "logpath=$logDrive\log\mongo.log`r`n"
    $configFileContent += "directoryperdb = true"
    
    $configFileContent | Out-File -Encoding ascii -FilePath $configFile
    
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile
    
    # unzip the downloaded file
    $shellApp = New-Object -com shell.application
    $destination = $shellApp.namespace($mongoDbInstallFolder)
    $destination.Copyhere($shellApp.namespace($zipFile).items())
    
    Copy-Item "$unzippedFolderContent\*" $mongoDbInstallFolder -recurse
    
    Remove-Item $unzippedFolderContent -recurse -force 
    Remove-Item $zipFile -recurse -force
    
    Start-Sleep -Seconds 20
    & $mongoDbInstallFolder\bin\mongod.exe --config $configFile --install
    
    & net start mongodb                
}
