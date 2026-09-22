"""Responde "o pipeline esta rodando normalmente?" numa tela so.

Sem isto, a resposta exige abrir 4 lugares no console (Scheduler, Lambda,
CloudWatch, S3) e cruzar na cabeca. Aqui o criterio fica explicito: cada
pipeline esta OK se o agendamento esta ligado, nao houve erro nas ultimas
24h e o dado mais recente no S3 e mais novo que a cadencia esperada.

Uso: make status   (ou: python scripts/status_pipeline.py)"""

import datetime
import os
import sys

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

REGIAO = os.environ.get("AWS_REGION", "us-east-1")
PROJETO = os.environ.get("PROJECT_NAME", "onibus-tempo-real")

# Quanto tempo sem dado novo ainda e considerado normal, por pipeline.
# Nao e o intervalo do cron: e o intervalo + folga, porque um atraso de
# minutos e rotina e nao deveria acender alerta.
PIPELINES = {
    "sp_posicoes": {"praca": "sp", "entidades": ["posicoes"], "tolerancia_h": 24 * 8},
    "rio_posicoes": {"praca": "rio", "entidades": ["posicoes"], "tolerancia_h": 24 * 8},
    "sp_cadastro": {"praca": "sp", "entidades": ["linhas", "pontos"], "tolerancia_h": 26},
    "rio_cadastro": {"praca": "rio", "entidades": ["linhas", "pontos"], "tolerancia_h": 26},
    "fortaleza_cadastro": {"praca": "fortaleza", "entidades": ["linhas", "pontos"], "tolerancia_h": 26},
}

AGORA = datetime.datetime.now(datetime.timezone.utc)


def _bucket(s3):
    for balde in s3.list_buckets()["Buckets"]:
        if balde["Name"].startswith(PROJETO):
            return balde["Name"]
    return None


def _estado_agendamentos(scheduler):
    estados = {}
    for pagina in scheduler.get_paginator("list_schedules").paginate():
        for agenda in pagina["Schedules"]:
            detalhe = scheduler.get_schedule(Name=agenda["Name"])
            estados[agenda["Name"]] = {
                "estado": detalhe["State"],
                "cron": detalhe["ScheduleExpression"],
            }
    return estados


def _metricas_24h(cloudwatch, funcao):
    """Invocacoes e erros nas ultimas 24h, direto das metricas da Lambda
    (mais barato e mais confiavel que varrer log)."""
    resultado = {}
    for metrica in ("Invocations", "Errors"):
        ponto = cloudwatch.get_metric_statistics(
            Namespace="AWS/Lambda",
            MetricName=metrica,
            Dimensions=[{"Name": "FunctionName", "Value": funcao}],
            StartTime=AGORA - datetime.timedelta(hours=24),
            EndTime=AGORA,
            Period=86400,
            Statistics=["Sum"],
        )["Datapoints"]
        resultado[metrica] = int(sum(p["Sum"] for p in ponto))
    return resultado


def _mais_recente(s3, bucket, praca, entidade, camada):
    prefixo = f"{camada}/praca={praca}/entidade={entidade}/"
    mais_novo = None
    total = 0
    for pagina in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefixo):
        for obj in pagina.get("Contents", []):
            total += 1
            if mais_novo is None or obj["LastModified"] > mais_novo:
                mais_novo = obj["LastModified"]
    return mais_novo, total


def _idade(momento):
    if momento is None:
        return None
    return (AGORA - momento).total_seconds() / 3600


def _formatar_idade(horas):
    if horas is None:
        return "nunca"
    if horas < 1:
        return f"{int(horas * 60)}min atras"
    if horas < 48:
        return f"{horas:.1f}h atras"
    return f"{horas / 24:.1f}d atras"


def main():
    sessao = boto3.Session(region_name=REGIAO)
    s3 = sessao.client("s3")
    scheduler = sessao.client("scheduler")
    cloudwatch = sessao.client("cloudwatch")

    try:
        bucket = _bucket(s3)
    except NoCredentialsError:
        print("Sem credencial AWS configurada. Rode: aws configure", file=sys.stderr)
        return 2
    except ClientError as erro:
        print(f"Falha ao falar com a AWS: {erro}", file=sys.stderr)
        return 2

    if bucket is None:
        print(f'Nenhum bucket comecando com "{PROJETO}". A infra esta aplicada?', file=sys.stderr)
        return 2

    agendamentos = _estado_agendamentos(scheduler)

    print(f"Conta: {sessao.client('sts').get_caller_identity()['Account']}   regiao: {REGIAO}")
    print(f"Bucket: {bucket}")
    print(f"Agora: {AGORA.astimezone().strftime('%Y-%m-%d %H:%M %Z')}")
    print()

    problemas = []
    linhas = []

    for nome, config in PIPELINES.items():
        nome_agenda = f"{PROJETO}-{nome.replace('_', '-')}"
        agenda = agendamentos.get(nome_agenda, {})
        ligado = agenda.get("estado") == "ENABLED"

        metricas = _metricas_24h(cloudwatch, f"{PROJETO}-{nome.replace('_', '-')}")

        idade_pior = None
        for entidade in config["entidades"]:
            momento, _ = _mais_recente(s3, bucket, config["praca"], entidade, "bronze")
            idade = _idade(momento)
            if idade is None:
                idade_pior = None if idade_pior is None else idade_pior
                idade_pior = float("inf")
            elif idade_pior is None or idade > idade_pior:
                idade_pior = idade

        fresco = idade_pior is not None and idade_pior != float("inf") and idade_pior <= config["tolerancia_h"]

        if not ligado:
            situacao, detalhe = "PAUSADO", "agendamento desligado"
        elif metricas["Errors"] > 0:
            situacao, detalhe = "FALHA", f"{metricas['Errors']} erro(s) em 24h"
            problemas.append(f"{nome}: {detalhe}")
        elif not fresco:
            situacao, detalhe = "SEM DADO", "nada novo dentro da tolerancia"
            problemas.append(f"{nome}: {detalhe}")
        else:
            situacao, detalhe = "OK", "dentro do esperado"

        idade_txt = "nunca" if idade_pior in (None, float("inf")) else _formatar_idade(idade_pior)
        linhas.append((situacao, nome, idade_txt, metricas["Invocations"], metricas["Errors"], detalhe))

    print(f"{'':9} {'PIPELINE':<20} {'DADO MAIS NOVO':<16} {'EXEC/24h':>8} {'ERRO':>5}  OBS")
    for situacao, nome, idade_txt, execucoes, erros, detalhe in linhas:
        print(f"[{situacao:^7}] {nome:<20} {idade_txt:<16} {execucoes:>8} {erros:>5}  {detalhe}")

    print()
    print("SILVER (gerada automaticamente pelo evento do S3)")
    for praca, entidade in [("sp", "posicoes"), ("sp", "linhas"), ("sp", "pontos"),
                            ("rio", "posicoes"), ("rio", "linhas"), ("rio", "pontos"),
                            ("fortaleza", "linhas"), ("fortaleza", "pontos")]:
        bronze_em, bronze_n = _mais_recente(s3, bucket, praca, entidade, "bronze")
        silver_em, silver_n = _mais_recente(s3, bucket, praca, entidade, "silver")
        if bronze_n == 0 and silver_n == 0:
            continue
        atrasada = bronze_em and (silver_em is None or silver_em < bronze_em)
        marca = "!!" if atrasada else "ok"
        print(f"  [{marca}] {praca}/{entidade:<9} bronze: {bronze_n:>3} arquivo(s), "
              f"silver: {silver_n:>3}  ({_formatar_idade(_idade(silver_em))})")
        if atrasada:
            problemas.append(f"silver {praca}/{entidade}: bronze gravou e silver nao acompanhou")

    print()
    if problemas:
        print("PRECISA DE ATENCAO")
        for p in problemas:
            print(f"  - {p}")
        return 1

    pausados = [n for n, c in PIPELINES.items()
                if agendamentos.get(f"{PROJETO}-{n.replace('_', '-')}", {}).get("estado") != "ENABLED"]
    if pausados:
        print(f"Nada quebrado, mas {len(pausados)} pipeline(s) estao pausados "
              f"(agendamento_habilitado = false). Nenhum dado novo vai aparecer sozinho.")
        return 0

    print("Todos os pipelines OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
