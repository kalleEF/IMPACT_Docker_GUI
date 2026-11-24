<#
    docker_build_push.ps1: build one of the two images by hand, and push it if wanted

    PURPOSE
      Builds an image from one of the Dockerfiles in docker_setup and, with -Push,
      uploads it to Docker Hub (the public image registry of Docker). The IMPACT Docker
      GUI builds the model image by itself; this script is for the maintainer, mainly for
      the prerequisite image (see docker_setup/README.md).

    WHEN IT RUNS
      Only when a person starts it, in PowerShell, from the docker_setup folder (the
      build context below is taken relative to the current folder):
          cd docker_setup
          .\docker_build_push.ps1 <dockerfile> [-ImageName <name>] [-ImageTag <tag>] [-Push]
      Example:
          .\docker_build_push.ps1 Dockerfile.prerequisite.IMPACTncdGER -ImageName prerequisite.impactncdger -ImageTag latest

    WHAT IT CHANGES
      - Builds the image <ImageName>:<ImageTag> on this computer, always from scratch
        ("--no-cache"). The defaults are "impactncd-germany-r-prerequisite" and "local";
        both are turned into small letters.
      - Build context ("the files Docker may copy into the image"): the repository
        folder ("..") for Dockerfile.IMPACTncdGER, the docker_setup folder (".") for any
        other Dockerfile.
      - With -Push only: signs in to Docker Hub and uploads the image as
        <DOCKERHUB_USERNAME>/<ImageName>:<ImageTag>. DOCKERHUB_USERNAME and
        DOCKERHUB_TOKEN come from the environment or from the file .env in the current
        folder, for example:
              export DOCKERHUB_USERNAME=yourusername
              export DOCKERHUB_TOKEN=youraccesstoken
        Without a token the script asks for the Docker Hub sign-in.

    WHAT IT NEVER TOUCHES
      Files of the repository, containers, and other images. Without -Push nothing
      leaves this computer.
#>
param (
    [string]$Dockerfile,
    [string]$ImageName = "impactncd-germany-r-prerequisite",
    [string]$ImageTag = "local",
    [switch]$Push = $false
)

# Initialize DockerHub variables (will be set later if needed)
$DockerHubUsername = $env:DOCKERHUB_USERNAME
$DockerHubToken = $env:DOCKERHUB_TOKEN

# Validate Dockerfile argument
if (-not $Dockerfile) {
    Write-Host "Error: Dockerfile argument is required."
    exit 1
}

function Log {
    param ($Message)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

# Remove hardcoded default for $ImageName
# Respect user-defined name if provided, otherwise derive from Dockerfile
if (-not $ImageName) {
    $ImageName = ($Dockerfile -split '\\|/')[-1] -replace '^[Dd]ockerfile\.', '' | ForEach-Object { $_.ToLower() }
}

# Convert image name and tag to lowercase
if ($ImageName -ne $ImageName.ToLower()) {
    Log "Image name '$ImageName' converted to lowercase."
    $ImageName = $ImageName.ToLower()
}
if ($ImageTag -ne $ImageTag.ToLower()) {
    Log "Image tag '$ImageTag' converted to lowercase."
    $ImageTag = $ImageTag.ToLower()
}

# Construct the image name for building
$BuildImageName = "${ImageName}:${ImageTag}"

# Skip credential checks if push argument is false
if ($Push) {
    # Load environment variables from .env if not already set (only when pushing)
    $envFile = ".env"
    if (-not $DockerHubUsername -or -not $DockerHubToken) {
        if (Test-Path $envFile) {
            $lines = Get-Content $envFile | Where-Object { $_ -notmatch '^(\s*#|\s*$)' }
            if ($lines.Count -eq 0) {
                Write-Host ".env file is empty or contains only comments."
            } else {
                $lines | ForEach-Object {
                    $parts = $_ -split '=', 2
                    if ($parts.Length -eq 2) {
                        $key = $parts[0].Trim() -replace 'export ', ''
                        $value = $parts[1].Trim()
                        if (-not (Get-Item -Path Env:$key -ErrorAction SilentlyContinue)) {
                            [Environment]::SetEnvironmentVariable($key, $value, "Process")
                            Write-Host "Set $key from .env"
                        }
                    }
                }
                Write-Host "Environment variables loaded from .env"
            }
        } else {
            Write-Host ".env file not found."
        }
    }

    # Prompt for username if not set
    if (-not $DockerHubUsername) {
        $DockerHubUsername = Read-Host "Enter your Docker Hub username"
    }

    # Construct the full image name for pushing
    $FullImageName = "${DockerHubUsername}/${ImageName}:${ImageTag}"
    if (-not $DockerHubToken) {
        Log "DOCKERHUB_TOKEN not set. Prompting for manual login..."
        docker login
    } else {
        Log "Logging into Docker Hub..."
        $DockerHubToken | docker login -u $DockerHubUsername --password-stdin
        if ($LASTEXITCODE -ne 0) {
            Log "Docker login failed."
            exit 1
        }
    }
}

# Validate Dockerfile argument
if (-not $Dockerfile) {
    Write-Host "Error: Dockerfile argument is required."
    exit 1
}

# Build
Log "Building Docker image..."
# Use parent directory as build context for Dockerfile.IMPACTncdGER to include entire project
# Use current directory for other dockerfiles
$DockerfileName = (Split-Path $Dockerfile -Leaf)
if ($DockerfileName -eq "Dockerfile.IMPACTncdGER") {
    $BuildContext = ".."
    Log "Using parent directory (..) as build context for Dockerfile.IMPACTncdGER"
} else {
    $BuildContext = "."
    Log "Using current directory (.) as build context for $DockerfileName"
}

docker build --no-cache -f $Dockerfile -t $BuildImageName $BuildContext
if ($LASTEXITCODE -eq 0) {
    Log "Docker image built successfully."
} else {
    Log "Docker image build failed."
    exit 1
}

if ($Push) {
    Log "Tagging Docker image for Docker Hub..."
    docker tag $BuildImageName $FullImageName

    Log "Pushing Docker image to Docker Hub..."
    docker push $FullImageName
    if ($LASTEXITCODE -eq 0) {
        Log "Docker image pushed successfully."
    } else {
        Log "Docker push failed."
        exit 1
    }
} else {
    Log "Skipping Docker push as -Push switch was not provided."
}

# Display the final Docker image name
Log "Final Docker image name: $BuildImageName"
