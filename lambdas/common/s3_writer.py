import json
import os
from datetime import datetime, timezone

import boto3

BUCKET_NAME = os.getenv("BUCKET_NAME", "onibus-dados-brutos-dev")

# So definido em dev local, pra apontar pro MinIO em vez da AWS de verdade.
# Sem essa variavel, boto3 usa o S3 real com as credenciais do ambiente.
S3_ENDPOINT_URL = os.getenv("S3_ENDPOINT_URL")


def _cliente_s3():
    kwargs = {"endpoint_url": S3_ENDPOINT_URL} if S3_ENDPOINT_URL else {}
    return boto3.client("s3", **kwargs)


def escrever_bronze(praca, entidade, registros, momento=None):
    """Grava os registros validados como NDJSON na camada bronze,
    particionado por praca/entidade/dt/hh (o mesmo layout descrito na
    Proposta de arquitetura). Nao escreve nada se o lote estiver vazio --
    evita poluir o bucket com arquivos de 0 bytes em ciclos sem novidade."""
    if not registros:
        return None

    momento = momento or datetime.now(timezone.utc)
    key = (
        f"bronze/praca={praca}/entidade={entidade}/"
        f"dt={momento:%Y-%m-%d}/hh={momento:%H}/"
        f"{momento:%Y%m%dT%H%M%SZ}.ndjson"
    )

    # Carimba aqui, e nao no handler, porque validar_lote usa model_dump() do
    # pydantic -- que devolve so os campos declarados no model da fonte e
    # descartaria qualquer coisa adicionada antes. Sem isso o bronze perde o
    # horario de coleta (so restaria o que esta na propria chave do S3).
    coletado_em = momento.isoformat()
    corpo = "\n".join(
        json.dumps({**registro, "coletado_em": coletado_em}, ensure_ascii=False)
        for registro in registros
    ).encode("utf-8")

    _cliente_s3().put_object(Bucket=BUCKET_NAME, Key=key, Body=corpo, ContentType="application/x-ndjson")
    return key
