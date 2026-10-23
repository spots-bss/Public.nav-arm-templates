param
(
    # Skip the confirmation and wait for the Docker service (used by the scheduled task at startup)
    [switch] $unattended,
    # Start the installed GitHub runner / DevOps agent services after a successful cleanup
    [switch] $startAgents
)

$ErrorActionPreference = "Stop"
$WarningActionPreference = "Stop"

if ($unattended) {
    Start-Transcript -Path "c:\CleanupAfterDocker.log"
}

# Specify which images to download
$ImagesToDownload = @()

$bcContainerHelperFolder = "C:\ProgramData\BcContainerHelper"

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
    throw "This script must run with administrator privileges"
}

Write-Host "Checking Docker Service Settings..."
$dockerService = (Get-Service docker -ErrorAction Ignore)
if (!($dockerService)) {
    throw "Docker Service not found / Docker is not installed"
}

if ($unattended) {
    # At startup the Docker service might not be running yet
    $timeout = (Get-Date).AddMinutes(5)
    while ($dockerService.Status -ne "Running" -and (Get-Date) -lt $timeout) {
        Start-Sleep -Seconds 10
        $dockerService.Refresh()
    }
}

if ($dockerService.Status -ne "Running") {
    throw "Docker Service is $($dockerService.Status) (Needs to be running)"
}

$dockerInfo = (docker info)
$dockerOsMode = ($dockerInfo | Where-Object { $_.Trim().StartsWith('OSType: ') }).Trim().SubString(8)
if ($dockerOsMode -ne "Windows") {
    throw "Docker is not running Windows Containers"
}

$dockerRootDir = ($dockerInfo | Where-Object { $_.Trim().StartsWith('Docker Root Dir: ') }).Trim().SubString(17)
if (!(Test-Path $dockerRootDir -PathType Container)) {
    throw "Folder $dockerRootDir does not exist"
}

Write-Host -Foregroundcolor Red "This function will remove all containers, remove all images and clear the folder $dockerRootDir"
Write-Host -Foregroundcolor Red "The function will also clear the contents of $bcContainerHelperFolder."
Write-Host -Foregroundcolor Red "Are you absolutely sure you want to do this? (This cannot be undone)"
if (!$unattended) {
    Write-Host -ForegroundColor Red "Type Yes to continue:" -NoNewline
    if ((Read-Host) -ne "Yes") {
        throw "Mission aborted"
    }
}

Write-Host "Running Docker System Prune"
docker system prune -f

Write-Host "Removing all containers (forced)"
docker ps -a -q | % { docker rm $_ -f 2> NULL }

Write-Host "Stopping Docker Service"
stop-service docker

# A failing Docker-Ci-Zap does not fail the cleanup
try {
    Write-Host "Downloading Docker-Ci-Zap"
    $dockerCiZapExe = Join-Path $Env:TEMP "docker-ci-zap.exe"
    Remove-Item $dockerCiZapExe -Force -ErrorAction Ignore
    (New-Object System.Net.WebClient).DownloadFile("https://github.com/moby/docker-ci-zap/raw/master/docker-ci-zap.exe", $dockerCiZapExe)
    Unblock-File -Path $dockerCiZapExe

    Write-Host "Running Docker-Ci-Zap on $dockerRootDir"
    Write-Host -ForegroundColor Yellow "Note: If this fails, please restart your computer and run this script again"
    & $dockerCiZapExe -folder $dockerRootDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host -ForegroundColor Yellow "Docker-Ci-Zap failed with exit code $LASTEXITCODE"
    }

    Write-Host "Removing Docker-Ci-Zap"
    Remove-Item $dockerCiZapExe -Force -ErrorAction Ignore
}
catch {
    Write-Host -ForegroundColor Yellow "Docker-Ci-Zap failed: $($_.Exception.Message)"
}

Write-Host "Starting Docker Service"
Start-Service docker

if (Test-Path $bcContainerHelperFolder -PathType Container) {
    Write-Host "Cleaning up $bcContainerHelperFolder"
    Get-ChildItem $bcContainerHelperFolder -Force | ForEach-Object { 
        Remove-Item $_.FullName -Recurse -force
    }
}

if ($ImagesToDownload) {
    Write-Host -ForegroundColor Green "Done cleaning up, pulling images for $os"

    $os = "ltsc2016"
    if ((Get-CimInstance win32_operatingsystem).BuildNumber -ge 17763) { $os = "ltsc2019" }
    
    # Download images needed
    $imagesToDownload | ForEach-Object {
        if ($_.EndsWith('-ltsc2016') -or $_.EndsWith('-1709') -or $_.EndsWith('-1803') -or $_.EndsWith('-ltsc2019') -or
            $_.EndsWith(':ltsc2016') -or $_.EndsWith(':1709') -or $_.EndsWith(':1803') -or $_.EndsWith(':ltsc2019')) {
            $imageName = $_
        } elseif ($_.Contains(':')) {
            $imageName = "$($_)-$os"
        } else {
            $imageName = "$($_):$os"
        }
        Write-Host "Pulling $imageName"
        docker pull $imageName
    }
}

if ($startAgents) {
    # GitHub runner services are named actions.runner.*, Azure DevOps agent services vstsagent.*
    Get-Service -Name "actions.runner.*", "vstsagent.*" -ErrorAction Ignore | ForEach-Object {
        Write-Host "Starting agent service $($_.Name)"
        Start-Service -Name $_.Name
    }
}
