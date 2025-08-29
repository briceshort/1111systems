#Requires -Version 5.1

<#
.SYNOPSIS
    A PowerShell script to test SSH connectivity and sudo authentication on Ubuntu hosts.

.DESCRIPTION
    This script SSHes into a list of provided Ubuntu hosts to verify that the connection
    can be established and that the provided credentials have password-based sudo access.
    It runs a non-destructive command ('whoami') and reports success or failure for each host.
    NO CHANGES ARE MADE TO THE TARGET SYSTEMS.

.WARNING
    The script passes the sudo password via stdin, which can be a security risk on shared systems.
#>

# --- Check for SSH Prerequisite ---
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Write-Host "FATAL: ssh.exe was not found. Please install the OpenSSH client and ensure it is in your PATH." -ForegroundColor Red
    exit 1
}

# --- Gather User Input ---
Write-Host "This script will test SSH connections and sudo credentials on Ubuntu hosts." -ForegroundColor Yellow
Write-Host "NO CHANGES will be made to the target systems." -ForegroundColor Yellow
Write-Host ""

$credential = Get-Credential -Message "Enter the credentials for the Ubuntu hosts"
$username = $credential.UserName
$password = $credential.GetNetworkCredential().Password

$serverList = Read-Host -Prompt "Enter a comma-separated list of server hostnames or IPs"
$servers = $serverList.Split(',').Trim()

# --- Main Processing Loop ---
foreach ($server in $servers) {
    Write-Host "------------------------------------------------------------"
    Write-Host "Testing connection to server: $server" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"

    try {
        # --- Define the non-destructive test command ---
        # We use 'sudo -S whoami' to test the password without making any changes.
        # The '-S' flag tells sudo to read the password from standard input.
        $testCommand = "sudo -S whoami"

        # --- Execute the Test Command ---
        Write-Host "[$server] Attempting to connect and authenticate..." -ForegroundColor Green
        
        # Use a short timeout as we are just testing the connection.
        $sshTestCommand = "echo '$password' | ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=no -l $username $server -- $testCommand"
        
        # Execute the command and capture all output streams (success and error)
        $testResult = Invoke-Expression -Command $sshTestCommand 2>&1
        
        # --- Analyze the Result ---
        if ($LASTEXITCODE -ne 0) {
            # This block catches errors from SSH itself or from the sudo command failing
            if ($testResult -like "*sudo: 1 incorrect password attempt*") {
                 Write-Host "[$server] FAILED: Connection succeeded, but sudo authentication failed. Please check the password." -ForegroundColor Red
            } else {
                 Write-Host "[$server] FAILED: An error occurred during the SSH command. Output below:" -ForegroundColor Red
                 Write-Host $testResult
            }
        } else {
            # Success
            Write-Host "[$server] SUCCESS: Connected and authenticated successfully. Sudo user: $($testResult.Trim())" -ForegroundColor Cyan
        }
    }
    catch {
        # This block catches errors from PowerShell's Invoke-Expression, usually connection timeouts or host not found.
        Write-Host "[$server] FAILED: Could not establish an SSH connection. Please check the hostname, network, and firewall rules." -ForegroundColor Red
        Write-Error $_.Exception.Message
    }

    Write-Host "Finished testing server: $server"
    Write-Host ""
}

Write-Host "============================================================"
Write-Host "All specified servers have been tested." -ForegroundColor Magenta
Write-Host "============================================================"

