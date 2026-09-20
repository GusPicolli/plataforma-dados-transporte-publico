#!/usr/bin/env bash
# Builda a imagem (as 5 funcoes moram na mesma imagem) e publica no ECR.
# O repo precisa existir primeiro -- ver "deploy em 2 fases" no README do
# terraform, porque o Lambda so aceita ser criado apontando pra uma tag que
# ja existe no ECR.
set -euo pipefail
cd "$(dirname "$0")/../.."  # raiz do repo

REPO_URL="${1:?Uso: build_and_push.sh <repo_url_do_ecr> [tag]}"
TAG="${2:-latest}"
REGION="${AWS_REGION:-us-east-1}"

# --provenance=false --sbom=false: sem isso o Docker Desktop atual (BuildKit)
# gera um manifesto com attestation que a Lambda REJEITA na criacao da
# funcao ("image manifest, config or layer media type ... is not
# supported") -- achado fazendo deploy de verdade, nao e opcional.
docker build --provenance=false --sbom=false -f infra/docker/Dockerfile -t "${REPO_URL}:${TAG}" .

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REPO_URL%%/*}"

docker push "${REPO_URL}:${TAG}"

echo "Publicado: ${REPO_URL}:${TAG}"
