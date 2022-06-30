# This script will bulk set the consistency level of a VM

# Get a list of Nutanix VMs
# For VMware, use "Get-RubrikVM"
$vms = Get-RubrikNutanixVM

# Specify the SLA that you want to set the consistency for
$sla = '1d-30d-NoArchive'

# Consistency levels: Automatic, ApplicationConsistent, CrashConsistent
$consistency = 'ApplicationConsistent'

foreach($vm in $vms)
{
  if($vm.effectiveSlaDomainName -eq $sla)
  {
    Write-Host "$($vm.name)" -foregroundcolor green
    Write-Host "Current Consistency - $($vm.snapshotConsistencyMandate)"
    # For VMWare use 'Set-RubrikVM'
    Set-RubrikNutanixVM -id $vm.id -SnapConsistency $consistency -confirm:0 | out-null
    $newVM = Get-RubrikNutanixVM -id $vm.id
    Write-Host "New Consistency - $($newVM.snapshotConsistencyMandate)"
    Write-Host ""
  }
}
