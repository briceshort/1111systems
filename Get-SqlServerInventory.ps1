<#
.SYNOPSIS
    Gathers disk space information for the S: drive and the largest database size
    from a list of SQL servers defined by an Active Directory (AD) container and naming scheme.

.DESCRIPTION
    This script is designed for SQL Server administrators to quickly inventory their servers.
    It performs the following actions:
    1. Prompts the user for the Active Directory container path and a server name filter.
    2. Queries that container for computer objects that match the given naming pattern.
    3. For each server found, it remotely queries for the total size and used space of the S: drive.
    4. It then connects to the default SQL Server instance on each server to find the name
       and size of the largest database.
    5. It displays a consolidated table in the console and exports the full results to a
       timestamped CSV file in the same directory as the script.

.PREREQUISITES
    1. PowerShell 5.1 or later.
    2. The script must be run from a machine that has the Active Directory and SqlServer modules installed.
       - To install the AD module: Install the "RSAT: Active Directory Domain Services and Lightweight Directory Services Tools" via Windows Features.
       - To install the SQL module: Run `Install-Module -Name SqlServer -Scope CurrentUser` in PowerShell.
    3. The user running the script needs:
       - Read permissions in the target Active Directory OU.
       - Local administrator rights on the target SQL servers (to query disk space via WMI/CIM).
       - At least the 'VIEW ANY DATABASE' permission on the SQL Server instances (typically granted by the 'public' role).
    4. For remote disk queries, RPC ports must be accessible between the machine running the script and the target servers.

.PARAMETER ADContainerPath
    The Distinguished Name (DN) of the Active Directory OU where the server objects are located.
    The script will prompt for this value.

.PARAMETER ServerNameFilter
    A filter string used to find servers by name. It supports wildcards (e.g., '*-vsql*').
    The script will prompt for this value.

.EXAMPLE
    .\Get-SqlServerInventory.ps1

    cmdlet Get-SqlServerInventory.ps1 at command pipeline position 1
    Supply values for the following parameters:
    ADContainerPath: OU=SQL Servers,OU=Servers,DC=corp,DC=localhost
    ServerNameFilter: *-vsql01*

    ServerName              SDriveSizeGB SDriveUsedGB LargestDbName   LargestDbSizeGB
    ----------              ------------ ------------ -------------   ---------------
    res22-vsql01-01.localhost       512.00       150.75 StagingDB            117.58
#>

# --- SCRIPT PARAMETERS ---
param(
    [Parameter(Mandatory=$true, HelpMessage="Enter the Distinguished Name of the AD OU (e.g., 'OU=Servers,DC=yourdomain,DC=local')")]
    [string]$ADContainerPath,

    [Parameter(Mandatory=$true, HelpMessage="Enter the server name filter with wildcards (e.g., '*-vsql*')")]
    [string]$ServerNameFilter
)

# --- SCRIPT BODY ---

# Import necessary modules. The script will show an error if they are not present.
Import-Module ActiveDirectory
Import-Module SqlServer

Write-Host "Starting script. Searching for servers in '$ADContainerPath' matching '$ServerNameFilter'..." -ForegroundColor Cyan

# Array to hold the results
$results = @()

try {
    # Get the list of servers from the specified AD container
    $servers = Get-ADComputer -Filter "Name -like '$ServerNameFilter'" -SearchBase $ADContainerPath | Select-Object -ExpandProperty Name

    if (-not $servers) {
        Write-Warning "No servers found in the specified AD container matching the filter. Please check your parameters."
        return
    }

    Write-Host "Found $($servers.Count) servers. Now gathering information..." -ForegroundColor Green

    # Loop through each server to gather information
    foreach ($server in $servers) {
        Write-Host "Processing: $server"

        try {
            # --- Get S: Drive Information ---
            # Using Get-WmiObject as it relies on DCOM/RPC and can work even if WinRM is blocked.
            $driveInfo = Get-WmiObject -ClassName Win32_LogicalDisk -ComputerName $server -Filter "DeviceID='S:'" -ErrorAction Stop

            if ($driveInfo) {
                $sDriveSizeGB = [math]::Round($driveInfo.Size / 1GB, 2)
                $sDriveFreeGB = [math]::Round($driveInfo.FreeSpace / 1GB, 2)
                $sDriveUsedGB = $sDriveSizeGB - $sDriveFreeGB
            } else {
                Write-Warning "S: drive not found on $server."
                $sDriveSizeGB = "N/A"
                $sDriveUsedGB = "N/A"
            }

            # --- Get Largest Database Information ---
            # T-SQL query to get all database sizes, sorted largest to smallest. We take the first result.
            $sqlQuery = @"
            SELECT TOP 1
                DB.name AS [DatabaseName],
                CAST( (SUM(MF.size) * 8.0 / 1024.0) AS DECIMAL(10, 2) ) AS [Size_MB]
            FROM
                sys.master_files MF
            INNER JOIN
                sys.databases DB ON DB.database_id = MF.database_id
            WHERE
                DB.database_id > 4 -- Exclude system databases (master, model, msdb, tempdb)
            GROUP BY
                DB.name
            ORDER BY
                [Size_MB] DESC;
"@

            # Execute the query against the server's default instance
            # Added -TrustServerCertificate to handle common SSL connection errors
            $dbInfo = Invoke-Sqlcmd -ServerInstance $server -Query $sqlQuery -QueryTimeout 60 -TrustServerCertificate

            if ($dbInfo) {
                $largestDbName = $dbInfo.DatabaseName
                $largestDbSizeGB = [math]::Round($dbInfo.Size_MB / 1024, 2)
            } else {
                Write-Warning "Could not retrieve database information from $server or no user databases found."
                $largestDbName = "N/A"
                $largestDbSizeGB = 0 # Use 0 for sorting purposes
            }

            # --- Create a custom object with the collected data ---
            $object = [PSCustomObject]@{
                ServerName        = $server
                SDriveSizeGB      = $sDriveSizeGB
                SDriveUsedGB      = $sDriveUsedGB
                LargestDbName     = $largestDbName
                LargestDbSizeGB   = $largestDbSizeGB
            }

            # Add the object to our results array
            $results += $object

        } catch {
            Write-Error "Failed to process server '$server'. Error: $_"
        }
    }

    # --- Display and Export Final Report ---
    if ($results) {
        # Sort the results once to be used for both display and export
        $sortedResults = $results | Sort-Object -Property LargestDbSizeGB -Descending

        Write-Host "`n--- Inventory Report (Console) ---`n" -ForegroundColor Green
        $sortedResults | Format-Table -AutoSize

        # --- Export to CSV ---
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $filePath = "$PSScriptRoot\SqlServerInventory-$timestamp.csv"
        $sortedResults | Export-Csv -Path $filePath -NoTypeInformation

        Write-Host "`nReport successfully exported to:" -ForegroundColor Green
        Write-Host $filePath
    } else {
        Write-Warning "Script finished, but no data was collected."
    }

} catch {
    Write-Error "A critical error occurred. Error: $_"
    Write-Error "Please ensure the ActiveDirectory module is available and your ADContainerPath is correct."
}