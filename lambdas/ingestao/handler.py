"""Handler unico das 5 funcoes de ingestao.

Qual fonte coletar vem da variavel de ambiente FONTE, definida por funcao no
Terraform (infra/terraform/lambda.tf). As 5 funcoes rodam a MESMA imagem e o
MESMO command -- o que muda entre elas e so essa variavel.

Antes isto eram cinco arquivos que diferiam em quatro linhas cada. O fluxo
-- coletar, validar, gravar, montar resultado, logar o que foi descartado --
era copia byte a byte nos cinco."""

import os
import time

from lambdas.common.logging_config import criar_logger
from lambdas.common.s3_writer import escrever_bronze
from lambdas.common.validation import validar_lote
from lambdas.ingestao.fontes import Contexto, obter_fonte

NOME_FONTE = os.environ.get("FONTE", "")
logger = criar_logger(NOME_FONTE.replace("_", "-") or "ingestao")


@logger.inject_lambda_context(log_event=False)
def lambda_handler(event, context):
    inicio = time.monotonic()

    # Resolve aqui, e nao na importacao, para que uma FONTE invalida falhe
    # dentro da invocacao -- com log estruturado e visivel na metrica Errors
    # -- em vez de quebrar no cold start, que e bem mais dificil de ler.
    fonte = obter_fonte(NOME_FONTE)
    praca = fonte["praca"]

    ctx = Contexto()
    resultado = {"praca": praca, "fonte": NOME_FONTE}

    # Lista plana das chaves gravadas. Existe pro orquestrador: o Step
    # Functions itera sobre ela pra chamar a silver, e iterar uma lista e
    # muito mais simples em ASL do que escarafunchar o dicionario aninhado.
    chaves = []

    for nome_entidade, coletar, modelo in fonte["entidades"]:
        registros = coletar(ctx)
        ctx.bruto[nome_entidade] = registros

        validos, invalidos = validar_lote(registros, modelo)
        chave_s3 = escrever_bronze(praca, nome_entidade, validos)

        chaves.append(chave_s3)
        resultado[nome_entidade] = {
            "total_recebido": len(registros),
            "total_valido": len(validos),
            "total_invalido": len(invalidos),
            "s3_key": chave_s3,
        }

        if invalidos:
            # Descartar registro ruim nunca derruba o lote -- mas tem que
            # deixar rastro, senao vira perda silenciosa de dado. A amostra
            # e o que permite descobrir o que mudou na origem.
            logger.warning(
                "registros invalidos descartados",
                extra={
                    "entidade": nome_entidade,
                    "total_invalido": len(invalidos),
                    "amostra": invalidos[:3],
                },
            )

    if ctx.extras:
        resultado.update(ctx.extras)
        logger.warning("coleta concluida com ressalvas", extra=ctx.extras)

    resultado["s3_keys"] = chaves
    resultado["duracao_s"] = round(time.monotonic() - inicio, 2)

    # ATENCAO: o formato destes dois logs e contrato com os metric filters em
    # infra/terraform/observabilidade.tf. O de volume casa
    # { $.entidade = "posicoes" && $.total_valido = * }, entao a fonte de uma
    # entidade so loga ACHATADA. Mudar os campos aqui exige mudar la.
    if len(fonte["entidades"]) == 1:
        nome_entidade = fonte["entidades"][0][0]
        logger.info(
            "coleta concluida",
            extra={
                "praca": praca,
                "entidade": nome_entidade,
                **resultado[nome_entidade],
                "duracao_s": resultado["duracao_s"],
            },
        )
    else:
        logger.info("coleta de cadastro concluida", extra=resultado)

    return resultado
