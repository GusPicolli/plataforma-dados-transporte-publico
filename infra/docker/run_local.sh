#!/usr/bin/env bash
# Builda e roda UMA funcao localmente, via Lambda Runtime Interface Emulator
# (ja embutido na imagem base public.ecr.aws/lambda/python). O handler vira
# argumento do "docker run" -- e assim que se troca de funcao sem rebuildar.
#
# Uso:
#   ./run_local.sh lambdas.rio_posicoes.handler.lambda_handler
#
# Depois, em outro terminal:
#   curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d '{}'
set -euo pipefail
cd "$(dirname "$0")/../.."  # raiz do repo

HANDLER="${1:?Uso: run_local.sh <handler> (ex: lambdas.rio_posicoes.handler.lambda_handler)}"

# --provenance=false --sbom=false nao muda nada pro teste local (RIE roda
# de qualquer jeito), mas mantem a imagem identica a que build_and_push.sh
# publica no ECR -- sem isso a Lambda de verdade rejeita a imagem.
docker build --provenance=false --sbom=false -f infra/docker/Dockerfile -t onibus-lambda:local .

# --env-file .env cobre SPTRANS_TOKEN. Pra escrever num S3 de mentira local
# (MinIO) em vez da AWS de verdade, acrescente:
#   -e BUCKET_NAME=onibus-dados-brutos-dev -e S3_ENDPOINT_URL=http://host.docker.internal:9000 \
#   -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin -e AWS_DEFAULT_REGION=us-east-1
docker run --rm -p 9000:8080 --env-file .env onibus-lambda:local "${HANDLER}"
