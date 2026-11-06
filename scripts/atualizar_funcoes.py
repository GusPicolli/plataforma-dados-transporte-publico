"""Forca as Lambdas a adotarem a imagem :latest que esta no ECR agora.

Por que isto nao e trabalho do Terraform: a Lambda resolve a TAG para um
DIGEST no momento em que o codigo da funcao e atualizado, e guarda o digest.
Como a string `image_uri` no Terraform continua sendo ".../lambda:latest"
depois de um push, o plan nao acusa diferenca nenhuma -- e as funcoes seguem
rodando a imagem antiga.

Medido neste projeto: depois de dois pushes no mesmo dia, a funcao heartbeat
continuava servindo uma imagem de 18 dias antes, porque nada no seu bloco
Terraform havia mudado. Pior, funcoes atualizadas pelo Terraform por outro
motivo (mudanca de variavel de ambiente) pegaram a imagem nova, enquanto as
intocadas nao -- o mesmo deploy em dois estados diferentes.

A correcao de verdade e tag imutavel por SHA do commit, que torna este script
desnecessario. Enquanto a tag for `latest`, ele e obrigatorio depois de todo
push -- e por isso `make deploy` ja o executa."""

import json
import subprocess
import sys

import boto3

DIRETORIO_TERRAFORM = "infra/terraform"


def _saida_terraform(nome):
    resultado = subprocess.run(
        ["terraform", f"-chdir={DIRETORIO_TERRAFORM}", "output", "-json", nome],
        capture_output=True,
        text=True,
    )
    if resultado.returncode != 0:
        print(
            f"Nao consegui ler a saida '{nome}' do Terraform. "
            f"A infraestrutura ja foi aplicada? (make tf-apply)\n{resultado.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(2)
    return json.loads(resultado.stdout)


def main():
    funcoes = _saida_terraform("funcoes_lambda")
    repositorio = _saida_terraform("ecr_repository_url")
    uri = f"{repositorio}:latest"

    # funcoes_lambda cobre so as 5 de ingestao; silver e heartbeat tem
    # recursos proprios e nao entram naquele for_each.
    nomes = sorted(set(funcoes.values()))
    projeto = nomes[0].rsplit("-", 2)[0] if nomes else "onibus-tempo-real"
    nomes += [f"{projeto}-silver", f"{projeto}-heartbeat"]

    lam = boto3.client("lambda")

    print(f"Apontando {len(nomes)} funcao(oes) para {uri}")
    for nome in nomes:
        try:
            lam.update_function_code(FunctionName=nome, ImageUri=uri)
            print(f"  atualizando  {nome}")
        except lam.exceptions.ResourceNotFoundException:
            print(f"  NAO EXISTE   {nome} (ignorado)")
            nomes = [n for n in nomes if n != nome]

    esperar = lam.get_waiter("function_updated_v2")
    for nome in nomes:
        esperar.wait(FunctionName=nome)

    print("\nTodas as funcoes estao servindo a imagem atual.")


if __name__ == "__main__":
    main()
