"""CLI dos pipelines em lote.

Uso: python main.py [sptrans|rio|fortaleza]    (padrao: sptrans)"""

import sys

from dotenv import load_dotenv

from coleta.pipelines import rodar

load_dotenv()


def main():
    praca = sys.argv[1] if len(sys.argv) > 1 else "sptrans"

    try:
        pasta_saida, contagens = rodar(praca)
    except KeyError as erro:
        print(erro.args[0], file=sys.stderr)
        sys.exit(1)

    print(f"\nTabelas geradas em {pasta_saida}/:")
    for tabela, total in contagens.items():
        print(f"  - {tabela}.csv: {total} linha(s)")

    if "posicoes" not in contagens:
        print(
            "  - posicoes.csv: nao gerado (Fortaleza nao tem API publica de "
            "posicao em tempo real, veja docs/FONTES.md)"
        )


if __name__ == "__main__":
    try:
        main()
    except Exception as erro:
        print(f"Erro ao consultar a API: {erro}", file=sys.stderr)
        sys.exit(1)
