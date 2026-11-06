import requests

BASE_URL = "http://gistapis.etufor.ce.gov.br:8081/api"


def buscar_linhas():
    resposta = requests.get(f"{BASE_URL}/linhas/")
    return resposta.json()


def buscar_itinerario(codigo_linha):
    resposta = requests.get(f"{BASE_URL}/itinerario/{codigo_linha}")
    return resposta.json()


def buscar_horarios(codigo_linha, data):
    resposta = requests.get(f"{BASE_URL}/horarios/{codigo_linha}", params={"data": data})
    return resposta.json()


def buscar_logradouros():
    resposta = requests.get(f"{BASE_URL}/logradouros/")
    return resposta.json()


def buscar_linhas_por_logradouro(codigo_logradouro):
    resposta = requests.get(f"{BASE_URL}/LinhasDologradouro/{codigo_logradouro}")
    return resposta.json()
