import time

from lambdas.common.logging_config import criar_logger
from lambdas.common.retry import com_retry
from lambdas.common.s3_writer import escrever_bronze
from lambdas.common.validation import validar_lote
from schemas.fortaleza import FortalezaLinha, FortalezaPonto
from src import fortaleza_client

logger = criar_logger("fortaleza-cadastro")

SENTIDOS = (("ida", "itinerarioIda"), ("volta", "itinerarioVolta"))

_buscar_linhas_com_retry = com_retry(fortaleza_client.buscar_linhas)
_buscar_itinerario_com_retry = com_retry(fortaleza_client.buscar_itinerario)


def _coletar_pontos(linhas):
    """Uma chamada por linha -- a ETUFOR nao tem endpoint em lote. Uma
    linha sem itinerario (erro 500 conhecido e intermitente da API
    nao-oficial, ver README) e pulada, nao aborta a coleta das demais."""
    pontos = []
    codigos_sem_itinerario = []

    for linha in linhas:
        codigo_linha = linha["numero"]
        try:
            itinerario = _buscar_itinerario_com_retry(codigo_linha)
        except Exception:
            itinerario = {}

        if "ida" not in itinerario and "volta" not in itinerario:
            codigos_sem_itinerario.append(codigo_linha)
            continue

        for sentido, chave_pontos in SENTIDOS:
            bloco = itinerario.get(sentido) or {}
            for ponto in bloco.get(chave_pontos, []):
                pontos.append({
                    "codigo_linha": codigo_linha,
                    "sentido": sentido,
                    "logId": ponto.get("logId"),
                    "nome": ponto.get("nome"),
                    "distanciaPercorrida": ponto.get("distanciaPercorrida"),
                })

    return pontos, codigos_sem_itinerario


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()

    linhas = _buscar_linhas_com_retry()
    linhas_validas, linhas_invalidas = validar_lote(linhas, FortalezaLinha)

    pontos, codigos_sem_itinerario = _coletar_pontos(linhas)
    pontos_validos, pontos_invalidos = validar_lote(pontos, FortalezaPonto)

    chave_linhas = escrever_bronze("fortaleza", "linhas", linhas_validas)
    chave_pontos = escrever_bronze("fortaleza", "pontos", pontos_validos)

    resultado = {
        "praca": "fortaleza",
        "linhas": {"total_recebido": len(linhas), "total_valido": len(linhas_validas), "total_invalido": len(linhas_invalidas), "s3_key": chave_linhas},
        "pontos": {
            "total_valido": len(pontos_validos),
            "total_invalido": len(pontos_invalidos),
            "s3_key": chave_pontos,
            "linhas_sem_itinerario": len(codigos_sem_itinerario),
        },
        "duracao_s": round(time.monotonic() - inicio, 2),
    }

    if linhas_invalidas:
        logger.warning("linhas invalidas descartadas", extra={"total_invalido": len(linhas_invalidas), "amostra": linhas_invalidas[:3]})
    if codigos_sem_itinerario:
        logger.warning("linhas sem itinerario (API da ETUFOR)", extra={
            "total": len(codigos_sem_itinerario),
            "codigos": codigos_sem_itinerario[:20],
        })
    if pontos_invalidos:
        logger.warning("pontos invalidos descartados", extra={"total_invalido": len(pontos_invalidos), "amostra": pontos_invalidos[:3]})

    logger.info("coleta de cadastro concluida", extra=resultado)
    return resultado
