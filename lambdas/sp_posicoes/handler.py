import time

from lambdas.common.logging_config import criar_logger
from lambdas.common.retry import com_retry
from lambdas.common.s3_writer import escrever_bronze
from lambdas.common.secrets import obter_token_sptrans
from lambdas.common.validation import validar_lote
from schemas.sptrans import SPTransPosicao
from src.sptrans_client import autenticar, buscar_posicao_geral, flatten_posicao_geral

logger = criar_logger("sp-posicoes")

_autenticar_com_retry = com_retry(autenticar)
_buscar_posicao_com_retry = com_retry(buscar_posicao_geral)


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()

    cookies = _autenticar_com_retry(obter_token_sptrans())
    veiculos = flatten_posicao_geral(_buscar_posicao_com_retry(cookies))

    validos, invalidos = validar_lote(veiculos, SPTransPosicao)
    chave_s3 = escrever_bronze("sp", "posicoes", validos)

    resultado = {
        "praca": "sp",
        "entidade": "posicoes",
        "total_recebido": len(veiculos),
        "total_valido": len(validos),
        "total_invalido": len(invalidos),
        "s3_key": chave_s3,
        "duracao_s": round(time.monotonic() - inicio, 2),
    }

    if invalidos:
        logger.warning("registros invalidos descartados do lote", extra={
            "total_invalido": len(invalidos),
            "amostra": invalidos[:3],
        })

    logger.info("coleta concluida", extra=resultado)
    return resultado
