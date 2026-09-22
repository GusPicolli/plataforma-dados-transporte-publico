import io
import json
import os
from typing import get_args

import boto3
import pyarrow as pa
import pyarrow.parquet as pq

S3_ENDPOINT_URL = os.getenv("S3_ENDPOINT_URL")

_TIPOS_ARROW = {str: pa.string(), float: pa.float64(), int: pa.int64(), bool: pa.bool_()}


def _cliente_s3():
    kwargs = {"endpoint_url": S3_ENDPOINT_URL} if S3_ENDPOINT_URL else {}
    return boto3.client("s3", **kwargs)


def ler_ndjson(bucket, key):
    corpo = _cliente_s3().get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    return [json.loads(linha) for linha in corpo.splitlines() if linha.strip()]


def _schema_arrow(modelo):
    """Deriva o schema Arrow do model pydantic em vez de deixar o pyarrow
    inferir dos dados. Inferir daria errado quando uma coluna vem inteira
    nula (ex: velocidade em SP, que a fonte nao tem): o pyarrow criaria uma
    coluna do tipo null, que o Athena nao le direito."""
    campos = []
    for nome, info in modelo.model_fields.items():
        args = [a for a in get_args(info.annotation) if a is not type(None)]
        tipo_python = args[0] if args else info.annotation
        campos.append(pa.field(nome, _TIPOS_ARROW.get(tipo_python, pa.string()), nullable=True))
    return pa.schema(campos)


def escrever_parquet(bucket, key, registros, modelo):
    if not registros:
        return None

    tabela = pa.Table.from_pylist(registros, schema=_schema_arrow(modelo))
    buffer = io.BytesIO()
    pq.write_table(tabela, buffer, compression="snappy")

    _cliente_s3().put_object(
        Bucket=bucket, Key=key, Body=buffer.getvalue(), ContentType="application/vnd.apache.parquet"
    )
    return key
