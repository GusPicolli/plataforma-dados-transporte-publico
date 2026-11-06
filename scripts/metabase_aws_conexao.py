"""Imprime os valores pra conectar o Metabase da AWS ao Athena.

Diferente do Metabase local, aqui NAO se digita chave de acesso: a instancia
tem um instance profile e o driver pega credencial temporaria sozinho. Era
justamente isso que nao funcionava no container local."""

import subprocess
import sys


def _saida(nome):
    r = subprocess.run(
        ["terraform", "-chdir=infra/terraform", "output", "-raw", nome],
        capture_output=True,
        text=True,
    )
    return r.stdout.strip() if r.returncode == 0 else "(indisponivel)"


def main():
    url = _saida("metabase_url")
    if url.startswith("("):
        print("A instancia esta desligada. Rode: make metabase-aws-ligar", file=sys.stderr)
        sys.exit(1)

    print(f"\n  Metabase:  {url}\n")
    print("Admin > Databases > Add database > Amazon Athena\n")
    print(f"  Region                          us-east-1")
    print(f"  Workgroup                       {_saida('athena_workgroup')}")
    print(f"  S3 staging directory            s3://{_saida('bucket_dados')}/athena-results/")
    print(f"  Database                        {_saida('athena_database_gold')}      <- comece por aqui")
    print(f"                                  {_saida('athena_database')}  (a silver crua)")
    print("  Catalog                         deixe em branco")
    print("  Use Default Credentials Chain   SIM  <- e NAO preencha chave nenhuma\n")
    print("A caixa de credencial padrao faz o driver usar o instance profile")
    print("da EC2. Nenhuma chave e digitada nem fica guardada no banco dele --")
    print("ao contrario do Metabase local, onde a cadeia nao funcionou.")


if __name__ == "__main__":
    main()
