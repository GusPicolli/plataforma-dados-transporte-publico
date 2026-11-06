# Uma imagem, 7 funcoes. O handler de cada uma nao vem daqui -- vem de
# "image_config.command" no Terraform (deploy) ou do argumento de
# "docker run" (local). O CMD abaixo so entra em jogo se ninguem
# especificar nenhum dos dois.
#
# Build a partir da RAIZ do repo (o contexto precisa alcancar src/,
# schemas/ e lambdas/):
#   docker build -f infra/docker/Dockerfile -t onibus-lambda:local .
FROM public.ecr.aws/lambda/python:3.12

# Mesma lista da layer do deploy em zip (ver lambdas/requirements-layer.txt)
# -- sem boto3 (o runtime da Lambda ja traz) nem python-dotenv (nao existe
# .env em producao). Rodando dentro dessa imagem base, o pip ja resolve os
# wheels pra a plataforma certa sozinho -- e o problema de
# "baixei o .whl do SO errado" que apareceu no build da layer em zip.
COPY lambdas/requirements-layer.txt ${LAMBDA_TASK_ROOT}/requirements.txt
RUN pip install -r ${LAMBDA_TASK_ROOT}/requirements.txt -t ${LAMBDA_TASK_ROOT}

COPY coleta ${LAMBDA_TASK_ROOT}/coleta
COPY schemas ${LAMBDA_TASK_ROOT}/schemas
COPY lambdas ${LAMBDA_TASK_ROOT}/lambdas

CMD ["lambdas.ingestao.handler.lambda_handler"]
