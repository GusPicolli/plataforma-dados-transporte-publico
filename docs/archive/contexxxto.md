# Contexto: projeto `sptrans-olho-vivo-teste`

Projeto de teste que consulta a API Olho Vivo da SPTrans (linhas de ônibus, paradas e posição de veículos em tempo real).

## Histórico

1. Projeto originalmente em Node.js (`index.js` + `src/sptransClient.js`, usando `axios`). Foi migrado integralmente para Python a pedido do usuário.
2. Estrutura Python atual:
   - `main.py` — ponto de entrada, roda o fluxo de demonstração (autentica, busca linhas por termo, paradas da 1ª linha, posição dos veículos da linha, e total de veículos em circulação na cidade toda).
   - `src/sptrans_client.py` — funções que chamam a API: `autenticar`, `buscar_linhas`, `buscar_paradas_por_linha`, `buscar_posicao_linha`, `buscar_posicao_geral`.
   - `requirements.txt` (requests, python-dotenv), `.env.example` (`SPTRANS_TOKEN`), README atualizado.
   - Arquivos Node.js antigos e `node_modules` foram removidos.
3. Criado um `Makefile` com alvos `venv`, `install`, `run` (aceita `ARGS=termo`), `clean`.
4. `make` não estava disponível no Windows sem admin — foi instalado via **Scoop** (gerenciador de pacotes em espaço de usuário, sem precisar de privilégio admin), depois `scoop install make`. PATH do usuário atualizado automaticamente (precisa abrir um terminal novo para reconhecer o comando).
5. Discussão sobre a API Olho Vivo:
   - `GET /Posicao/Linha?codigoLinha=X` → posição dos veículos de uma linha específica.
   - `GET /Posicao` (sem parâmetros) → posição de **todos** os veículos em circulação, agrupados por linha.
   - A API **não** retorna bairro/cidade/região — só latitude/longitude (`px`/`py`). Para obter região seria necessário geocodificação reversa externa (ex: Nominatim/Google Maps).
   - Implementada `buscar_posicao_geral()` no cliente e ligada ao `main.py` para exibir o total de veículos ativos na cidade.
6. **Nota importante**: o usuário (ou um linter) alterou `autenticar()` em `sptrans_client.py` de `requests.get` para `requests.post` — mudança intencional, não reverter.
7. Nada foi executado de fato neste ambiente (sem Python instalado inicialmente / sem token real da SPTrans para testar), então validação em runtime ainda está pendente do lado do usuário.

## Estado atual

Projeto funcional em Python, aguardando teste real com `make install && make run` (ou `python main.py <termo>`).
