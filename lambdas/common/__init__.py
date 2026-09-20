# python-dotenv so entra em lambdas/requirements.txt (dev local), nao em
# requirements-layer.txt / na imagem de container -- producao nao tem .env
# e nao precisa da lib. Import opcional pra imagem publicada nao quebrar
# (bug real, pego rodando o container: import direto derrubava o modulo
# inteiro por falta de dotenv).
try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass
