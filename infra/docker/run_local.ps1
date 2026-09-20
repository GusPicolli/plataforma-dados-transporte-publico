# Equivalente PowerShell do run_local.sh.
# Uso: .\run_local.ps1 lambdas.rio_posicoes.handler.lambda_handler
param(
    [Parameter(Mandatory = $true)][string]$Handler
)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\..")  # raiz do repo

# --provenance=false --sbom=false mantem a imagem identica a que
# build_and_push.ps1 publica no ECR -- sem isso a Lambda de verdade
# rejeita a imagem.
docker build --provenance=false --sbom=false -f infra\docker\Dockerfile -t onibus-lambda:local .

# --env-file .env cobre SPTRANS_TOKEN. Pra escrever num S3 de mentira local
# (MinIO) em vez da AWS de verdade, acrescente antes do nome da imagem:
#   -e BUCKET_NAME=onibus-dados-brutos-dev -e S3_ENDPOINT_URL=http://host.docker.internal:9000 `
#   -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin -e AWS_DEFAULT_REGION=us-east-1
docker run --rm -p 9000:8080 --env-file .env onibus-lambda:local $Handler
