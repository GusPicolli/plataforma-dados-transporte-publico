import time

from lambdas.common.logging_config import criar_logger
from lambdas.common.retry import com_retry
from lambdas.common.s3_writer import escrever_bronze
from lambdas.common.validation import validar_lote
from schemas.rio import RioLinha, RioPonto
from src import rio_gtfs

logger = criar_logger("rio-cadastro")

_buscar_linhas_com_retry = com_retry(rio_gtfs.buscar_linhas)
_buscar_pontos_com_retry = com_retry(rio_gtfs.buscar_pontos_todas_linhas)


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()

    linhas = _buscar_linhas_com_retry()
    pontos = _buscar_pontos_com_retry()

    linhas_validas, linhas_invalidas = validar_lote(linhas, RioLinha)
    pontos_validos, pontos_invalidos = validar_lote(pontos, RioPonto)

    chave_linhas = escrever_bronze("rio", "linhas", linhas_validas)
    chave_pontos = escrever_bronze("rio", "pontos", pontos_validos)

    resultado = {
        "praca": "rio",
        "linhas": {"total_recebido": len(linhas), "total_valido": len(linhas_validas), "total_invalido": len(linhas_invalidas), "s3_key": chave_linhas},
        "pontos": {"total_recebido": len(pontos), "total_valido": len(pontos_validos), "total_invalido": len(pontos_invalidos), "s3_key": chave_pontos},
        "duracao_s": round(time.monotonic() - inicio, 2),
    }

    if linhas_invalidas:
        logger.warning("linhas invalidas descartadas", extra={"total_invalido": len(linhas_invalidas), "amostra": linhas_invalidas[:3]})
    if pontos_invalidos:
        logger.warning("pontos invalidos descartados", extra={"total_invalido": len(pontos_invalidos), "amostra": pontos_invalidos[:3]})

    logger.info("coleta de cadastro concluida", extra=resultado)
    return resultado
