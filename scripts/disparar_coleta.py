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


def main():
    grupo = (sys.argv[1] if len(sys.argv) > 1 else "posicoes").strip().lower()
    if grupo not in GRUPOS:
        print(f"Grupo invalido: {grupo!r}. Use: {' ou '.join(GRUPOS)}", file=sys.stderr)
        sys.exit(1)

    agendador = boto3.client("scheduler", region_name=REGIAO)
    nome = f"{PROJETO}-coleta-{grupo}"
    try:
        agenda = agendador.get_schedule(Name=nome)
    except agendador.exceptions.ResourceNotFoundException:
        print(f"Agendamento {nome!r} nao existe. A infraestrutura esta aplicada?", file=sys.stderr)
        sys.exit(1)

    alvo = agenda["Target"]
    arn_fluxo = alvo["Arn"]
    entrada = alvo.get("Input", "{}")

    fontes = [f["funcao"] for f in json.loads(entrada).get("fontes", [])]
    print(f"\nDisparando a coleta de {grupo} ({len(fontes)} fonte(s)):")
    for f in fontes:
        print(f"  - {f}")

    execucao = boto3.client("stepfunctions", region_name=REGIAO).start_execution(
        stateMachineArn=arn_fluxo,
        input=entrada,
    )
    arn = execucao["executionArn"]

    print(f"\nExecucao iniciada: {arn.rsplit(':', 1)[-1]}")
    print("\nAcompanhe em:")
    print(
        f"  https://{REGIAO}.console.aws.amazon.com/states/home"
        f"?region={REGIAO}#/v2/executions/details/{arn}"
    )
    print("\nO grafo atualiza sozinho. Terminado, 'make status' mostra o dado novo.")

    if agenda["State"] == "DISABLED":
        print(
            "\nObs.: o agendamento esta DESLIGADO -- esta execucao e avulsa.\n"
            "      Pra coletar sozinho em horario comercial: make tf-ligar"
        )


if __name__ == "__main__":
    main()
