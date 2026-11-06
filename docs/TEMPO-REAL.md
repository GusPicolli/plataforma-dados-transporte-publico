# Tempo real — o exercício e os conceitos

Os pipelines acima são em lote: rodam, escrevem um CSV, terminam. O módulo
`exemplos/realtime/` é um exercício pessoal, **fora do caminho de
produção** (esse é `lambdas/` + `infra/`, ver seção abaixo) — a mesma ideia
de ingestão, mas como um fluxo contínuo, só para SP e Rio (as praças com
posição em tempo real). Fortaleza não entra aqui por não ter essa fonte.
Fica em `exemplos/` de propósito, separado do que é pensado pra rodar em
produção, pra ficar claro o que é uma coisa e o que é outra.

### Os conceitos

- **Producer** (`producer_sp.py`, `producer_rio.py`) — só sabe consultar a
  fonte e publicar cada posição como uma mensagem. Não sabe (nem precisa
  saber) quem vai ler, nem o que vai ser feito com o dado.
- **Broker** (Redis, rodando à parte) — a fila/canal no meio. É o que permite
  producer e consumer rodarem em processos diferentes, em ritmos diferentes,
  sem um conhecer o outro diretamente.
- **Consumer** (`consumer.py`) — assina o canal, recebe cada mensagem e
  materializa a "última posição conhecida" de cada veículo num hash do
  Redis. É a ponte entre o fluxo de eventos e um estado consultável.
- **API** (`api.py`) — só lê esse hash. Não sabe nada sobre producer/broker;
  para ela, é só um dado que já está lá, pronto.

Esse desenho (producer → broker → consumer → estado materializado → leitura)
é o mesmo padrão geral de sistemas maiores como Kafka — aqui só trocamos o
broker por Redis Pub/Sub, que é mais simples de rodar e de entender primeiro.

**Sobre "tempo real" e "5 segundos":** nenhuma das fontes empurra dado pra
nós — continuamos fazendo *polling* (perguntando de novo e de novo), só que
rápido. E cada veículo só manda um novo ping de GPS a cada ~30s (confirmado
nos dados: ver campo `ta` na SPTrans e `datetime` no Rio). Então "5 segundos
de latência" aqui significa **o tempo entre a fonte ter um dado novo e a
nossa API conseguir servir esse dado** — não que a posição do ônibus vai
mudar visualmente a cada 5s. Se o producer consulta mais rápido do que a
fonte atualiza, boa parte das consultas simplesmente vai repetir o mesmo
dado — isso é esperado, não é bug.

### Como rodar

Precisa de um Redis rodando (usei Docker, mas qualquer Redis local serve) e
5 processos separados, cada um no seu terminal:

```bash
docker run -d --name realtime-redis -p 6379:6379 redis:7-alpine   # broker

python -m exemplos.realtime.producer_sp     # publica posicoes de SP
python -m exemplos.realtime.producer_rio    # publica posicoes do Rio
python -m exemplos.realtime.consumer        # materializa a ultima posicao de cada veiculo
python -m uvicorn exemplos.realtime.api:app --reload --port 8000   # GET /posicoes/sp, /posicoes/rio
```

ou via Makefile: `make realtime-redis`, `make realtime-producer-sp`,
`make realtime-producer-rio`, `make realtime-consumer`, `make realtime-api`.

Por padrão cada producer publica **todos os veículos da cidade** — pra SP
isso é ~5.000 mensagens a cada ciclo, difícil de acompanhar no terminal.
Pra um primeiro teste, filtre por uma linha específica:

```bash
SP_FILTRO_LETREIRO="3459-10" python -m exemplos.realtime.producer_sp   # letreiro com sentido, ex: "3459-10"
RIO_FILTRO_SERVICO="497" python -m exemplos.realtime.producer_rio      # so o numero do servico
```

Variáveis de ambiente aceitas: `SP_INTERVALO_SEGUNDOS` / `RIO_INTERVALO_SEGUNDOS`
(padrão 5s), `SP_FILTRO_LETREIRO`, `RIO_FILTRO_SERVICO`, `REDIS_HOST` /
`REDIS_PORT` (padrão `localhost:6379`).

Com tudo rodando:

```bash
curl http://127.0.0.1:8000/posicoes/sp              # todas as posicoes conhecidas em SP
curl http://127.0.0.1:8000/posicoes/rio/B31066       # uma posicao especifica no Rio
```

### Limitações conhecidas (é um exercício, não é produção)

- Redis Pub/Sub **não persiste**: se o consumer estiver fora do ar quando o
  producer publica, essa mensagem se perde (o hash de estado não atualiza,
  mas nada quebra). Um broker baseado em log — Redis Streams ou Kafka — guarda
  as mensagens e permite reprocessar; é o passo natural depois de entender
  este exercício.
- Sem reconexão automática se o Redis cair no meio da execução.
- SPTrans: sessão de cookie sem renovação proativa — o producer só
  reautentica quando uma chamada falha.
