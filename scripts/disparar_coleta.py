"""Dispara uma coleta agora, sem esperar o agendamento.

A coleta so roda das 8h as 16h59 em dia util. Fora dessa janela -- numa
demonstracao a noite, por exemplo -- nao existe execucao nenhuma pra mostrar
no console, e o Step Functions aparece vazio.

A entrada NAO e montada aqui: ela e lida do proprio agendamento no
EventBridge. Assim a execucao disparada na mao e indistinguivel de uma
agendada, e fonte nova entra sozinha -- se alguem acrescentar uma praca, o
agendamento passa a cita-la e este script a dispara junto, sem alteracao.
"""

import json
import sys

import boto3

REGIAO = "us-east-1"
PROJETO = "onibus-tempo-real"
GRUPOS = ("posicoes", "cadastro")


def _disparar(agendador, fluxos, grupo):
    """Starta o fluxo com a MESMA entrada que o agendamento usaria."""
    nome = f"{PROJETO}-coleta-{grupo}"
    try:
        agenda = agendador.get_schedule(Name=nome)
    except agendador.exceptions.ResourceNotFoundException:
        print(f"Agendamento {nome!r} nao existe. A infraestrutura esta aplicada?", file=sys.stderr)
        sys.exit(1)

    alvo = agenda["Target"]
    entrada = alvo.get("Input", "{}")
    fontes = [f["funcao"] for f in json.loads(entrada).get("fontes", [])]

    print(f"\n{grupo.upper()} ({len(fontes)} fonte(s)):")
    for f in fontes:
        print(f"  - {f}")

    arn = fluxos.start_execution(stateMachineArn=alvo["Arn"], input=entrada)["executionArn"]
    print(f"  execucao: {arn.rsplit(':', 1)[-1]}")
    print(
        f"  https://{REGIAO}.console.aws.amazon.com/states/home"
        f"?region={REGIAO}#/v2/executions/details/{arn}"
    )
    return agenda["State"], arn


def main():
    # Sem argumento, dispara TUDO. O padrao antes era so "posicoes", e isso
    # enganava: a gold depende de linhas e pontos, que vem do cadastro --
    # entao coletar so posicoes deixava dim_linhas e dim_pontos vazias, e os
    # modelos do dbt devolviam zero linha sem erro nenhum.
    pedido = (sys.argv[1] if len(sys.argv) > 1 else "todos").strip().lower()

    if pedido in ("todos", "tudo", "all"):
        grupos = list(GRUPOS)
    elif pedido in GRUPOS:
        grupos = [pedido]
    else:
        print(f"Grupo invalido: {pedido!r}. Use: todos, {' ou '.join(GRUPOS)}", file=sys.stderr)
        sys.exit(1)

    agendador = boto3.client("scheduler", region_name=REGIAO)
    fluxos = boto3.client("stepfunctions", region_name=REGIAO)

    print(f"Disparando: {', '.join(grupos)}")
    estados = [_disparar(agendador, fluxos, g)[0] for g in grupos]

    print("\nO grafo atualiza sozinho. Terminado, 'make status' mostra o dado novo.")
    if "cadastro" in grupos:
        print("Pra a camada gold enxergar o dado novo, rode depois: make dbt-build")

    if any(e == "DISABLED" for e in estados):
        print(
            "\nObs.: os agendamentos estao DESLIGADOS -- estas execucoes sao avulsas.\n"
            "      Pra coletar sozinho em horario comercial: make tf-ligar"
        )


if __name__ == "__main__":
    main()
