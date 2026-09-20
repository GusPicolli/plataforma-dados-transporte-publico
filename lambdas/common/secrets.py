import os

import boto3


def obter_token_sptrans():
    """SPTRANS_TOKEN direto no ambiente (dev local, reaproveita o .env que
    os pipelines em lote ja usam). Em producao, sem essa variavel, busca no
    SSM Parameter Store pelo nome em SPTRANS_TOKEN_PARAM."""
    token = os.getenv("SPTRANS_TOKEN")
    if token:
        return token

    nome_parametro = os.getenv("SPTRANS_TOKEN_PARAM")
    if not nome_parametro:
        raise RuntimeError(
            "Defina SPTRANS_TOKEN (dev local) ou SPTRANS_TOKEN_PARAM "
            "(nome do parametro no SSM, em producao)."
        )
    resposta = boto3.client("ssm").get_parameter(Name=nome_parametro, WithDecryption=True)
    return resposta["Parameter"]["Value"]
