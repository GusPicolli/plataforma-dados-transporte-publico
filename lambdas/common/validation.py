from pydantic import ValidationError


def validar_lote(registros, modelo):
    """Valida cada registro contra um model pydantic. Um registro invalido
    nao derruba o lote inteiro -- vai pra lista de invalidos com o motivo,
    e a coleta segue (mesmo principio ja usado pro erro 500 pontual da
    ETUFOR nos pipelines em lote: falha por item, nao por lote)."""
    validos = []
    invalidos = []
    for registro in registros:
        try:
            validos.append(modelo.model_validate(registro).model_dump())
        except ValidationError as erro:
            invalidos.append({"registro": registro, "erro": erro.errors()})
    return validos, invalidos
