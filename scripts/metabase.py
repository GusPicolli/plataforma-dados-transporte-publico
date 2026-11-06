"""Sobe o Metabase local ja conectado ao Athena, pronto pra montar dashboard.

Roda na SUA maquina. O Athena e acessivel de fora da AWS, entao nao ha motivo
pra pagar um container 24/7 na nuvem enquanto so voce usa -- um Metabase
hospedado seria o item mais caro do projeto inteiro.

Tres coisas que so se descobre tentando, e que motivam este script existir em
vez de um "docker run" no Makefile:

1. O Git Bash converte caminho absoluto. "/metabase-dados" virava
   "C:/Program Files/Git/metabase-dados" e o Metabase nao subia ("Unable to
   connect to Metabase h2 DB"). Chamando o docker por lista de argumentos,
   sem shell no meio, isso nao acontece.

2. O arquivo ~/.aws/credentials do "aws configure" no Windows usa CRLF, e o
   SDK Java da AWS nao reconhece a secao "[default]\\r".

3. Mesmo com o arquivo corrigido e montado em /root/.aws, com
   AWS_SHARED_CREDENTIALS_FILE apontando pra ele, o driver continuou
   reportando ProfileFile(sections=[]). A cadeia de credenciais simplesmente
   nao funcionou nesta combinacao de imagem e driver.

Por isso a conexao usa chave explicita, que e o que a propria interface do
Metabase oferece. A chave fica guardada no banco local dele -- a mesma chave
que ja esta em texto plano no seu ~/.aws/credentials, na mesma maquina."""

import json
import pathlib
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

import boto3

CONTAINER = "onibus-metabase"
VOLUME = "onibus-metabase-dados"
IMAGEM = "metabase/metabase:latest"
PORTA = 3000
BASE = f"http://localhost:{PORTA}"

EMAIL = "local@onibus.dev"
SENHA = "OnibusLocal#2026"
MAX_ESPERA_S = 240


def _api(caminho, dados=None, sessao=None, metodo=None):
    pedido = urllib.request.Request(
        BASE + caminho,
        data=json.dumps(dados).encode() if dados is not None else None,
        method=metodo or ("POST" if dados is not None else "GET"),
    )
    pedido.add_header("Content-Type", "application/json")
    if sessao:
        pedido.add_header("X-Metabase-Session", sessao)
    with urllib.request.urlopen(pedido, timeout=300) as resposta:
        corpo = resposta.read().decode()
        return json.loads(corpo) if corpo else {}


def _terraform(nome):
    r = subprocess.run(
        ["terraform", "-chdir=infra/terraform", "output", "-raw", nome],
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


def _container_existe():
    r = subprocess.run(
        ["docker", "ps", "-aq", "-f", f"name=^{CONTAINER}$"], capture_output=True, text=True
    )
    return bool(r.stdout.strip())


def _subir_container():
    if _container_existe():
        subprocess.run(["docker", "start", CONTAINER], capture_output=True)
        print("Religando o container existente (dashboards preservados).")
        return

    r = subprocess.run(
        [
            "docker", "run", "-d",
            "--name", CONTAINER,
            "-p", f"{PORTA}:3000",
            # Volume nomeado: sem ele, remover o container apaga todos os
            # dashboards, que ficam num H2 dentro da imagem.
            "-v", f"{VOLUME}:/metabase-dados",
            "-e", "MB_DB_FILE=/metabase-dados/metabase.db",
            IMAGEM,
        ],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    print("Container criado.")


def _esperar_no_ar():
    inicio = time.monotonic()
    while time.monotonic() - inicio < MAX_ESPERA_S:
        try:
            with urllib.request.urlopen(f"{BASE}/api/health", timeout=3) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        time.sleep(3)
    return False


def _sessao():
    propriedades = _api("/api/session/properties")
    if not propriedades.get("has-user-setup"):
        print("Criando a conta de administrador local...")
        return _api(
            "/api/setup",
            {
                "token": propriedades["setup-token"],
                "user": {
                    "first_name": "Gustavo",
                    "last_name": "Local",
                    "email": EMAIL,
                    "password": SENHA,
                    "site_name": "Onibus Tempo Real",
                },
                "prefs": {"site_name": "Onibus Tempo Real", "allow_tracking": False},
            },
        )["id"]
    return _api("/api/session", {"username": EMAIL, "password": SENHA})["id"]


def _garantir_bancos(sessao):
    existentes = _api("/api/database", sessao=sessao)
    existentes = existentes["data"] if isinstance(existentes, dict) else existentes
    ja_tem = {b["name"] for b in existentes}

    credencial = boto3.Session().get_credentials()
    if credencial is None:
        print("Sem credencial AWS local. Rode 'aws configure'.", file=sys.stderr)
        sys.exit(2)
    credencial = credencial.get_frozen_credentials()

    bucket = _terraform("bucket_dados")
    workgroup = _terraform("athena_workgroup")

    alvos = [
        ("Onibus - gold", _terraform("athena_database_gold")),
        ("Onibus - silver", _terraform("athena_database")),
    ]

    for nome, banco in alvos:
        if nome in ja_tem:
            print(f"  ja configurado: {nome}")
            continue
        try:
            criado = _api(
                "/api/database",
                {
                    "engine": "athena",
                    "name": nome,
                    "details": {
                        "region": "us-east-1",
                        "workgroup": workgroup,
                        "s3_staging_dir": f"s3://{bucket}/athena-results/",
                        "db": banco,
                        "access_key": credencial.access_key,
                        "secret_key": credencial.secret_key,
                    },
                },
                sessao=sessao,
            )
            print(f"  conectado: {nome}  ->  {banco}")
            _api(f"/api/database/{criado['id']}/sync_schema", {}, sessao=sessao)
        except urllib.error.HTTPError as erro:
            print(f"  FALHOU {nome}: {erro.read().decode()[:200]}", file=sys.stderr)


def main():
    if shutil.which("docker") is None:
        print("Docker nao encontrado no PATH.", file=sys.stderr)
        sys.exit(2)

    _subir_container()
    print("Aguardando subir (a primeira vez leva ~1 min)...")
    if not _esperar_no_ar():
        print(f"Nao respondeu em {MAX_ESPERA_S}s. Veja: docker logs {CONTAINER}", file=sys.stderr)
        sys.exit(1)

    sessao = _sessao()
    print("\nConferindo as conexoes com o Athena:")
    _garantir_bancos(sessao)

    print(f"\n  Metabase:  {BASE}")
    print(f"  Usuario:   {EMAIL}")
    print(f"  Senha:     {SENHA}   <- troque em Settings > Account")
    print("\nComece por 'Onibus - gold': gold_dim_linhas, gold_dim_pontos,")
    print("gold_posicoes -- ja com fuso corrigido e chave de juncao pronta.")
    print("\n'make metabase-stop' para. Os dashboards ficam salvos.")


if __name__ == "__main__":
    main()
