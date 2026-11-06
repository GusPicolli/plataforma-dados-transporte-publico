"""Tabela declarativa das fontes de ingestao.

Antes existia um handler por funcao -- cinco arquivos que diferiam em quatro
linhas e repetiam o mesmo bloco de validar, gravar, montar resultado e logar.
Aqui fica so o que REALMENTE muda entre elas; o resto vive em handler.py.

Mesmo espirito de schemas/mapeamento_silver.py: fonte nova se resolve
acrescentando uma entrada nesta tabela, sem tocar no handler.

Cada entidade e uma tupla (nome, coletar, modelo):
  nome     -> vira o prefixo "entidade=" no S3
  coletar  -> funcao que recebe o Contexto e devolve a lista de registros crus
  modelo   -> model pydantic que valida cada registro

A ordem da lista importa: os pontos de Fortaleza dependem das linhas ja
coletadas, e leem isso do Contexto."""

from coleta import fortaleza, gtfs, rio, sptrans
from lambdas.common.retry import com_retry
from lambdas.common.secrets import obter_token_sptrans
from schemas.fortaleza import FortalezaLinha, FortalezaPonto
from schemas.rio import RioLinha, RioPonto, RioPosicao
from schemas.sptrans import SPTransLinha, SPTransPonto, SPTransPosicao

SENTIDOS_FORTALEZA = (("ida", "itinerarioIda"), ("volta", "itinerarioVolta"))


class Contexto:
    """Estado compartilhado entre as entidades de uma mesma execucao.

    Serve a dois casos reais: a sessao da SPTrans, que seria reautenticada
    uma vez por entidade sem isto, e os pontos de Fortaleza, que precisam
    das linhas coletadas no passo anterior."""

    def __init__(self):
        self.bruto = {}
        self.extras = {}
        self._cookies_sp = None

    def cookies_sptrans(self):
        if self._cookies_sp is None:
            self._cookies_sp = com_retry(sptrans.autenticar)(obter_token_sptrans())
        return self._cookies_sp


def _sp_posicoes(ctx):
    bruto = com_retry(sptrans.buscar_posicao_geral)(ctx.cookies_sptrans())
    return sptrans.flatten_posicao_geral(bruto)


def _sp_linhas(ctx):
    return com_retry(sptrans.buscar_todas_linhas)(ctx.cookies_sptrans())


def _sp_pontos(ctx):
    return com_retry(gtfs.SPTRANS.buscar_pontos_todas_linhas)()


def _rio_posicoes(ctx):
    # buscar_posicao_geral ja deduplica por veiculo: a API devolve o log bruto
    # de pings da janela, nao um retrato do momento (ver docs/FONTES.md).
    return com_retry(rio.buscar_posicao_geral)()


def _rio_linhas(ctx):
    return com_retry(gtfs.RIO.buscar_linhas)()


def _rio_pontos(ctx):
    return com_retry(gtfs.RIO.buscar_pontos_todas_linhas)()


def _fortaleza_linhas(ctx):
    return com_retry(fortaleza.buscar_linhas)()


def _fortaleza_pontos(ctx):
    """Uma chamada por linha -- a ETUFOR nao tem endpoint em lote. Linha sem
    itinerario (erro 500 conhecido e intermitente da API nao-oficial) e
    pulada, nao aborta a coleta das demais."""
    buscar = com_retry(fortaleza.buscar_itinerario)
    pontos = []
    sem_itinerario = []

    for linha in ctx.bruto["linhas"]:
        codigo_linha = linha["numero"]
        try:
            itinerario = buscar(codigo_linha)
        except Exception:
            itinerario = {}

        if "ida" not in itinerario and "volta" not in itinerario:
            sem_itinerario.append(codigo_linha)
            continue

        for sentido, chave_pontos in SENTIDOS_FORTALEZA:
            bloco = itinerario.get(sentido) or {}
            for ponto in bloco.get(chave_pontos, []):
                pontos.append(
                    {
                        "codigo_linha": codigo_linha,
                        "sentido": sentido,
                        "logId": ponto.get("logId"),
                        "nome": ponto.get("nome"),
                        "distanciaPercorrida": ponto.get("distanciaPercorrida"),
                    }
                )

    if sem_itinerario:
        ctx.extras["linhas_sem_itinerario"] = len(sem_itinerario)
        ctx.extras["codigos_sem_itinerario"] = sem_itinerario[:20]

    return pontos


FONTES = {
    "sp_posicoes": {
        "praca": "sp",
        "entidades": [("posicoes", _sp_posicoes, SPTransPosicao)],
    },
    "rio_posicoes": {
        "praca": "rio",
        "entidades": [("posicoes", _rio_posicoes, RioPosicao)],
    },
    "sp_cadastro": {
        "praca": "sp",
        "entidades": [
            ("linhas", _sp_linhas, SPTransLinha),
            ("pontos", _sp_pontos, SPTransPonto),
        ],
    },
    "rio_cadastro": {
        "praca": "rio",
        "entidades": [
            ("linhas", _rio_linhas, RioLinha),
            ("pontos", _rio_pontos, RioPonto),
        ],
    },
    "fortaleza_cadastro": {
        "praca": "fortaleza",
        "entidades": [
            ("linhas", _fortaleza_linhas, FortalezaLinha),
            # precisa vir depois de "linhas": le ctx.bruto["linhas"]
            ("pontos", _fortaleza_pontos, FortalezaPonto),
        ],
    },
}


def obter_fonte(nome):
    fonte = FONTES.get(nome)
    if fonte is None:
        raise KeyError(
            f'Fonte "{nome}" desconhecida. Defina a variavel de ambiente FONTE '
            f"com uma de: {', '.join(sorted(FONTES))}."
        )
    return fonte
