import sys

from dotenv import load_dotenv

from src.fortaleza_pipeline import PASTA_SAIDA as PASTA_SAIDA_FORTALEZA
from src.fortaleza_pipeline import rodar_pipeline as rodar_pipeline_fortaleza
from src.rio_pipeline import PASTA_SAIDA as PASTA_SAIDA_RIO
from src.rio_pipeline import rodar_pipeline as rodar_pipeline_rio
from src.sptrans_pipeline import PASTA_SAIDA as PASTA_SAIDA_SPTRANS
from src.sptrans_pipeline import rodar_pipeline as rodar_pipeline_sptrans

load_dotenv()


def _resumo(pasta_saida, contagens):
    print(f"\nTabelas geradas em {pasta_saida}/:")
    for tabela, total in contagens.items():
        print(f"  - {tabela}.csv: {total} linha(s)")


def main():
    cidade = sys.argv[1] if len(sys.argv) > 1 else "sptrans"

    if cidade == "sptrans":
        contagens = rodar_pipeline_sptrans()
        _resumo(PASTA_SAIDA_SPTRANS, contagens)
    elif cidade == "rio":
        contagens = rodar_pipeline_rio()
        _resumo(PASTA_SAIDA_RIO, contagens)
    elif cidade == "fortaleza":
        contagens = rodar_pipeline_fortaleza()
        _resumo(PASTA_SAIDA_FORTALEZA, contagens)
        print(
            "  - posicoes.csv: nao gerado (Fortaleza nao tem API publica de "
            "posicao em tempo real, veja README)"
        )
    else:
        print(
            f'Cidade "{cidade}" desconhecida. Use: sptrans, rio ou fortaleza.',
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as erro:
        print(f"Erro ao consultar a API: {erro}", file=sys.stderr)
        sys.exit(1)
