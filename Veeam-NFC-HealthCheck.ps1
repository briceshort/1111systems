<#
.SYNOPSIS
    A foundational toolkit script for connecting to a Veeam Backup & Replication (VBR) server
    and performing administrative tasks, including a detailed NFC health check.

.DESCRIPTION
    This script provides a reusable framework for Veeam automation. It handles the core
    requirements of any Veeam PowerShell session and includes a comprehensive health check
    function based on common NFC troubleshooting steps.
    1. Ensures the Veeam PowerShell Snap-in is loaded.
    2. Prompts for the VBR server, a vCenter Cluster, and ESXi host credentials.
    3. Establishes a connection to the specified VBR server.
    4. Runs a detailed health check against the specified cluster and its hosts, including advanced SSH checks.
    5. Gracefully disconnects from the VBR server when tasks are complete.
    6. Includes robust error handling for connectivity issues.

.PREREQUISITES
    1. This script must be run from a machine that has the Veeam Backup & Replication Console,
       VMware PowerCLI, and the Posh-SSH module installed.
       - To install Posh-SSH: Run `Install-Module Posh-SSH -Scope CurrentUser`
    2. The user running the script must have appropriate permissions in both Veeam and vCenter.
    3. SSH must be enabled on all ESXi hosts in the target cluster.

.PARAMETER VBRServer
    The hostname or IP address of the Veeam Backup & Replication server you want to connect to.

.PARAMETER ClusterName
    The name of the vCenter cluster you want to run the health check against.

.PARAMETER ESXiCredential
    Credentials for the ESXi hosts (e.g., root). This is required for advanced hostd checks via SSH.
    The script will securely prompt for this.

.EXAMPLE
    .\Veeam-Toolkit.ps1 -VBRServer my-vbr-server.local -ClusterName Production-Cluster

    [2025-08-20 16:30:00] INFO: Successfully connected to my-vbr-server.local.
    ...
    [2025-08-20 16:31:00] OK: [Advanced Hostd Check] Host esx01.local 'nfcsvc' max_memory is 100663296. Status: OK
    [2025-08-20 16:31:05] WARN: [Advanced Hostd Check] Host esx02.local 'nfcsvc' max_memory is 50331648. Status: WARN
#>

# --- SCRIPT PARAMETERS ---
param(
    [Parameter(Mandatory=$true, HelpMessage="Enter the name of the VBR server to connect to.")]
    [string]$VBRServer,

    [Parameter(Mandatory=$true, HelpMessage="Enter the name of the vCenter Cluster to check.")]
    [string]$ClusterName,

    [Parameter(Mandatory=$true, HelpMessage="Enter credentials for the ESXi hosts (e.g., root). This is for advanced hostd checks via SSH.")]
    [System.Management.Automation.PSCredential]$ESXiCredential
)

# --- FUNCTIONS ---

# Define a logging function for clean console output
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARN", "ERROR", "OK", "MANUAL")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logLine = "[$timestamp] $Level`: $Message"

    $colorMap = @{
        INFO   = "White"
        WARN   = "Yellow"
        ERROR  = "Red"
        OK     = "Green"
        MANUAL = "Cyan"
    }
    Write-Host $logLine -ForegroundColor $colorMap[$Level]
}

# --- HEALTH CHECK FUNCTION ---
function Invoke-VeeamNfcHealthCheck {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetClusterName,

        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]$Credential
    )

    Write-Log "--- Starting NFC Health Check for cluster '$TargetClusterName' ---"

    # Find the specified cluster in the Veeam infrastructure
    $cluster = Find-VBRViEntity -Name $TargetClusterName -Type Cluster
    if (-not $cluster) {
        Write-Log "Could not find a cluster with the name '$TargetClusterName'. Please check the name and try again." -Level ERROR
        return
    }

    # Get all hosts within that cluster
    $hostsInCluster = Get-VBRViHost -Parent $cluster
    if (-not $hostsInCluster) {
        Write-Log "Could not find any ESXi hosts in the cluster '$TargetClusterName'." -Level ERROR
        return
    }

    $vcenter = $cluster.Parent.Parent.Name
    Write-Log "Connecting to vCenter $vcenter to get detailed host info..."
    Connect-VIServer $vcenter -WarningAction SilentlyContinue | Out-Null

    # --- 1. Check VM Distribution ---
    $totalVMs = ($hostsInCluster | ForEach-Object { $_.GetAllVms().Count }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    $avgVmsPerHost = [math]::Round($totalVMs / $hostsInCluster.Count, 0)
    $vmDistroStatus = if ($avgVmsPerHost -gt 175) { "WARN" } else { "OK" }
    Write-Log "[Cluster VM Distribution] Average VMs per host: $avgVmsPerHost. Status: $vmDistroStatus" -Level $vmDistroStatus
    if ($vmDistroStatus -eq "WARN") {
        Write-Log " -> Recommendation: Average VM count is high. Check for Large VCCR environment standards."
    }

    # --- 2. Check VCCR Proxies ---
    $proxies = Get-VBRBackupProxy
    foreach ($host in $hostsInCluster) {
        $proxiesOnHost = $proxies | Where-Object { $_.HostId -eq $host.Id }
        $proxyCount = $proxiesOnHost.Count
        $proxyStatus = if ($proxyCount -gt 2) { "WARN" } else { "OK" }
        Write-Log "[Proxy Distribution] Host $($host.Name) has $proxyCount proxies. Status: $proxyStatus" -Level $proxyStatus
        if ($proxyStatus -eq "WARN") {
            Write-Log " -> Recommendation: More than 2 proxies on a single host can cause contention."
        }
        
        foreach($proxy in $proxiesOnHost){
            if($proxy.Type -ne "Network"){
                Write-Log "[Proxy $($proxy.Name)] Transport mode is '$($proxy.Type)'. Should be 'Network'." -Level WARN
            }
        }
    }
    Write-Log "[Proxy Hot-Add Drives] Please manually check proxies for lingering hot-added disks." -Level MANUAL


    # --- 3. Check each ESXi host ---
    $powerCliHosts = Get-VMHost -Name ($hostsInCluster.Name)
    $firstHostBuild = ($powerCliHosts | Select-Object -First 1).Build
    foreach ($host in $powerCliHosts) {
        # Check ESXi Version consistency
        if($host.Build -ne $firstHostBuild){
            Write-Log "[Host Version] Host $($host.Name) is on build $($host.Build), which differs from other hosts ($firstHostBuild)." -Level WARN
        }

        # Check Uptime
        $uptimeDays = [math]::Round((New-TimeSpan -Start $host.ExtensionData.Summary.Runtime.BootTime -End (Get-Date)).TotalDays, 0)
        $uptimeStatus = if($uptimeDays -gt 90){"WARN"}else{"OK"}
        Write-Log "[Host Uptime] Host $($host.Name) uptime is $uptimeDays days. Status: $uptimeStatus" -Level $uptimeStatus
        if($uptimeStatus -eq "WARN"){
             Write-Log " -> Recommendation: Host uptime exceeds 90 days. Consider a rolling reboot of the cluster."
        }
    }
    Write-Log "[Host Health] Please manually check host health (CPU/Mem), datastore paths, and hardware status in vCenter/UCS." -Level MANUAL


    # --- 4. Large VCCR Environment Standards Check ---
    if ($avgVmsPerHost -gt 175) {
        Write-Log "High VM count detected. Checking for Large VCCR standards..."
        foreach ($host in $powerCliHosts) {
            $maxCapacity = Get-AdvancedSetting -Entity $host -Name "BufferCache.MaxCapacity"
            $flushInterval = Get-AdvancedSetting -Entity $host -Name "BufferCache.FlushInterval"
            if($maxCapacity.Value -ne 32768){
                Write-Log "[Large Env Check] Host $($host.Name) BufferCache.MaxCapacity is $($maxCapacity.Value) (should be 32768)." -Level WARN
            }
            if($flushInterval.Value -ne 20000){
                Write-Log "[Large Env Check] Host $($host.Name) BufferCache.FlushInterval is $($flushInterval.Value) (should be 20000)." -Level WARN
            }
        }
    }
    Write-Log "[VBR Registry] Please manually confirm required registry keys exist on the VBR server." -Level MANUAL

    # --- 5. Advanced Host Configuration Check (SSH) ---
    Write-Log "Starting advanced hostd memory check via SSH..."
    foreach ($host in $powerCliHosts) {
        $sshSession = $null
        try {
            $sshSession = New-SSHSession -ComputerName $host.Name -Credential $Credential -ErrorAction Stop
            # FIX: Simplified the grep pattern to avoid PowerShell parsing errors with nested quotes.
            $command = "/bin/configstorecli config current get -c esx -g services -k hostd | grep 'max_memory'"
            $sshResult = Invoke-SSHCommand -SSHSession $sshSession -Command $command
            
            $output = $sshResult.Output
            $regex = '"max_memory": (\d+)'
            if ($output -match $regex) {
                $currentValue = [long]$matches[1]
                # Recommended value is 100663296 (100MB) or higher
                if ($currentValue -lt 100663296) {
                    Write-Log "[Advanced Hostd Check] Host $($host.Name) 'nfcsvc' max_memory is $currentValue. Status: WARN" -Level WARN
                    Write-Log " -> Recommendation: Value is below the recommended 100MB. Consider increasing it."
                } else {
                    Write-Log "[Advanced Hostd Check] Host $($host.Name) 'nfcsvc' max_memory is $currentValue. Status: OK" -Level OK
                }
            } else {
                Write-Log "[Advanced Hostd Check] Could not parse max_memory value for host $($host.Name)." -Level WARN
            }
        } catch {
            Write-Log "[Advanced Hostd Check] Failed to connect or run command on host $($host.Name) via SSH. Error: $($_.Exception.Message)" -Level ERROR
        } finally {
            if ($sshSession) { Remove-SSHSession -SSHSession $sshSession -Confirm:$false }
        }
    }

    # --- 6. SQL and Storage ---
    Write-Log "[Storage & SQL] Please manually check Storage IOPS/Latency and SQL Database health/maintenance plans." -Level MANUAL

    Write-Log "--- Health Check Complete ---"
    Disconnect-VIServer $vcenter -Confirm:$false | Out-Null
}


# --- MAIN SCRIPT BODY ---

# Global variable to hold the VBR connection session
$global:VBRConnection = $null

try {
    # Step 1: Ensure the Veeam and VMware modules are loaded
    if (-not (Get-PSSnapin -Name "VeeamPSSnapIn" -ErrorAction SilentlyContinue)) {
        Write-Log "Veeam PSSnapin not found, attempting to add it."
        Add-PSSnapin -Name "VeeamPSSnapIn"
    } else {
        Write-Log "Veeam PSSnapin is already loaded."
    }
    if (-not (Get-Module -Name "VMware.PowerCLI" -ListAvailable)) {
        Write-Log "VMware PowerCLI module not found. Please install it by running 'Install-Module VMware.PowerCLI -Scope CurrentUser'." -Level ERROR
        throw "VMware PowerCLI is required for detailed host checks."
    }
    if (-not (Get-Module -Name "Posh-SSH" -ListAvailable)) {
        Write-Log "Posh-SSH module not found. Please install it by running 'Install-Module Posh-SSH -Scope CurrentUser'." -Level ERROR
        throw "Posh-SSH module is required for advanced host checks."
    }

    # Step 2: Connect to the specified VBR Server
    Write-Log "Attempting to connect to VBR server: $VBRServer..."
    $global:VBRConnection = Connect-VBRServer -Server $VBRServer
    
    if ($global:VBRConnection) {
        Write-Log "Successfully connected to $VBRServer."
    } else {
        throw "Failed to establish a connection object for $VBRServer."
    }

    # Step 3: Execute your custom tasks
    # ---------------------------------------------------------
    Invoke-VeeamNfcHealthCheck -TargetClusterName $ClusterName -Credential $ESXiCredential
    # ---------------------------------------------------------

} catch {
    # Catch any errors that occurred during connection or task execution
    Write-Log "An error occurred: $($_.Exception.Message)" -Level "ERROR"
} finally {
    # Step 4: Gracefully disconnect from the server
    if ($global:VBRConnection) {
        Write-Log "Disconnecting from $VBRServer."
        Disconnect-VBRServer -Server $global:VBRConnection -Confirm:$false
    }
}
