import csv
import os


def escrever_csv(caminho, linhas):
    os.makedirs(os.path.dirname(caminho), exist_ok=True)

    if not linhas:
        open(caminho, "w").close()
        return

    with open(caminho, "w", newline="", encoding="utf-8") as arquivo:
        escritor = csv.DictWriter(arquivo, fieldnames=list(linhas[0].keys()))
        escritor.writeheader()
        escritor.writerows(linhas)
