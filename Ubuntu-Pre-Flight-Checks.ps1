#Requires -Version 5.1

<#
.SYNOPSIS
    A PowerShell script to perform pre-flight checks and preparation on Ubuntu hosts before an OS upgrade.

.DESCRIPTION
    This script SSHes into a list of provided Ubuntu hosts to perform a series of cleanup
    and package preparation steps. It handles the removal of problematic packages and ensures
    the system is in a clean state, ready for a manual 'do-release-upgrade'.

.WARNING
    THIS SCRIPT MAKES CHANGES TO YOUR SYSTEM'S PACKAGES AND CONFIGURATION.
    ALWAYS TEST ON NON-PRODUCTION SYSTEMS FIRST.
    ENSURE YOU HAVE FULL BACKUPS OR SNAPSHOTS BEFORE PROCEEDING.
    The script passes the sudo password via stdin, which can be a security risk on shared systems.
#>

# --- Check for SSH Prerequisite ---
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Write-Host "FATAL: ssh.exe was not found. Please install the OpenSSH client and ensure it is in your PATH." -ForegroundColor Red
    exit 1
}

# --- Gather User Input ---
Write-Host "This script will perform pre-flight checks on Ubuntu hosts for an OS upgrade." -ForegroundColor Yellow
Write-Host "Please ensure you have backups of all target systems before proceeding." -ForegroundColor Yellow
Write-Host ""

$credential = Get-Credential -Message "Enter the credentials for the Ubuntu hosts"
$username = $credential.UserName
$password = $credential.GetNetworkCredential().Password

$serverList = Read-Host -Prompt "Enter a comma-separated list of server hostnames or IPs"
$servers = $serverList.Split(',').Trim()

# --- Main Processing Loop ---
foreach ($server in $servers) {
    Write-Host "------------------------------------------------------------"
    Write-Host "Starting pre-flight check for server: $server" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    try {
        # --- Define the sequence of preparation commands ---
        # Note: We use 'DEBIAN_FRONTEND=noninteractive' to help prevent prompts from apt.
        # The 'sudo -S' command reads the password from the standard input pipe.
        $prepCommands = @"
        echo 'Step 1: Running initial package updates and upgrades...'
        export DEBIAN_FRONTEND=noninteractive
        sudo -S apt-get update
        sudo -S apt-get upgrade -y

        echo 'Step 2: Removing LXD and Snapd to prevent upgrade issues...'
        sudo -S snap remove --purge lxd
        sudo -S apt-get remove --purge lxd snapd -y
        sudo -S apt-get purge lxd lxd-client -y

        echo 'Step 3: Removing potentially problematic repository files...'
        sudo -S rm -f /etc/apt/sources.list.d/saltstack.list

        echo 'Step 4: Reconfiguring any broken packages...'
        sudo -S dpkg --configure -a

        echo 'Step 5: Running dist-upgrade and autoremove...'
        sudo -S apt-get dist-upgrade -y
        sudo -S apt-get autoremove -y
"@

        # --- Execute Preparation Commands ---
        Write-Host "[$server] Executing preparation and cleanup commands..." -ForegroundColor Green
        # Use a shorter timeout for the prep commands
        $prepSshCommand = "echo '$password' | ssh -o ConnectTimeout=120 -o StrictHostKeyChecking=no -l $username $server -- $prepCommands"
        $prepResult = Invoke-Expression -Command $prepSshCommand
        Write-Host $prepResult
    }
    catch {
        Write-Host "An error occurred while processing $server. See details below." -ForegroundColor Red
        Write-Error $_.Exception.Message
    }

    Write-Host "Finished pre-flight check for server: $server" -ForegroundColor Cyan
    Write-Host ""
}

Write-Host "============================================================"
Write-Host "All specified servers have been processed." -ForegroundColor Magenta
Write-Host "============================================================"
