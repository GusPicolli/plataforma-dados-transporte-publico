import time

from lambdas.common.logging_config import criar_logger
from lambdas.common.retry import com_retry
from lambdas.common.s3_writer import escrever_bronze
from lambdas.common.secrets import obter_token_sptrans
from lambdas.common.validation import validar_lote
from schemas.sptrans import SPTransLinha, SPTransPonto
from src import sptrans_gtfs
from src.sptrans_client import autenticar, buscar_todas_linhas

logger = criar_logger("sp-cadastro")

_autenticar_com_retry = com_retry(autenticar)
_buscar_todas_linhas_com_retry = com_retry(buscar_todas_linhas)
_buscar_pontos_com_retry = com_retry(sptrans_gtfs.buscar_pontos_todas_linhas)


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()

    cookies = _autenticar_com_retry(obter_token_sptrans())
    linhas = _buscar_todas_linhas_com_retry(cookies)
    pontos = _buscar_pontos_com_retry()

    linhas_validas, linhas_invalidas = validar_lote(linhas, SPTransLinha)
    pontos_validos, pontos_invalidos = validar_lote(pontos, SPTransPonto)

    chave_linhas = escrever_bronze("sp", "linhas", linhas_validas)
    chave_pontos = escrever_bronze("sp", "pontos", pontos_validos)

    resultado = {
        "praca": "sp",
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
