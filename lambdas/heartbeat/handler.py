"""Publica a IDADE do dado mais recente de cada pipeline como metrica.

Existe por um motivo especifico: nao da pra alarmar de forma confiavel sobre
a AUSENCIA de execucao usando a metrica Invocations da Lambda. Ela e esparsa
-- so ganha ponto quando a funcao roda -- e o CloudWatch, ao avaliar, procura
datapoint para tras ate achar algum. Medido neste projeto: com a funcao 26h
sem rodar, o alarme continuou OK porque encontrou o ponto de dois dias antes.
FILL(m,0) tambem nao resolve: sem ponto nenhum na janela, nao ha lacuna a
preencher.

Esta funcao roda de hora em hora e SEMPRE publica um ponto por pipeline.
Metrica densa, alarme confiavel. E o que ela mede -- ha quanto tempo nao
chega dado -- e a pergunta que realmente importa, nao um proxy dela.

Mesmo criterio de scripts/status_pipeline.py, que responde isso no terminal."""

import datetime
import os

import boto3

from lambdas.common.logging_config import criar_logger

logger = criar_logger("heartbeat")

BUCKET = os.environ["BUCKET_NAME"]
NAMESPACE = os.environ.get("METRICAS_NAMESPACE", "onibus-tempo-real/qualidade")

# Um item por pipeline agendado. A entidade escolhida e a que aquele pipeline
# sempre grava quando roda bem -- se ela esta velha, o pipeline nao entregou.
PIPELINES = {
    "sp_posicoes": ("sp", "posicoes"),
    "rio_posicoes": ("rio", "posicoes"),
    "sp_cadastro": ("sp", "linhas"),
    "rio_cadastro": ("rio", "linhas"),
    "fortaleza_cadastro": ("fortaleza", "linhas"),
}

# Valor publicado quando a praca nunca gravou nada. Um numero grande e finito
# em vez de pular o ponto: pular deixaria a serie esparsa de novo, que e
# exatamente o problema que esta funcao existe para resolver.
IDADE_SEM_DADO_H = 9999.0

s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")


def _idade_horas(praca, entidade, agora):
    prefixo = f"bronze/praca={praca}/entidade={entidade}/"
    mais_novo = None
    for pagina in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefixo):
        for obj in pagina.get("Contents", []):
            if mais_novo is None or obj["LastModified"] > mais_novo:
                mais_novo = obj["LastModified"]
    if mais_novo is None:
        return IDADE_SEM_DADO_H
    return (agora - mais_novo).total_seconds() / 3600


def lambda_handler(event, context):
    agora = datetime.datetime.now(datetime.timezone.utc)

    idades = {
        nome: round(_idade_horas(praca, entidade, agora), 3)
        for nome, (praca, entidade) in PIPELINES.items()
    }

    cloudwatch.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {
                "MetricName": f"idade_horas_{nome}",
                "Value": idade,
                "Unit": "None",
                "Timestamp": agora,
            }
            for nome, idade in idades.items()
        ],
    )

    logger.info("idade do dado publicada", extra={"idades_h": idades})
    return idades
