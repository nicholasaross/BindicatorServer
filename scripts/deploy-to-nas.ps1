#Requires -Version 5.1
<#
.SYNOPSIS
    Build, ship, and install the Bindicator Docker image onto a Synology NAS over SSH.

.DESCRIPTION
    Run this on the Windows dev box. It:
      1. builds  bindicator:latest  (linux/amd64 — the DS218+/Celeron arch),
      2. saves it to a tarball,
      3. scp's the tarball to the NAS,
      4. `docker load`s it on the NAS over ssh (via sudo), removing the tarball after.
    With -Start it also writes a prebuilt-image compose, copies it, and runs
    `docker compose up -d` on the NAS. The compose bind-mounts <RemoteDir>/data to
    /data so the scraped schedule persists across container/host restarts.

.PREREQUISITES
    Dev box : Docker Desktop running; the Windows OpenSSH client (ssh/scp — built in).
    NAS     : SSH enabled (Control Panel > Terminal & SNMP > Enable SSH service);
              Container Manager installed; an *administrator* account (docker runs via sudo).
              For -Start: docker-compose (v1) or `docker compose` (v2) on the NAS - the script
              auto-detects, preferring v1 (the Synology default); override with -ComposeCmd.

.EXAMPLE
    # Build, copy, and load the image (then create/start it yourself in Container Manager):
    .\scripts\deploy-to-nas.ps1 -NasHost 192.168.1.50 -NasUser admin

.EXAMPLE
    # Full one-shot: also copy compose and start the stack:
    .\scripts\deploy-to-nas.ps1 -NasHost 192.168.1.50 -NasUser admin -Start

.EXAMPLE
    # Re-deploy without rebuilding, using an SSH key, on a non-default port:
    .\scripts\deploy-to-nas.ps1 -NasHost nas.local -NasUser admin -SkipBuild -SshKey ~\.ssh\id_ed25519 -SshPort 2222
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $NasHost,                 # NAS IP or hostname
    [Parameter(Mandatory)] [string] $NasUser,                 # a NAS administrator account
    [string] $RemoteDir = "/volume1/docker/bindicator",       # working dir on the NAS
    [string] $ImageTag  = "bindicator:latest",
    [int]    $SshPort   = 22,
    [string] $SshKey,                                         # optional private key path (ssh -i)
    [string] $DockerCmd = "docker",                           # left as "docker" => auto-resolve the path on the NAS; else use this exact path
    [string] $ComposeCmd = "",                                # -Start only: blank => auto-detect docker-compose (v1) / `docker compose` (v2); else this exact command
    [int]    $HostPort = 8000,                                # -Start only: NAS host port to publish (container serves :8000 internally) - use a free one
    [string] $Uprn = "200001920678",                          # -Start only: UPRN (property id) in the NAS compose
    [int]    $RefreshHours = 12,                              # -Start only: REFRESH_HOURS in the NAS compose
    [string] $TimeZone  = "Europe/London",                    # -Start only: TZ in the NAS compose
    [switch] $SkipBuild,                                      # reuse the existing local image
    [switch] $Start                                           # also copy compose and `docker compose up -d`
)

$ErrorActionPreference = "Stop"
# Keep our explicit $LASTEXITCODE checks authoritative across PowerShell versions.
Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Script -ErrorAction SilentlyContinue

$repoRoot  = Split-Path -Parent $PSScriptRoot
$localTar  = Join-Path $env:TEMP "bindicator-image.tar"
$remoteTar = "$RemoteDir/bindicator-image.tar"
$target    = "${NasUser}@${NasHost}"

# ssh uses -p for the port, scp uses -P; -i (key) is optional for both.
# scp -O forces the legacy SCP protocol: Synology's sshd usually omits the SFTP subsystem that
# modern scp defaults to, which otherwise fails with "subsystem request failed on channel 0".
$sshOpts = @("-p", "$SshPort"); $scpOpts = @("-O", "-P", "$SshPort")
if ($SshKey) { $sshOpts += @("-i", $SshKey); $scpOpts += @("-i", $SshKey) }

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Assert-Ok($what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)." } }
function Write-LfFile($path, $content) { [IO.File]::WriteAllText($path, ($content -replace "`r`n", "`n")) }

# --- 0. Preflight ----------------------------------------------------------------------
Step "Checking the local Docker daemon..."
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker CLI not found. Install Docker Desktop (https://docs.docker.com/desktop/) and ensure it's on PATH."
}
# Query the server version. When the daemon is down this exits non-zero and writes a noisy
# "cannot connect" error to stderr - capture both streams so we can show a clean, actionable
# message instead of a stack of pipe/handle errors.
$dockerInfo = & docker version --format 'server {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw @"
Docker daemon not reachable - is Docker Desktop running?

  Start Docker Desktop, wait for the whale icon to stop animating (status "running"),
  then re-run this script. On a cold start the engine can take 30-60s to accept connections.

(docker reported: $($dockerInfo -join ' '))
"@
}
Write-Host "    $dockerInfo"
foreach ($c in 'ssh', 'scp') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        throw "$c not found. Install the Windows OpenSSH client (Settings > Optional features)."
    }
}

# --- 1. Build --------------------------------------------------------------------------
if ($SkipBuild) {
    Step "Skipping build; using the existing $ImageTag."
    docker image inspect $ImageTag *> $null
    if ($LASTEXITCODE -ne 0) { throw "$ImageTag not found locally; run without -SkipBuild." }
}
else {
    Step "Building $ImageTag (linux/amd64)..."
    # --provenance=false => a plain single-arch image, so `docker save`/`load` stays clean on
    # whatever Docker version the NAS runs (attestation manifests can trip older daemons).
    docker build --platform linux/amd64 --provenance=false -t $ImageTag $repoRoot
    Assert-Ok "docker build"
}

# --- 2. Save ---------------------------------------------------------------------------
Step "Saving $ImageTag to a tarball..."
docker save $ImageTag -o $localTar
Assert-Ok "docker save"
$tarMB = [int]((Get-Item $localTar).Length / 1MB)
Write-Host "    tarball: $tarMB MB"

# --- 3. Copy to the NAS ----------------------------------------------------------------
Step "Creating $RemoteDir on $NasHost ..."
ssh @sshOpts $target "mkdir -p '$RemoteDir'"
Assert-Ok "ssh mkdir (check SSH is enabled and the account/credentials)"

Step "Copying the image tarball to $NasHost (~$tarMB MB)..."
scp @scpOpts $localTar "${target}:$remoteTar"
Assert-Ok "scp (image tarball)"

if ($Start) {
    # Compose for the NAS: references the loaded image (no `build:`), publishes :8000, and
    # bind-mounts ./data -> /data so the scraped schedule survives restarts. shm_size keeps
    # headless Chromium from crashing on Docker's default 64MB /dev/shm. Written with LF
    # endings for the Linux host.
    $composeTmp = Join-Path $env:TEMP "bindicator-compose.nas.yml"
    # `version` is kept for Synology's docker-compose v1 (older parsers want it); v2 ignores it.
    Write-LfFile $composeTmp @"
version: "3.8"
services:
  bindicator:
    image: $ImageTag
    container_name: bindicator
    restart: unless-stopped
    ports:
      - "${HostPort}:8000"
    environment:
      - UPRN=$Uprn
      - REFRESH_HOURS=$RefreshHours
      - TZ=$TimeZone
      - CACHE_FILE=/data/collections.json
    volumes:
      - ./data:/data
    # Chromium needs /dev/shm larger than Docker's default 64MB.
    shm_size: "256m"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
"@

    Step "Copying compose to $RemoteDir ..."
    scp @scpOpts $composeTmp "${target}:$RemoteDir/docker-compose.yml"; Assert-Ok "scp (compose)"
    Remove-Item $composeTmp -ErrorAction SilentlyContinue
}

# --- 4. Install (and optionally start) on the NAS --------------------------------------
# sudo on Synology resets PATH (secure_path) and can't see `docker`/`docker-compose`, so we
# resolve their full paths in the remote shell and call `sudo <full-path>`. Synology also
# usually has docker-compose v1 (hyphenated), NOT the `docker compose` v2 plugin, so compose
# is resolved separately (v1 first, v2 fallback). One ssh -t session: -t gives sudo a TTY and
# caches its credentials across the &&-chained commands (prompted at most once).

# Resolve the docker binary into $D (or set it to the caller-supplied -DockerCmd).
if ($DockerCmd -eq 'docker') {
    $resolveD = 'D=$(for p in /usr/local/bin/docker ' +
        '/var/packages/ContainerManager/target/usr/bin/docker ' +
        '/var/packages/Docker/target/usr/bin/docker; do [ -x "$p" ] && { echo "$p"; break; }; done); ' +
        '[ -z "$D" ] && D=$(command -v docker); ' +
        '[ -z "$D" ] && { echo "docker not found on the NAS - re-run with -DockerCmd <path>" >&2; exit 127; }; ' +
        'echo "using docker at $D"; '
}
else {
    $resolveD = "D='$DockerCmd'; "
}
$dk = '"$D"'             # literal; the remote shell expands $D
$imageRepo = $ImageTag.Split(':')[0]

if ($Start) {
    Step "Loading the image and starting the stack on the NAS (enter the sudo password if prompted)..."
    # Resolve the compose command into $C: docker-compose (v1) first, then `docker compose` (v2).
    if ($ComposeCmd) {
        $resolveC = "C='$ComposeCmd'; "
    }
    else {
        $resolveC = 'if [ -x /usr/local/bin/docker-compose ]; then C=/usr/local/bin/docker-compose; ' +
            'elif command -v docker-compose >/dev/null 2>&1; then C=$(command -v docker-compose); ' +
            'elif "$D" compose version >/dev/null 2>&1; then C="$D compose"; ' +
            'else echo "no docker-compose (v1) or docker compose (v2) on the NAS - re-run with -ComposeCmd <cmd>" >&2; exit 127; fi; ' +
            'echo "using compose: $C"; '
    }
    $ck = '$C'          # unquoted reference, so a `<docker> compose` (v2) value word-splits
    # `down` first so a prior/half-created container can't leave its port "already allocated"
    # ( || true: down is a no-op the first time, when there's nothing to remove ). Then force-
    # remove any leftover container named `bindicator` by name: `compose down` only removes
    # containers it owns, so one created out-of-band (a manual `docker run`, Container Manager,
    # or an earlier compose project) would otherwise collide on the fixed container_name.
    # `mkdir -p data`: the ./data bind-mount source must exist first - Synology's docker-compose
    # v1 won't auto-create it (newer Docker does), so `up` would fail with "Bind mount failed:
    # '.../data' does not exists".
    $remote = $resolveD + $resolveC +
        "sudo $dk load -i '$remoteTar' && sudo rm -f '$remoteTar' && cd '$RemoteDir' && mkdir -p data && " +
        "{ sudo $ck down || true; } && { sudo $dk rm -f bindicator || true; } && " +
        "sudo $ck up -d && sudo $ck ps"
}
else {
    Step "Loading the image on the NAS (enter the sudo password if prompted)..."
    $remote = $resolveD +
        "sudo $dk load -i '$remoteTar' && sudo rm -f '$remoteTar' && sudo $dk images $imageRepo"
}
ssh -t @sshOpts $target $remote
Assert-Ok "remote docker step"

# --- 5. Cleanup + next steps -----------------------------------------------------------
Remove-Item $localTar -ErrorAction SilentlyContinue
Step "Done."
if ($Start) {
    Write-Host @"

Started. Verify:  http://${NasHost}:${HostPort}/health   then  /next
The scraped schedule is persisted to ${RemoteDir}/data/collections.json, so it
survives container and host restarts.
"@ -ForegroundColor Green
}
else {
    Write-Host @"

Image '$ImageTag' is now loaded on $NasHost.
Next, re-run with -Start (add -HostPort if :8000 is taken), or create the Project in Container
Manager using a compose that publishes  ports: ["${HostPort}:8000"], sets  shm_size: 256m,
and bind-mounts  ./data:/data  with  CACHE_FILE=/data/collections.json.
"@ -ForegroundColor Green
}
