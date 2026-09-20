import json

import requests
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

# Falha de rede (timeout, conexao recusada, DNS) ou resposta que nao e JSON
# valido (ex: pagina de erro HTML) sao os dois jeitos que ja vimos uma
# chamada dessas quebrar de forma transitoria. Erro de negocio (ex: token
# invalido, 500 pontual da ETUFOR que devolve JSON valido) nao entra aqui
# de proposito -- tentar de novo nao resolveria.
EXCECOES_COM_RETRY = (requests.exceptions.RequestException, json.JSONDecodeError)


def com_retry(func):
    """Decorator: ate 3 tentativas, com espera exponencial (1s, 2s, 4s)."""
    return retry(
        retry=retry_if_exception_type(EXCECOES_COM_RETRY),
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=1, max=8),
        reraise=True,
    )(func)
