# Requires PowerCLI

#Parameters
param (
    [ValidateRange(1,1000)]
    [Int]
    # Number of VMs to clone
    $NumberVms = 50
)

# The VM will be named with the prefix, followed by the '-###', eg 'cloned-vm-001'
$VMNamePrefix = 'cloned-vm'

#Variables - Fill out the variables for the environment you will be cloning to
$VMNumberArray = @(1..$NumberVMs)
$Template = Get-Template -Name "template01"
$Datastores = Get-Datastore | Where-Object { $_.Name -match "datastore01"}
$Cluster = Get-Cluster -Name "cluster01"
$VMHosts = $Cluster | Get-VMHost
$PortGroup = Get-VirtualPortGroup -Name "network01"
$Locations = Get-Folder | Where-Object {$_.Name -contains "folder01"}

# Clone VM
foreach ($VMNumber in $VMNumberArray) {
    # Change the VM prefix name if you want
    $VMName = "$VMNamePrefix-$(([string]$VMNumber).PadLeft(3,'0'))"
    $VMHost = ($VMHosts | Get-Random)
    $Datastore = ($Datastores | Get-Random)
    $Location = ($Locations | Get-Random)
    Write-Host "Creating VM $VMName on host $VMHost"
    New-VM -Name $VMName -Datastore $Datastore -VMHost $VMHost -Template $Template -Portgroup $PortGroup -Location $Location
}

# Power on each VM
foreach ($VMNumber in $VMNumberArray) {
    $VMName = "$VMNamePrefix-$(([string]$VMNumber).PadLeft(3,'0'))"
    Start-VM -VM $VMName
}

# If you need to get the IP of each VM after turning it on
# $vmIPList = Get-VM | Select Name, @{N="IP Address";E={@($_.guest.IPAddress[0])}} | Where-Object -Property 'Name' -match 'cloned-vm' | sort-object -property 'name'
# $vmIPList | select -Property 'IP Address'
