import time

from lambdas.common.logging_config import criar_logger
from lambdas.common.retry import com_retry
from lambdas.common.s3_writer import escrever_bronze
from lambdas.common.validation import validar_lote
from schemas.rio import RioPosicao
from src.rio_client import buscar_posicao_geral

logger = criar_logger("rio-posicoes")

_buscar_posicao_com_retry = com_retry(buscar_posicao_geral)


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()

    # buscar_posicao_geral ja deduplica por id_veiculo (a API devolve log
    # bruto de pings, nao snapshot -- ver README/schemas.rio.RioPosicao).
    veiculos = _buscar_posicao_com_retry()

    validos, invalidos = validar_lote(veiculos, RioPosicao)
    chave_s3 = escrever_bronze("rio", "posicoes", validos)

    resultado = {
        "praca": "rio",
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
