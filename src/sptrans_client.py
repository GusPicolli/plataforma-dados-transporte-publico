import string

import requests

BASE_URL = "http://api.olhovivo.sptrans.com.br/v2.1"

# A API nao tem endpoint para listar todas as linhas de uma vez; Linha/Buscar
# exige um termo. Varrer todos os digitos e letras contra o letreiro cobre
# praticamente todo o cadastro (inclusive prefixos como "N" das noturnas).
TERMOS_VARREDURA = list(string.digits) + list(string.ascii_lowercase)


def autenticar(token):
    resposta = requests.post(f"{BASE_URL}/Login/Autenticar", params={"token": token})

    if resposta.json() is not True:
        raise RuntimeError(
            "Falha na autenticacao: token invalido ou nao autorizado pela SPTrans."
        )

    if not resposta.cookies:
        raise RuntimeError("Autenticacao nao retornou cookie de sessao.")

    return resposta.cookies


def buscar_linhas(cookies, termo_busca):
    resposta = requests.get(
        f"{BASE_URL}/Linha/Buscar", params={"termosBusca": termo_busca}, cookies=cookies
    )
    return resposta.json()


def buscar_paradas_por_linha(cookies, codigo_linha):
    resposta = requests.get(
        f"{BASE_URL}/Parada/BuscarParadasPorLinha",
        params={"codigoLinha": codigo_linha},
        cookies=cookies,
    )
    return resposta.json()


def buscar_posicao_linha(cookies, codigo_linha):
    resposta = requests.get(
        f"{BASE_URL}/Posicao/Linha", params={"codigoLinha": codigo_linha}, cookies=cookies
    )
    return resposta.json()


def buscar_posicao_geral(cookies):
    resposta = requests.get(f"{BASE_URL}/Posicao", cookies=cookies)
    return resposta.json()


def buscar_todas_linhas(cookies):
    linhas_por_codigo = {}
    for termo in TERMOS_VARREDURA:
        for linha in buscar_linhas(cookies, termo):
            linhas_por_codigo[linha["cl"]] = linha
    return list(linhas_por_codigo.values())


def flatten_posicao_geral(posicao_geral):
    """Achata a resposta de /Posicao (agrupada por linha) numa lista com um
    registro por veiculo. horario_referencia e o horario "hr" da resposta,
    nao o horario do ping do veiculo (esse e o campo horario_veiculo/ta)."""
    posicoes = []
    for linha in posicao_geral.get("l", []):
        for veiculo in linha.get("vs", []):
            posicoes.append(
                {
                    "codigo_linha": linha.get("cl"),
                    "letreiro": linha.get("c"),
                    "sentido": linha.get("sl"),
                    "origem": linha.get("lt0"),
                    "destino": linha.get("lt1"),
                    "qtd_veiculos_linha": linha.get("qv"),
                    "prefixo_veiculo": veiculo.get("p"),
                    "acessivel": veiculo.get("a"),
                    "horario_veiculo": veiculo.get("ta"),
                    "latitude": veiculo.get("py"),
                    "longitude": veiculo.get("px"),
                    "horario_referencia": posicao_geral.get("hr"),
                }
            )
    return posicoes
