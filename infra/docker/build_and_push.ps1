# Equivalente PowerShell do build_and_push.sh.
param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [string]$Tag = "latest",
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" })
)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\..")  # raiz do repo

# --provenance=false --sbom=false: sem isso o Docker Desktop atual (BuildKit)
# gera um manifesto com attestation que a Lambda REJEITA na criacao da
# funcao ("image manifest, config or layer media type ... is not
# supported") -- achado fazendo deploy de verdade, nao e opcional.
docker build --provenance=false --sbom=false -f infra\docker\Dockerfile -t "${RepoUrl}:${Tag}" .

$registryHost = $RepoUrl.Split("/")[0]
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registryHost

docker push "${RepoUrl}:${Tag}"

Write-Host "Publicado: ${RepoUrl}:${Tag}"
