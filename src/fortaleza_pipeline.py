from datetime import datetime, timezone

from src import fortaleza_client
from src.csv_utils import escrever_csv

PASTA_SAIDA = "output/fortaleza"

# A ETUFOR/Fortaleza nao tem API publica de posicao de veiculo em tempo real
# (ver README), entao este pipeline nao gera posicoes.csv.
SENTIDOS = (("ida", "itinerarioIda"), ("volta", "itinerarioVolta"))


def rodar_pipeline():
    coletado_em = datetime.now(timezone.utc).isoformat()

    print("Buscando todas as linhas...")
    linhas = fortaleza_client.buscar_linhas()
    for linha in linhas:
        linha["coletado_em"] = coletado_em
    escrever_csv(f"{PASTA_SAIDA}/linhas.csv", linhas)
    print(f"{len(linhas)} linha(s) encontrada(s).")

    print(f"Buscando itinerario de {len(linhas)} linha(s) (uma chamada por linha)...")
    pontos = []
    falhas = []
    for indice, linha in enumerate(linhas, start=1):
        codigo_linha = linha["numero"]
        try:
            itinerario = fortaleza_client.buscar_itinerario(codigo_linha)
        except Exception:
            itinerario = {}

        if "ida" not in itinerario and "volta" not in itinerario:
            # A API da ETUFOR e nao-oficial e retorna erro 500 (corpo tipo
            # {"Message": "..."}) para alguns codigos pontuais; pulamos a
            # linha em vez de abortar a coleta.
            falhas.append(codigo_linha)
            continue
        for sentido, chave_pontos in SENTIDOS:
            bloco = itinerario.get(sentido) or {}
            for ponto in bloco.get(chave_pontos, []):
                pontos.append(
                    {
                        "codigo_linha": codigo_linha,
                        "sentido": sentido,
                        "logId": ponto.get("logId"),
                        "nome": ponto.get("nome"),
                        "distanciaPercorrida": ponto.get("distanciaPercorrida"),
                        "coletado_em": coletado_em,
                    }
                )
        if indice % 100 == 0:
            print(f"  ... {indice}/{len(linhas)} linhas processadas")
    escrever_csv(f"{PASTA_SAIDA}/pontos.csv", pontos)
    if falhas:
        print(f"{len(falhas)} linha(s) sem itinerario (erro da API da ETUFOR): {falhas}")

    return {"linhas": len(linhas), "pontos": len(pontos)}
