"""Roda uma consulta no Athena pela linha de comando.

Serve pra conferir dado rapido sem abrir o console -- e pra conferencia
automatizada, ja que imprime tabela e sai com codigo != 0 se a consulta
falhar.

Uso:
    make query SQL="SELECT praca, count(*) FROM posicoes GROUP BY praca"
    make query-gold SQL="SELECT * FROM gold_dim_linhas LIMIT 5"
    python scripts/consultar.py "SELECT ..." [--limite 50] [--camada gold]

O banco e o workgroup saem do terraform output, entao nao ha nada fixo aqui."""

import argparse
import json
import subprocess
import sys
import time

import boto3

DIRETORIO_TERRAFORM = "infra/terraform"
MAX_ESPERA_S = 300


def _saida_terraform(nome):
    r = subprocess.run(
        ["terraform", f"-chdir={DIRETORIO_TERRAFORM}", "output", "-raw", nome],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(
            f"Nao consegui ler '{nome}' do Terraform. A infra foi aplicada? (make tf-apply)",
            file=sys.stderr,
        )
        sys.exit(2)
    return r.stdout.strip()


def _executar(athena, sql, banco, workgroup):
    inicio = time.monotonic()
    execucao = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": banco},
        WorkGroup=workgroup,
    )["QueryExecutionId"]

    while True:
        detalhe = athena.get_query_execution(QueryExecutionId=execucao)["QueryExecution"]
        estado = detalhe["Status"]["State"]
        if estado in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return execucao, detalhe, estado
        if time.monotonic() - inicio > MAX_ESPERA_S:
            athena.stop_query_execution(QueryExecutionId=execucao)
            print(f"Consulta passou de {MAX_ESPERA_S}s e foi cancelada.", file=sys.stderr)
            sys.exit(1)
        time.sleep(1)


def _imprimir(linhas):
    """Tabela alinhada, com as colunas dimensionadas pelo conteudo."""
    if not linhas:
        print("(sem resultado)")
        return

    celulas = [[(c.get("VarCharValue") if c.get("VarCharValue") is not None else "NULL") for c in linha["Data"]] for linha in linhas]
    larguras = [min(max(len(linha[i]) for linha in celulas), 40) for i in range(len(celulas[0]))]

    for indice, linha in enumerate(celulas):
        print("  " + "  ".join(valor[:larg].ljust(larg) for valor, larg in zip(linha, larguras)))
        if indice == 0:
            print("  " + "  ".join("-" * larg for larg in larguras))


def main():
    parser = argparse.ArgumentParser(description="Consulta a camada silver via Athena.")
    parser.add_argument("sql", help="A consulta SQL.")
    parser.add_argument("--limite", type=int, default=50, help="Linhas a imprimir (padrao: 50).")
    parser.add_argument(
        "--camada",
        choices=["silver", "gold"],
        default="silver",
        help="Qual banco consultar (padrao: silver).",
    )
    args = parser.parse_args()

    banco = _saida_terraform(
        "athena_database" if args.camada == "silver" else "athena_database_gold"
    )
    workgroup = _saida_terraform("athena_workgroup")
    athena = boto3.client("athena")

    execucao, detalhe, estado = _executar(athena, args.sql, banco, workgroup)

    if estado != "SUCCEEDED":
        print(f"{estado}: {detalhe['Status'].get('StateChangeReason', '')}", file=sys.stderr)
        sys.exit(1)

    estatisticas = detalhe["Statistics"]
    varrido_mb = estatisticas["DataScannedInBytes"] / 1024 / 1024
    segundos = estatisticas["TotalExecutionTimeInMillis"] / 1000

    resultado = athena.get_query_results(QueryExecutionId=execucao, MaxResults=min(args.limite + 1, 1000))
    _imprimir(resultado["ResultSet"]["Rows"][: args.limite + 1])

    # Athena cobra por byte VARRIDO, nao por linha devolvida -- por isso o
    # numero que importa aqui e esse, e nao a contagem de resultados.
    print(f"\n{varrido_mb:.2f} MB varridos em {segundos:.1f}s (US$ 5,00 por TB varrido)")


if __name__ == "__main__":
    main()
