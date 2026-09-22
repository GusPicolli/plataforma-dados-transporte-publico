"""Diagnostico de ambiente: diz o que ja da pra rodar agora e o que falta.

A ideia e que alguem que nunca pegou o projeto consiga responder "por que
isso nao funciona?" sem precisar ler codigo. Roda com `make check`."""

import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent


def _tem_modulo(nome):
    return importlib.util.find_spec(nome) is not None


def _token_sptrans():
    env = RAIZ / ".env"
    if not env.exists():
        return None
    for linha in env.read_text(encoding="utf-8").splitlines():
        if linha.startswith("SPTRANS_TOKEN="):
            valor = linha.split("=", 1)[1].strip()
            # o .env.example vem com placeholder -- nao conta como configurado
            return valor if valor and valor != "seu_token_aqui" else None
    return None


def _docker_rodando():
    if shutil.which("docker") is None:
        return False
    try:
        return subprocess.run(
            ["docker", "info"], capture_output=True, timeout=15
        ).returncode == 0
    except Exception:
        return False


def _credencial_aws():
    if os.environ.get("AWS_ACCESS_KEY_ID"):
        return True
    return (Path.home() / ".aws" / "credentials").exists()


def main():
    deps_base = all(_tem_modulo(m) for m in ("requests", "dotenv"))
    deps_realtime = all(_tem_modulo(m) for m in ("redis", "fastapi", "uvicorn"))
    deps_lambda = all(_tem_modulo(m) for m in ("pydantic", "tenacity", "pyarrow", "boto3"))
    token = _token_sptrans()
    docker = _docker_rodando()
    aws = _credencial_aws()

    print(f"Python {sys.version.split()[0]}")
    print()
    print("O QUE JA DA PRA RODAR AGORA")

    pronto = []
    bloqueado = []

    if deps_base:
        pronto.append(("make run-rio", "coleta o Rio inteiro (~7s), grava em output/rio/"))
        pronto.append(("make run-fortaleza", "coleta Fortaleza (~2min), grava em output/fortaleza/"))
    else:
        bloqueado.append(("make run-rio", "faltam dependencias -> rode: make setup"))

    if deps_base and token:
        pronto.append(("make run-sptrans", "coleta SP inteiro (~6s), grava em output/sptrans/"))
    else:
        motivo = "faltam dependencias -> make setup" if not deps_base else (
            "falta SPTRANS_TOKEN no .env -> pegue um gratis em "
            "https://www.sptrans.com.br/desenvolvedores/"
        )
        bloqueado.append(("make run-sptrans", motivo))

    if deps_realtime and docker:
        pronto.append(("make realtime-redis", "exercicio de tempo real (ver README)"))
    else:
        motivo = "falta o Docker rodando" if deps_realtime else "faltam dependencias -> make setup"
        bloqueado.append(("make realtime-*", motivo))

    if docker:
        pronto.append(("make docker-build", "builda a imagem das Lambdas"))
    else:
        bloqueado.append(("make docker-build", "falta o Docker rodando"))

    for cmd, desc in pronto:
        print(f"  [ok] {cmd:<24} {desc}")
    print()
    print("O QUE FALTA CONFIGURAR")
    if not bloqueado:
        print("  nada -- ambiente completo")
    for cmd, motivo in bloqueado:
        print(f"  [--] {cmd:<24} {motivo}")

    print()
    print("EXTRAS")
    print(
        "  dependencias das Lambdas  "
        + ("instaladas" if deps_lambda else "faltando -> make setup")
        + " (so pra importar os handlers direto no Python; via Docker elas ja estao na imagem)"
    )
    print(
        "  credencial AWS            "
        + ("configurada" if aws else "ausente -> aws configure")
        + " (so pra mexer na infra; nada disso e necessario pra rodar local)"
    )


if __name__ == "__main__":
    main()
