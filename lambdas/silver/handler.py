"""Lambda generica bronze -> silver.

Nao tem nenhuma regra por praca: le o par (praca, entidade) das proprias
particoes da chave no S3 e consulta schemas/mapeamento_silver.py pra saber
como normalizar. Fonte nova = uma entrada naquele dicionario, sem tocar aqui.

Aceita dois formatos de entrada:
  - evento do S3 (disparo automatico quando a bronze grava)
  - payload manual {"bucket": "...", "key": "..."} pra reprocessar
"""

import time
from urllib.parse import unquote_plus

from lambdas.common.logging_config import criar_logger
from lambdas.common.s3_silver import escrever_parquet, ler_ndjson
from lambdas.common.validation import validar_lote
from schemas.mapeamento_silver import obter_mapeamento

logger = criar_logger("silver")


def _objetos_do_evento(event):
    """Extrai (bucket, key) tanto de um evento do S3 quanto de um payload
    manual. O S3 entrega a chave URL-encoded, por isso o unquote_plus."""
    if "Records" in event:
        return [
            (r["s3"]["bucket"]["name"], unquote_plus(r["s3"]["object"]["key"]))
            for r in event["Records"]
        ]
    if "bucket" in event and "key" in event:
        return [(event["bucket"], event["key"])]
    raise ValueError(
        'Evento sem objeto pra processar. Esperado evento do S3 ou {"bucket": ..., "key": ...}.'
    )


def _particoes(key):
    """bronze/praca=sp/entidade=posicoes/dt=.../hh=.../arquivo.ndjson
    -> {"praca": "sp", "entidade": "posicoes", ...}"""
    return dict(
        segmento.split("=", 1) for segmento in key.split("/") if "=" in segmento
    )


def _normalizar(registros, mapeamento, praca):
    canonicos = []
    for registro in registros:
        canonico = {
            campo_canonico: registro.get(campo_bronze)
            for campo_bronze, campo_canonico in mapeamento["campos"].items()
        }
        canonico["praca"] = praca
        canonicos.append(canonico)
    return canonicos


def _processar_objeto(bucket, key):
    particoes = _particoes(key)
    praca, entidade = particoes["praca"], particoes["entidade"]
    mapeamento = obter_mapeamento(praca, entidade)

    brutos = ler_ndjson(bucket, key)
    canonicos = _normalizar(brutos, mapeamento, praca)
    validos, invalidos = validar_lote(canonicos, mapeamento["modelo"])

    key_silver = key.replace("bronze/", "silver/", 1).replace(".ndjson", ".parquet")
    escrever_parquet(bucket, key_silver, validos, mapeamento["modelo"])

    if invalidos:
        logger.warning(
            "registros descartados na normalizacao",
            extra={"total_invalido": len(invalidos), "amostra": invalidos[:3], "origem": key},
        )

    return {
        "praca": praca,
        "entidade": entidade,
        "origem": key,
        "destino": key_silver,
        "total_lido": len(brutos),
        "total_valido": len(validos),
        "total_invalido": len(invalidos),
    }


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()
    resultados = [_processar_objeto(bucket, key) for bucket, key in _objetos_do_evento(event)]

    resumo = {
        "objetos_processados": len(resultados),
        "total_valido": sum(r["total_valido"] for r in resultados),
        "total_invalido": sum(r["total_invalido"] for r in resultados),
        "duracao_s": round(time.monotonic() - inicio, 2),
        "detalhe": resultados,
    }
    logger.info("normalizacao concluida", extra=resumo)
    return resumo
