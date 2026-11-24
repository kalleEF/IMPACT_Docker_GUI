
<# IMPACTncd Germany Master Script 

TESTING GPT ANSWER - PLEASE REVIEW CAREFULLY

#>

# --- User-configurable bits ---
$Image           = "rocker/rstudio:latest"   # kept for reference; not used when calling the repo script
$ContainerName   = "rstudio"
$HostPort        = 8787                      # port on the machine that runs the container
$ContainerPort   = 8787

# Remote host profile (edit these)
$RemoteUser      = "you"
$RemoteHost      = "remote.example.com"
$RemoteCtxName   = "rstudio-remote"
$RemoteRepoRoot  = "/home/you/repos"         # hardcoded directory containing repos
$RepoScriptName  = "MY_CONTAINER.sh"

function Read-PlainPassword {
  param([string]$Prompt = "RStudio password")
  Read-Host -Prompt $Prompt
}

function Ensure-DockerContext {
  param([string]$CtxName, [string]$Endpoint)
  $exists = (docker context ls --format "{{.Name}}" | Where-Object { $_ -eq $CtxName }) -ne $null
  if (-not $exists) {
    Write-Host "Creating Docker context '$CtxName' -> $Endpoint ..."
    docker context create $CtxName --docker "host=$Endpoint" | Out-Null
  }
}

function Select-FromList {
  param(
    [string]$Title,
    [string[]]$Options
  )
  if (-not $Options -or $Options.Count -eq 0) {
    throw "No options found to select from."
  }
  Write-Host "`n$Title" -ForegroundColor Cyan
  for ($i=0; $i -lt $Options.Count; $i++) {
    "{0,2}) {1}" -f ($i+1), $Options[$i] | Write-Host
  }
  do {
    $choice = Read-Host "Enter number (1-$($Options.Count))"
  } while (-not ($choice -as [int]) -or [int]$choice -lt 1 -or [int]$choice -gt $Options.Count)
  return $Options[[int]$choice - 1]
}

function Start-Local {
  # Unchanged local path mount (optional: keep using docker run locally)
  $pwdPath = (Get-Location).Path
  $default = $pwdPath
  $proj = Read-Host "Local project path to mount (Enter for current: $default)"
  if ([string]::IsNullOrWhiteSpace($proj)) { $proj = $default }

  if (-not (Test-Path $proj)) { throw "Path not found: $proj" }

  $pass = Read-PlainPassword

  Write-Host "Starting RStudio locally, mounting '$proj' => /home/rstudio/project ..." -ForegroundColor Green
  docker run -d --name $ContainerName `
    -p $HostPort:$ContainerPort `
    -e PASSWORD=$pass `
    -v "${proj}:/home/rstudio/project" `
    $Image | Out-Null

  Write-Host "Open: http://localhost:$HostPort  (user: rstudio, your password)" -ForegroundColor Yellow
}

function Start-Remote {
  $pass = Read-PlainPassword

  # Basic SSH reachability
  Write-Host "Checking SSH reachability to $RemoteUser@$RemoteHost ..."
  & ssh "$RemoteUser@$RemoteHost" "echo ok" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "SSH to $RemoteUser@$RemoteHost failed." }

  # Ensure/Use Docker context (not strictly required to run the script, but handy if your script uses 'docker')
  Ensure-DockerContext -CtxName $RemoteCtxName -Endpoint "ssh://$RemoteUser@$RemoteHost"
  docker context use $RemoteCtxName | Out-Null

  # List repos on the remote
  Write-Host "Listing repos in $RemoteRepoRoot on remote ..."
  $lsCmd = "set -e; test -d $RemoteRepoRoot && ls -1 $RemoteRepoRoot || true"
  $reposText = & ssh "$RemoteUser@$RemoteHost" $lsCmd
  $repos = @()
  if ($reposText) {
    $repos = $reposText -split "`n" | Where-Object { $_ -ne "" }
  }
  if ($repos.Count -eq 0) { throw "No repos found under $RemoteRepoRoot on remote host." }

  $selected = Select-FromList -Title "Select a remote repo directory" -Options $repos
  $remoteRepoPath = "$RemoteRepoRoot/$selected"

  # Optional: pull latest on remote BEFORE starting container
  $gitUpdateCmd = @"
set -e
if [ -d '$remoteRepoPath/.git' ]; then
  cd '$remoteRepoPath'
  git fetch --all || true
  git pull --rebase --autostash || true
fi
"@
  Write-Host "Refreshing repo on remote (fetch/pull) ..."
  & ssh "$RemoteUser@$RemoteHost" $gitUpdateCmd | Out-Null

  # ---- NEW: Run the repo's launcher script instead of docker run ----
  # We pass env vars the script can read. Adjust in MY_CONTAINER.sh to use them.
  $runScriptCmd = @"
set -e
cd '$remoteRepoPath'
if [ ! -f './$RepoScriptName' ]; then
  echo 'ERROR: $RepoScriptName not found in $remoteRepoPath' >&2
  exit 1
fi
chmod +x './$RepoScriptName' || true

# Export variables your script can consume:
export PASSWORD='$pass'
export RSTUDIO_PASSWORD='$pass'         # some images use PASSWORD, others check RSTUDIO_PASSWORD
export RSTUDIO_PORT='$HostPort'         # expose on this host port (if your script supports it)
export CONTAINER_NAME='$ContainerName'  # container name to use (optional)
export PROJECT_DIR='$remoteRepoPath'    # path to mount (optional)

# Run the script. If it accepts a verb, try 'start' first; otherwise just run it.
if grep -q 'start)' './$RepoScriptName' 2>/dev/null; then
  ./'$RepoScriptName' start
else
  ./'$RepoScriptName'
fi
"@

  Write-Host "Running $RepoScriptName on the remote repo ..." -ForegroundColor Green
  & ssh "$RemoteUser@$RemoteHost" $runScriptCmd
  if ($LASTEXITCODE -ne 0) {
    throw "Remote script failed. Check $remoteRepoPath/$RepoScriptName on $RemoteHost."
  }

  Write-Host "If the script started RStudio Server, open: http://$RemoteHost:$HostPort  (user: rstudio, your password)" -ForegroundColor Yellow

  # Optionally switch back to local context:
  # docker context use default | Out-Null
}

# --- Main menu ---
Write-Host "Start Rocker/RStudio" -ForegroundColor Cyan
$mode = Select-FromList -Title "Where do you want to run the container?" -Options @("Local (this Windows PC)", "Remote ($RemoteUser@$RemoteHost)")

try {
  if ($mode -like "Local*") {
    Start-Local
  } else {
    Start-Remote
  }
}
catch {
  Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
    