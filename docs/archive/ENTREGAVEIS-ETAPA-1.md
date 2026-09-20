# Discovery e Proposta Técnica — Pipeline de Geolocalização para Mídia em Transporte

**Cliente:** empresa de mídia em transporte público (telões em ônibus)
**Praças:** Fortaleza, Rio de Janeiro e São Paulo
**Etapa:** 1 — Discovery, mapeamento de fontes e proposta de arquitetura
**Data:** 14/08/2026
**Base de evidências:** chamadas reais às três APIs, não leitura de documentação

---

## Sumário executivo

### O problema, na forma como o negócio o vive

O time de marketing precisa decidir **qual anúncio exibir em cada região**. Para isso
precisa saber por onde os veículos circulam. Nenhuma das APIs públicas de transporte
entrega "região" — todas entregam apenas latitude e longitude. **A tradução de coordenada
para região é o coração deste pipeline**, não um detalhe de enriquecimento.

### O que foi validado

As três fontes foram acessadas com chamadas reais e um protótipo funcional já coleta e
grava as três entidades por cidade:

| Praça | Linhas | Veículos em circulação | Pontos/trajeto | Posição em tempo real |
|---|---:|---:|---:|---|
| São Paulo (SPTrans) | 2.688 | 10.769 | 4.888 | ✅ |
| Rio de Janeiro (Data.Rio) | 498 | 3.378 | 52.505 | ✅ |
| Fortaleza (ETUFOR) | 539 | — | 19.398 | ❌ não existe |

### Três achados que mudam o escopo

1. **Fortaleza não publica posição de veículo.** Um terço das praças não tem o dado que o
   produto pressupõe. Há um caminho alternativo (Seção 2.4).
2. **30 minutos é incompatível com veiculação por posição instantânea.** Um ônibus percorre
   vários quilômetros nesse intervalo. Isso não é um defeito do requisito — indica que o
   pipeline serve **planejamento de inventário**, não decisão em tempo real. Precisa ser
   confirmado (**N2**).
3. **A ingenuidade no enriquecimento geográfico custaria ~US$ 1,2 milhão por ano.**
   Geocodificação reversa comercial a cada posição é inviável; o cruzamento espacial com
   malhas públicas custa praticamente zero (Seção 7.4).

### O que propomos

Arquitetura **agnóstica de nuvem**, operável por uma pessoa, com custo anual de
infraestrutura estimado em **US$ 180 a 300** — compatível com orçamento fixo. Implementação
em três ondas, **7 a 9 semanas** de uma pessoa, entregando São Paulo ponta a ponta já na
primeira onda.

---

## 1. Entendimento do problema de negócio

### 1.1 A cadeia de valor do dado

O dado só tem valor quando chega ao fim desta cadeia. Cada elo é uma etapa do pipeline:

```
Posição do veículo   →   Região         →   Perfil da região   →   Decisão de anúncio
(lat/long, das APIs)     (enriquecimento)   (dado do cliente)      (time de marketing)
      ✅ validado          ⚠️ a construir      ❓ não mapeado          fora do escopo
```

**O elo mais frágil não é a coleta — é a tradução de coordenada para região.** As APIs
resolvem o primeiro elo; o segundo é onde está o trabalho de engenharia e o risco de custo.

### 1.2 O que o dado precisa responder

Traduzindo a necessidade de marketing em perguntas que o modelo deve responder:

| Pergunta de negócio | O que exige do dado |
|---|---|
| Quais regiões a linha X atende? | Posição histórica agregada por linha e região |
| Quanto tempo a linha X passa na região Y? | Permanência (dwell time) por região — base de precificação de inventário |
| Quantos veículos circulam na região Y agora? | Posição corrente agregada por região |
| Qual o alcance potencial de um anúncio na região Y? | Veículos × permanência, cruzado com dado de audiência do cliente |
| Em que horários a região Y tem mais circulação? | Série temporal por região e faixa horária |

**Observação consultiva:** todas essas perguntas são de **planejamento**, e nenhuma exige
latência abaixo de 30 minutos. Isso é consistente com o requisito e reforça a leitura de
que o pipeline apoia decisão de inventário, não veiculação instantânea.

### 1.3 O questionamento central: 30 minutos serve para quê?

Vale explicitar uma tensão no requisito, porque ela determina a arquitetura.

Um ônibus urbano em deslocamento percorre entre 5 e 15 km em 30 minutos — atravessa vários
bairros. **Portanto uma posição com 30 minutos de defasagem não pode decidir qual anúncio
o telão mostra naquele instante.**

Duas leituras possíveis, com consequências arquiteturais opostas:

| Leitura | O que o pipeline entrega | Arquitetura |
|---|---|---|
| **A — Planejamento de inventário** (nossa hipótese) | Mapa de cobertura linha × região, permanência, sazonalidade | Lote a cada 30 min. É o que propomos |
| **B — Veiculação em tempo real** | Posição corrente por veículo, para decidir o anúncio no ar | Exigiria streaming e latência de segundos, não 30 min |

Se a decisão do anúncio acontece **no próprio telão**, que tem GPS embarcado, a leitura A é
suficiente e correta: o dispositivo sabe onde está; o pipeline diz ao marketing **o que
carregar** para cada linha. Essa é a arquitetura que propomos, e ela atende o requisito de
30 minutos com folga.

**Isto precisa ser confirmado antes da Onda 2** (**N2**). Seguimos com a leitura A como
padrão, porque é a única compatível com o requisito declarado.

### 1.4 Perguntas de negócio em aberto

| # | Pergunta | Por que é crítica | Padrão adotado se não houver resposta |
|---|---|---|---|
| **N1** | **O que é "região" para o negócio?** Bairro, setor censitário, zona de mídia própria, ou raio ao redor de um ponto? | Define toda a camada de enriquecimento e a granularidade de todo o produto | Bairro (malha pública IBGE), por ser padrão de mercado publicitário e gratuito |
| **N2** | A decisão do anúncio é no telão (GPS embarcado) ou centralizada? | Define se entregamos planejamento ou serving. Ver 1.3 | Planejamento — única leitura compatível com 30 min |
| **N3** | **Trens estão no escopo?** Nenhuma fonte validada cobre trilhos | Um modal inteiro do produto sem fonte de dados | Fora do escopo desta etapa; mapear fontes ferroviárias em etapa própria |
| **N4** | Fortaleza aceita granularidade de planejamento em vez de tempo real? | Sem posição, a praça só pode ser servida por itinerário | Sim — cobertura por itinerário (Seção 2.4) |
| **N5** | Existe dado de audiência ou demografia por região do lado do cliente? | É o que transforma cobertura em valor comercial | Assumimos que sim, e entregamos a chave de junção (código de região) |
| **N6** | Qual o valor exato do orçamento anual de infraestrutura? | Define margem de escolha arquitetural | Dimensionamos para o mínimo viável e reportamos o consumo |

---

## 2. Mapeamento e validação das fontes

Todos os números vêm de chamadas reais executadas em 14/08/2026.

### 2.1 Cobertura modal — a lacuna dos trens

| Praça | Fonte validada | Modal coberto | Trens/metrô |
|---|---|---|---|
| São Paulo | SPTrans Olho Vivo | Ônibus | ❌ CPTM e Metrô são operadores distintos, não mapeados |
| Rio de Janeiro | Data.Rio SPPO | Ônibus (tipos GTFS 700, 702, 200) | ❌ SuperVia e MetrôRio não estão no feed |
| Fortaleza | ETUFOR | Ônibus (Convencional, Complementar, Alimentadora, Troncal) | ❌ Metrofor não mapeado |

**Verificado nos metadados**, não presumido: o GTFS do Rio contém 498 rotas, todas de tipo
rodoviário; Fortaleza retorna 539 linhas, todas em categorias de ônibus.

**Consequência:** se telões em trens fazem parte do produto, **falta mapear três fontes
adicionais** — uma por praça. É trabalho de discovery não contemplado nesta etapa
(**N3**).

### 2.2 São Paulo — SPTrans Olho Vivo

**Base:** `http://api.olhovivo.sptrans.com.br/v2.1` · Autenticação por sessão:
`POST /Login/Autenticar?token=…` devolve `true` e um cookie reenviado nas chamadas
seguintes. Não há header de API key.

| Endpoint | Uso | Medido |
|---|---|---|
| `/Linha/Buscar?termosBusca=` | Linhas | 2.688 únicas |
| `/Posicao` | **Todas as posições, numa chamada** | 10.769 veículos |
| `/Parada/BuscarParadasPorLinha` | Paradas | 4.888 (só 634 linhas) |

**Achado — não existe endpoint "listar todas as linhas".** `Linha/Buscar` exige termo.
Contornamos varrendo os 36 termos `0-9` e `a-z` com deduplicação por código: 2.688 linhas
em ~2s. É heurística, não garantia (**R6**).

**Achado — cobertura de paradas incompleta.** Apenas **634 das 2.688 linhas** (23,6%)
retornam alguma parada. Re-testadas individualmente e com pausa, seguem vazias — não é
throttling. A linha 1012 retorna **zero paradas e quatro veículos circulando ao mesmo
tempo**.

> **Recalibração pelo contexto de negócio:** este achado era grave enquanto o objetivo era
> mapa de paradas. Para *cobertura de região*, o dado que importa é a **posição do
> veículo**, que está 100% disponível. As paradas são complemento. **O impacto cai de alto
> para baixo** — exemplo de por que a severidade de um achado técnico só se define contra
> o uso pretendido.

### 2.3 Rio de Janeiro — Data.Rio

O portal em ArcGIS Hub é o **catálogo**, não a API. Duas fontes reais:

**a) GPS em tempo real** — `GET https://dados.mobilidade.rio/gps/sppo`, sem autenticação.
Limites do gateway: **5 req/s e 60 req/min** — folgadíssimo para 48 chamadas por dia.

> ⚠️ **Armadilha crítica — falha silenciosa.** O formato é `MM-dd-yyyy HH:mm:ss`, mês antes
> do dia. Com data no formato brasileiro a API **retorna `[]` com HTTP 200**, sem erro.
> Uma pipeline ingênua gravaria vazio todos os dias sem alarme. Motiva o teste **QD-1**.

> ⚠️ **Não é snapshot, é log bruto de pings.** Janela de 5 min traz ~10 registros por
> veículo: **39.860 registros brutos = 3.378 veículos únicos**. Sem deduplicação a frota
> fica ~11× inflada. Já tratado no protótipo.

**b) GTFS oficial** — zip de ~25 MB, mensal, da SMTR. Fornece linhas e o traçado. O join
`routes → trips → stop_times → stops` roda em passagem única sobre um arquivo de ~86 MB.

### 2.4 Fortaleza — ETUFOR, e o caminho alternativo

O portal oficial `dados.fortaleza.ce.gov.br` tem **apenas datasets estáticos**: GTFS, mapas
e um dump de GPS de 2015. **Não há API de posição em tempo real.**

Validamos uma **API não-oficial e não documentada** em
`http://gistapis.etufor.ce.gov.br:8081/api`, que responde JSON e serve 539 linhas,
itinerários, horários programados e 2.515 logradouros.

**A alternativa que salva a praça.** Sem posição, Fortaleza parece inviável para um produto
geolocalizado. Mas o itinerário entrega **a sequência de logradouros que cada linha
percorre** — e logradouro é geocodificável contra a malha da cidade. Ou seja:

| O que temos em Fortaleza | O que permite |
|---|---|
| Itinerário: sequência de ruas por linha | **Quais regiões cada linha atravessa** — cobertura estática |
| Horários programados | **Quando** a linha está em circulação |
| ❌ Posição do veículo | ❌ Onde o veículo está agora; ❌ permanência real por região |

**Para planejamento de inventário — que é a leitura A da Seção 1.3 — isso é suficiente.**
O time de marketing consegue saber que a linha 617 atravessa determinados bairros e em que
horários opera. O que se perde é a medição real de permanência, que passa a ser estimada.

Ressalvas: os "pontos" são logradouros **sem latitude/longitude** (exigem geocodificação
contra a base de endereços da cidade); a linha 915 retorna erro 500; e o servidor responde
como IIS 7.5, fora de suporte, reforçando o risco de descontinuidade (**R2**).

---

## 3. Escopo da proposta

### 3.1 Dentro do escopo

- Coleta agendada a cada 30 minutos das fontes de posição (São Paulo e Rio) e coleta diária
  de cadastro nas três praças.
- Historização imutável do dado bruto — a fonte não tem histórico, o que não for capturado
  está perdido.
- **Enriquecimento geográfico**: tradução de coordenada para região, o núcleo do produto.
- Modelo canônico unificado entre as três praças.
- Tabelas de consumo para marketing: cobertura linha × região, permanência, circulação por
  faixa horária.
- Testes de qualidade, observabilidade e documentação operacional.
- Infraestrutura como código, agnóstica de nuvem.

### 3.2 Fora do escopo desta etapa

| Fora do escopo | Por quê | Quando reconsiderar |
|---|---|---|
| **Fontes ferroviárias** | Nenhuma mapeada; exige discovery próprio | Se **N3** confirmar trens no escopo |
| Decisão/veiculação do anúncio | É do sistema de mídia, não do pipeline | Nunca — fronteira de responsabilidade |
| Dado de audiência e demografia | É ativo do cliente; entregamos a chave de junção | Quando **N5** for respondido |
| Painel de BI customizado | Entregamos tabelas e um BI open source padrão | Se houver requisito de UX próprio |
| Previsão de circulação | Exige histórico consolidado | Após 6 meses de histórico |
| Praças além das três | Escopo fechado | Nova praça comercial |

### 3.3 Premissas

1. As APIs seguem disponíveis e com o comportamento observado em 14/08/2026.
2. O cliente provê uma conta de nuvem (qualquer provedor) ou infraestrutura própria.
3. A decisão do anúncio ocorre no dispositivo; o pipeline apoia planejamento (**N2**).
4. O dado é público e não contém informação pessoal — `id_veiculo` identifica o veículo,
   não o motorista. Não há tratamento de dado pessoal.
5. **Uma única pessoa** implementa e opera o pipeline. Simplicidade operacional é requisito,
   não preferência.

---

## 4. Arquitetura do pipeline

### 4.1 Princípios

Quatro princípios, nesta ordem de prioridade, e cada escolha adiante deriva deles:

1. **Agnóstica de nuvem.** Nada no caminho crítico que exista em um só provedor.
2. **Operável por uma pessoa.** Complexidade é custo recorrente de atenção, não só de
   dinheiro. Cada componente precisa justificar sua existência.
3. **Custo é restrição de projeto, não consequência.** Orçamento fixo anual significa que a
   arquitetura se ajusta ao teto, e não o contrário.
4. **Dado bruto preservado.** A fonte é perecível e não tem histórico; reprocessar precisa
   ser possível sem re-consultar.

### 4.2 Camadas

```
┌──────────────────────────────────────────────────────────────────────┐
│  COLETA — um conector por fonte, cadências separadas                 │
│                                                                      │
│   Posição · a cada 30 min          Cadastro · 1× ao dia              │
│   SP  /Posicao          ✅          SP  linhas + paradas             │
│   Rio /gps/sppo         ✅          Rio GTFS (semanal)               │
│   Fortaleza             ❌          Fortaleza linhas + itinerários   │
└──────────────────────┬───────────────────────┬───────────────────────┘
                       ▼                       ▼
┌──────────────────────────────────────────────────────────────────────┐
│  BRUTO — resposta original, imutável, particionada                   │
│  praca=<p>/entidade=<e>/dt=2026-08-14/hh=16/                         │
└──────────────────────────────┬───────────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  PADRONIZADO — modelo canônico entre praças + deduplicação           │
│  linhas · posicoes · pontos    (mesmo schema nas 3 praças)           │
└──────────────────────────────┬───────────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ENRIQUECIDO — o núcleo do produto                                   │
│  posição (lat/long)  ⨝  malha de regiões  →  posição + regiao_id     │
│  Cruzamento espacial local. Sem API paga. Ver 4.4                    │
└──────────────────────────────┬───────────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  CONSUMO — tabelas que respondem às perguntas da Seção 1.2           │
│  cobertura_linha_regiao · permanencia_regiao · circulacao_hora       │
└──────────────────────────────────────────────────────────────────────┘
```

A camada **enriquecido** é a que diferencia este pipeline de uma coleta genérica: é onde
coordenada vira região e o dado passa a responder à pergunta do marketing.

### 4.3 Modelo canônico

As três fontes nomeiam o mesmo conceito de formas diferentes:

| Conceito | São Paulo | Rio | Fortaleza |
|---|---|---|---|
| Código da linha | `cl` | `route_id` | `numero` |
| Nome público | `lt` | `route_short_name` | `numeroNome` |
| Latitude | `py` | `latitude` | — |
| Longitude | `px` | `longitude` | — |
| ID do veículo | `p` | `id_veiculo` | — |
| Timestamp | `ta` | `datetime` | — |

```
linhas    (praca, id_linha, codigo_publico, nome, origem, destino,
           sentido, tipo_linha, coletado_em)

posicoes  (praca, id_veiculo, id_linha, latitude, longitude,
           velocidade, direcao, timestamp_veiculo, regiao_id, coletado_em)

pontos    (praca, id_ponto, id_linha, nome, latitude, longitude,
           ordem, regiao_id, coletado_em)

regioes   (regiao_id, praca, nome, tipo, geometria, populacao_estimada)
```

`regiao_id` em `posicoes` e `pontos` é a chave que liga tudo ao produto — e a chave de
junção com o dado de audiência do cliente (**N5**).

Campos ausentes na origem ficam nulos, explicitamente. **Nulo honesto é preferível a valor
inventado**, e a cobertura por praça vira parte do contrato de dados (Seção 5).

### 4.4 Enriquecimento geográfico — a decisão de maior impacto

Traduzir coordenada em região tem três caminhos, com custos separados por ordens de
magnitude. **Esta é a decisão arquitetural mais relevante do projeto do ponto de vista
financeiro.**

| Abordagem | Como funciona | Custo anual estimado | Veredito |
|---|---|---|---|
| **Geocodificação reversa por posição** | Chamada a API comercial para cada uma das ~248M posições/ano | **~US$ 1.240.000** | ❌ Inviável — sozinho, milhares de vezes o orçamento |
| **Geocodificação com cache por grade** | Arredonda a coordenada a ~100 m e consulta só células inéditas | ~US$ 250 no 1º ano, depois quase zero | ⚠️ Viável, mas cria dependência de fornecedor |
| **Cruzamento espacial com malha pública** | Ponto-em-polígono contra shapefiles oficiais, localmente | **~US$ 0 marginal** | ✅ **Recomendado** |

**Recomendação: cruzamento espacial local.** As malhas territoriais brasileiras (bairros e
setores censitários) são publicadas gratuitamente pelo IBGE e pelas prefeituras. Baixadas
uma vez, viram uma tabela de polígonos; a atribuição de região é um *point-in-polygon* com
índice espacial, que roda em segundos para o volume diário. Sem chamada externa, sem custo
por requisição, sem dependência de fornecedor, e funciona offline.

> **Este item sozinho responde pela viabilidade do orçamento.** A diferença entre a
> abordagem ingênua e a recomendada é de aproximadamente **quatro ordens de grandeza** —
> maior do que todas as outras decisões de custo do projeto somadas.

O setor censitário do IBGE tem um bônus relevante: **já vem com dados populacionais**, o
que ajuda a estimar alcance potencial por região sem depender de fonte adicional.

### 4.5 Justificativa de cada escolha

| Escolha | Justificativa | Alternativa descartada |
|---|---|---|
| **Cruzamento espacial local** | Quatro ordens de grandeza mais barato que geocodificação por chamada; sem dependência externa | API de geocodificação |
| **Separar cadastro de posição** | Volatilidades incompatíveis: posição muda a cada 30 min; linha muda a cada meses | Pipeline único |
| **Camada bruta imutável** | Fonte perecível sem histórico; reprocessar é possível, re-consultar não | Transformar direto na ingestão |
| **Particionar por data e hora** | Consultas são por recorte temporal; poda de partição reduz varredura | Arquivo único |
| **Parquet** | Formato aberto e colunar; comprime 5–10× contra CSV e é lido por qualquer ferramenta | CSV, ou formato proprietário |
| **Processamento embarcado (DuckDB)** | 679 mil registros/dia cabem folgadamente em um processo único. Cluster seria custo e complexidade sem ganho | Spark, warehouse gerenciado |
| **Deduplicação obrigatória no Rio** | Sem ela a frota fica ~11× inflada, distorcendo toda métrica de circulação | Ingerir bruto sem tratar |
| **Uma chamada de posição por praça** | Uma chamada devolve 10.769 veículos; a alternativa exige ~2.700 | Iterar linha a linha |
| **Idempotência por instante de coleta** | Re-execução após falha não pode duplicar e inflar circulação | Append cego |
| **Tolerância a falha por item** | Uma linha com erro não pode derrubar a coleta das outras 538 | Abortar no primeiro erro |
| **Piso de volume na ingestão** | O Rio devolve `[]` com HTTP 200; só volume esperado detecta | Confiar no status HTTP |

---

## 5. Arquitetura de infraestrutura

### 5.1 Stack proposto

Escolhido para satisfazer os quatro princípios da Seção 4.1 simultaneamente:

| Camada | Escolha | Por quê |
|---|---|---|
| **Execução** | Containers OCI (Docker) | Unidade portável universal; roda em qualquer nuvem, on-premise ou na máquina do desenvolvedor |
| **Orquestração** | Cron do sistema no MVP; Prefect ou Dagster self-hosted se crescer | Agendamento a cada 30 min não justifica orquestrador dedicado no início |
| **Armazenamento** | Object storage com API S3 | Padrão de fato; todos os provedores oferecem ou têm gateway compatível |
| **Formato** | Parquet particionado | Aberto, comprimido, lido por qualquer ferramenta |
| **Processamento** | DuckDB embarcado + Polars | Zero infraestrutura; lê Parquet direto do object storage |
| **Geoprocessamento** | GeoPandas / Shapely + malhas IBGE | Bibliotecas abertas; nenhum serviço externo |
| **Consumo** | Metabase self-hosted, ou Parquet consumido direto | Open source; roda no mesmo host |
| **Infra como código** | Terraform | Multi-provedor; a troca de nuvem é troca de provider |
| **Segredos** | Cofre do provedor, com fallback em variáveis de ambiente cifradas | Interface fina, trocável |
| **Observabilidade** | Logs estruturados + healthcheck externo + alerta por webhook | Suficiente para uma pessoa; sem custo de plataforma |

### 5.2 Grau de portabilidade

Ser "agnóstico" não é absoluto — é saber exatamente onde estão os pontos de acoplamento e
mantê-los finos e isolados:

| Componente | Portabilidade | O que muda ao trocar de nuvem |
|---|---|---|
| Formato de dados (Parquet) | **Total** | Nada |
| Processamento (DuckDB, Polars) | **Total** | Nada |
| Geoprocessamento | **Total** | Nada |
| Lógica de coleta e transformação | **Total** | Nada |
| Container | **Total** | Serviço que executa o container |
| Object storage | **Alta** | Endpoint e credencial — a API S3 é comum |
| Terraform | **Alta** | O *provider*; a estrutura permanece |
| Segredos | **Média** | Implementação do cofre, atrás de uma interface |
| Observabilidade | **Média** | Destino dos logs |

**Regra de projeto:** todo acoplamento fica atrás de uma interface — armazenamento,
segredos e notificação. A migração entre provedores deve ser uma mudança de configuração e
de *provider* do Terraform, não uma reescrita.

### 5.3 Topologia mínima

Um único host pequeno executa tudo:

```
┌─────────────────────────────────────────────────┐
│  Host pequeno (2 vCPU, 4 GB)                    │
│                                                 │
│  ├─ container coleta-posicoes   (cron :00 :30)  │
│  ├─ container coleta-cadastro   (cron diário)   │
│  ├─ container transforma        (cron :05 :35)  │
│  └─ container metabase          (sempre ativo)  │
└──────────────────────┬──────────────────────────┘
                       ▼
         ┌──────────────────────────────┐
         │  Object storage (API S3)     │
         │  bruto/ padronizado/         │
         │  enriquecido/ consumo/       │
         └──────────────────────────────┘
```

**Por que um host sempre ligado em vez de funções serverless?** É a escolha que mais
serve aos princípios, apesar de pagar por ociosidade:

- **Portabilidade.** Funções serverless são o componente *menos* portável de qualquer
  nuvem — cada provedor tem modelo, limites e empacotamento próprios. Container em host é
  o oposto.
- **Custo previsível.** Orçamento fixo anual favorece um valor conhecido e constante sobre
  um valor variável, mesmo que a média seja parecida.
- **Operabilidade individual.** Um host, um `docker compose`, um log. Depurar é entrar na
  máquina.
- **Sem limite de tempo de execução.** A coleta de cadastro leva ~2min25s em São Paulo e
  ~2min12s em Fortaleza; funções têm teto e sofrem com cold start.

O custo da ociosidade é de **US$ 10 a 15 por mês**. É o preço da portabilidade e da
simplicidade, e cabe no orçamento com folga.

---

## 6. Contrato de dados

### 6.1 Cobertura por praça

Sem esta tabela explícita, a cobertura desigual vira armadilha silenciosa na análise:

| Campo | São Paulo | Rio | Fortaleza |
|---|:---:|:---:|:---:|
| `posicoes` — existe? | ✅ | ✅ | ❌ |
| `posicoes.velocidade` | ❌ | ✅ | — |
| `posicoes.direcao` | ❌ | ✅ | — |
| `pontos` com coordenada | ⚠️ 24% das linhas | ✅ | ❌ logradouro, exige geocodificação |
| `regiao_id` em posições | ✅ | ✅ | ❌ sem posição |
| Cobertura linha × região | ✅ medida | ✅ medida | ⚠️ **estimada por itinerário** |
| Permanência real por região | ✅ | ✅ | ❌ não mensurável |
| Horários programados | ❌ | ✅ GTFS | ✅ |
| **Trens** | ❌ | ❌ | ❌ |

**Regra de uso:** toda análise que compare praças deve declarar quais colunas usa e quais
praças ficam de fora. Especialmente: **Fortaleza tem cobertura estimada, não medida** — o
que é aceitável para planejamento, mas não pode ser somado a São Paulo e Rio como se fosse
o mesmo tipo de dado.

### 6.2 Compromisso de serviço

As fontes não têm SLA. O compromisso é, portanto, **sobre a plataforma, não sobre o dado
de origem**:

| Dimensão | Compromisso | Como é medido |
|---|---|---|
| **Atualização** | Dado de posição disponível em até 10 min após a janela de 30 min | Diferença entre `coletado_em` e publicação |
| **Completude** | ≥ 95% das 48 janelas diárias capturadas, por praça | Janelas com dado sobre esperado |
| **Detecção de falha** | Anomalia gera alerta em até 30 min | Cobertura dos testes QD-1 a QD-6 |
| **Disponibilidade da fonte** | **Não garantida** — repassada como está | Métrica de lacuna publicada |
| **Estabilidade de schema** | Mudança com aviso e versionamento | Teste QD-3 |

---

## 7. Qualidade e observabilidade

Dado perecível e falha silenciosa conhecida elevam o peso desta camada.

| ID | Teste | Detecta | Ação |
|---|---|---|---|
| **QD-1** | **Piso de volume por janela** | O `[]` silencioso do Rio; fonte fora do ar | **Falhar** e alertar |
| **QD-2** | **Frescor** — timestamp mais recente dentro da janela esperada | Fonte congelada devolvendo dado velho | Alertar |
| **QD-3** | **Schema** — campos presentes e tipados | Mudança não anunciada na API | **Falhar** e alertar |
| **QD-4** | **Sanidade geográfica** — coordenada dentro do envelope da praça | Coordenada corrompida; latitude trocada com longitude | Quarentenar e alertar |
| **QD-5** | **Taxa de atribuição de região** — % de posições com `regiao_id` | Malha desatualizada; posição fora da área mapeada | Alertar acima do limiar |
| **QD-6** | **Duplicidade** — chave praça + veículo + timestamp única | Idempotência quebrada inflando circulação | **Falhar** e alertar |

**QD-1 e QD-5 são os mais importantes.** O primeiro protege contra o modo de falha mais
perigoso identificado — a API do Rio respondendo HTTP 200 com corpo vazio. O segundo
protege o núcleo do produto: uma posição sem região não serve para nada, e uma queda na
taxa de atribuição é o sintoma mais direto de que o pipeline parou de gerar valor.

**Operação:** painel de completude por praça e janela; alerta de lacuna via webhook;
runbook com a ação de cada teste. Lacuna de posição é irrecuperável — o procedimento é
registrar e comunicar, não tentar recuperar.

---

## 8. FinOps

### 8.1 Volume real, na cadência exigida

A cadência de 30 minutos reduz o volume em ~24× frente a uma coleta de 1 minuto — e é o
principal motivo de o custo caber com folga:

| Item | Valor |
|---|---:|
| Coletas de posição por dia | 48 |
| Registros por dia (SP 516.912 + Rio 162.144) | ~679 mil |
| Registros por mês | ~20,4 milhões |
| Registros por ano | ~248 milhões |
| Tamanho por registro (Parquet comprimido) | ~30 bytes |
| **Armazenamento por mês** | **~0,6 GB** |
| **Acumulado no ano 1** | **~7,3 GB** |

### 8.2 Custo anual estimado

| Componente | Mensal | **Anual** |
|---|---:|---:|
| Host pequeno (2 vCPU, 4 GB) | US$ 10–15 | US$ 120–180 |
| Object storage (~7 GB no ano 1) | < US$ 1 | ~US$ 12 |
| Rede e egresso | ~US$ 2 | ~US$ 24 |
| Backup e snapshot | ~US$ 2 | ~US$ 24 |
| Observabilidade (self-hosted) | US$ 0–5 | US$ 0–60 |
| **Total** | **US$ 15–25** | **US$ 180–300** |
| **Custo das APIs** | **US$ 0** | **US$ 0 — as três são gratuitas** |

**Custo unitário:** ~US$ 60–100 por praça por ano; ~US$ 0,001 por mil posições processadas.

**Reserva recomendada:** provisionar 25% acima do teto estimado (~US$ 375/ano) para
absorver crescimento de histórico e eventual inclusão de fontes ferroviárias.

### 8.3 O que decidimos *não* comprar, e por quê

Ponto central de FinOps: o custo é definido mais pelo que se recusa do que pelo que se
otimiza.

| Não contratado | Custo anual evitado | Por quê |
|---|---:|---|
| **Geocodificação reversa por posição** | **~US$ 1.240.000** | Cruzamento espacial local entrega o mesmo resultado (Seção 4.4) |
| Orquestrador gerenciado (Airflow) | ~US$ 4.200 | Cron atende 48 execuções diárias |
| Data warehouse gerenciado | ~US$ 1.200–3.600 | DuckDB processa 679 mil registros/dia em um processo |
| Cluster de processamento distribuído | ~US$ 2.400+ | O volume cabe em memória de um host pequeno |
| Plataforma de observabilidade paga | ~US$ 600 | Logs estruturados e healthcheck bastam para um operador |

**Soma evitada: mais de US$ 1,2 milhão por ano**, majoritariamente numa única decisão. O
maior ganho de FinOps deste projeto não está em negociar preço de instância — está em
**não escolher a arquitetura errada no enriquecimento geográfico**.

### 8.4 Sensibilidade e alavancas

O que acontece se as premissas mudarem:

| Mudança | Efeito no custo | Comentário |
|---|---|---|
| Cadência de 30 min → 15 min | +~US$ 12/ano | Armazenamento dobra, mas parte de base ínfima |
| Cadência de 30 min → 5 min | +~US$ 70/ano | Ainda cabe; o host não muda |
| Incluir trens (3 fontes novas) | +US$ 0–60/ano em infra | O custo real é de desenvolvimento, não de infra |
| Retenção 12 → 36 meses | +~US$ 25/ano | Armazenamento é o componente mais barato |
| Trocar host por serverless | −US$ 60 a 120/ano | Economia real, mas custa portabilidade |
| Adicionar BI gerenciado | +US$ 300–1.200/ano | Metabase self-hosted evita |

**Leitura:** nenhuma alavanca de volume ameaça o orçamento — a estrutura de custo é
dominada por componentes fixos. **A frequência de coleta pode ser decidida por critério
técnico e de negócio, não por custo.**

### 8.5 Guardrails

Controles propostos para manter o gasto dentro do orçamento fixo:

1. **Alertas de orçamento** em 50%, 80% e 100% do teto anual.
2. **Política de ciclo de vida** no object storage: 12 meses quente, depois camada fria,
   expurgo conforme retenção acordada.
3. **Etiquetagem de custo** por componente, para atribuir gasto a cada parte do pipeline.
4. **Teto de gasto** configurado no provedor, quando disponível.
5. **Revisão trimestral** de custo real contra o estimado, com o consumo reportado ao
   cliente.
6. **Dimensionamento revisado** a cada nova praça ou modal.

---

## 9. Plano de implementação

Estimativa para **uma pessoa**, conforme a premissa 3.3.5. Organizado em ondas, com valor
entregue ao fim de cada uma — e não só ao fim do projeto.

### 9.1 Ondas

| Onda | Entrega | Esforço |
|---|---|---:|
| **Onda 1 — São Paulo ponta a ponta** | Infra como código e host provisionado; conector de posição a cada 30 min; camada bruta particionada; modelo canônico; **malha de regiões e cruzamento espacial**; primeira tabela de consumo (cobertura linha × região) | **3–4 sem** |
| **Onda 2 — Rio e Fortaleza** | Conector do Rio com deduplicação e QD-1; conector de Fortaleza; **cobertura estimada por itinerário**; unificação das três praças no modelo canônico | **2–3 sem** |
| **Onda 3 — Robustez e entrega** | Testes QD-1 a QD-6; alertas e painel de completude; tabelas de permanência e circulação por hora; BI para marketing; documentação e runbook | **2 sem** |
| | **Total** | **7–9 sem** |

**Por que São Paulo primeiro:** maior volume (10.769 veículos, 63% do total), API oficial
com token, e o endpoint `/Posicao` mais eficiente das três. É a praça onde o pipeline prova
valor mais rápido e onde os problemas de escala aparecem primeiro.

**Por que a malha de regiões entra já na Onda 1:** é o núcleo do produto e a maior
incerteza técnica. Deixá-la para o fim significaria descobrir tarde se a definição de
região (**N1**) está errada.

### 9.2 Critérios de aceite

| # | Critério | Verificação |
|---|---|---|
| **CA-1** | Re-executar a coleta de uma janela não duplica registros | Contagem idêntica antes e depois |
| **CA-2** | Data em formato brasileiro na fonte do Rio **falha a execução** | Teste automatizado; não pode gravar vazio |
| **CA-3** | ≥ 95% das posições recebem `regiao_id` | Taxa de atribuição medida (QD-5) |
| **CA-4** | Veículos únicos por praça na faixa medida no discovery | SP ~10.769 · Rio ~3.378, com tolerância |
| **CA-5** | Toda coluna nula por praça justificada no contrato | Revisão da tabela 6.1 contra o schema real |
| **CA-6** | Lacuna de coleta simulada gera alerta em até 30 min | Interromper conector e cronometrar |
| **CA-7** | Migração de provedor exige apenas troca de configuração e *provider* | Revisão de desenho; sem código de nuvem no núcleo |
| **CA-8** | Nenhuma credencial no repositório | Varredura de segredos no CI |
| **CA-9** | Custo real do primeiro mês dentro do teto estimado | Relatório de custo do provedor |

### 9.3 Métricas de sucesso

- **Completude ≥ 95%** das 48 janelas diárias, por praça.
- **Taxa de atribuição de região ≥ 95%** — o produto só existe acima disso.
- **Zero falhas silenciosas** — toda anomalia gerou alerta, nenhuma descoberta por acidente.
- **Custo anual dentro do orçamento**, reportado trimestralmente.
- **Nova praça integrável em menos de uma semana**, sem mudar o modelo canônico.

---

## 10. Mapa de riscos

### 10.1 Riscos de escopo e produto

| # | Risco | Prob. | Impacto | Mitigação |
|---|---|:---:|:---:|---|
| **R1** | **Nenhuma fonte cobre trens.** O produto prevê telões em trens; as três fontes são de ônibus | **Certo** | **Alto** | Confirmar **N3**. Se trens estiverem no escopo, discovery próprio para as três praças — trabalho não contemplado nesta etapa |
| **R2** | **Fortaleza não publica posição.** Um terço das praças sem o dado central | **Certo** | **Alto** | Cobertura estimada por itinerário (2.4); declarar no contrato que é estimativa, não medição; pedido formal à ETUFOR |
| **R3** | **Definição de "região" divergir da expectativa do negócio** | Média | **Alto** | **N1** antes da Onda 1. A malha é parametrizável: trocar de bairro para setor censitário é troca de arquivo, não de código |
| **R4** | **30 min ser insuficiente** se a decisão do anúncio for centralizada | Média | **Alto** | **N2**. Se confirmar a leitura B, a arquitetura muda — e o orçamento também |

### 10.2 Riscos técnicos e operacionais

| # | Risco | Prob. | Impacto | Mitigação |
|---|---|:---:|:---:|---|
| **R5** | **API do Rio retorna `[]` com HTTP 200** em formato de data errado | Média | **Alto** | **QD-1** e **CA-2** já na Onda 2. Nunca confiar apenas no status HTTP |
| **R6** | API da ETUFOR é não-oficial, sem documentação, em infra fora de suporte | Média | **Alto** | Isolar em conector próprio; GTFS estático como alternativa; alertar em falha |
| **R7** | Fontes públicas sem SLA; indisponibilidade é perda definitiva | Alta | Médio | Retry com backoff; alerta de lacuna; SLA de plataforma separado do da fonte |
| **R8** | Varredura alfanumérica da SPTrans é heurística | Média | Baixo | Monitorar variação; validar contra GTFS da SPTrans |
| **R9** | Cobertura de paradas da SPTrans em 24% das linhas | **Certo** | Baixo | **Recalibrado:** para cobertura de região o que importa é a posição, disponível integralmente |
| **R10** | Mudança de schema sem aviso nas APIs | Média | Médio | **QD-3**; camada bruta permite reprocessar |
| **R11** | Operação concentrada em uma pessoa — férias, saída, indisponibilidade | Alta | Médio | Documentação e runbook como entregável da Onda 3; stack padrão sem componente exótico |

### 10.3 Riscos financeiros e de governança

| # | Risco | Prob. | Impacto | Mitigação |
|---|---|:---:|:---:|---|
| **R12** | **Escolha errada no enriquecimento geográfico** estourar o orçamento sozinha | Baixa | **Crítico** | Decisão já tomada e justificada (4.4); registrar como decisão arquitetural travada |
| **R13** | **Credencial exposta.** O arquivo de exemplo de variáveis de ambiente contém valor que aparenta ser token real da SPTrans | **Certo** | Médio | **Ação imediata:** rotacionar e substituir por placeholder; cofre de segredos na Onda 1; varredura no CI |
| **R14** | Crescimento de histórico corroer o orçamento no ano 2+ | Baixa | Baixo | Política de ciclo de vida e alertas (8.5) |
| **R15** | Termos de uso das fontes não revisados formalmente | Média | Médio | Revisar licença de cada portal antes de uso comercial — **atenção: o uso aqui é comercial**, o que exige mais rigor do que uso analítico interno |

### 10.4 Prioridade

1. **R13** — rotacionar a credencial. Imediato, custo baixo.
2. **R1 e R4** — confirmar trens (**N3**) e o modelo de decisão do anúncio (**N2**). Podem
   redefinir o escopo do projeto.
3. **R3** — definir "região" (**N1**) antes da Onda 1.
4. **R15** — revisar licenças, dado que o uso é comercial.
5. **R5** — QD-1 já na Onda 2.

---

## 11. Decisões pendentes, com recomendação

**Cada decisão tem um padrão recomendado.** Se nada for dito em contrário, seguimos com o
padrão — **nenhuma bloqueia o início da Onda 1**, exceto **N1**, que é insumo direto da
camada de enriquecimento.

| # | Decisão | Recomendação | Quando decidir |
|---|---|---|---|
| **N1** | O que é "região" | **Bairro pela malha do IBGE**, por ser padrão de mercado publicitário, gratuito e comparável entre praças. Parametrizável para setor censitário se o cliente quiser granularidade fina | **Antes da Onda 1** |
| **N2** | Decisão do anúncio no telão ou centralizada | **No telão**, com o pipeline apoiando planejamento. Única leitura compatível com 30 min | Antes da Onda 2 |
| **N3** | Trens no escopo | **Fora desta etapa.** Mapear fontes ferroviárias em discovery próprio, com orçamento próprio | Antes da Onda 2 |
| **N4** | Fortaleza com cobertura estimada | **Sim, manter a praça** com cobertura por itinerário, declarada como estimativa no contrato | Antes da Onda 2 |
| **N5** | Dado de audiência por região | **Assumir que existe do lado do cliente**; entregamos `regiao_id` como chave de junção | Antes da Onda 3 |
| **N6** | Valor do orçamento anual | **Dimensionar para o mínimo viável** (~US$ 300/ano) e reportar consumo trimestral | Antes da Onda 1 |
| **T1** | Provedor de nuvem | **Onde o cliente já opera.** A arquitetura é portável por desenho | Antes da Onda 1 |
| **T2** | Retenção do histórico | **12 meses quente + frio indefinido.** Armazenamento é o componente mais barato e o dado é irrecuperável | Onda 3 |
| **T3** | Ferramenta de consumo | **Metabase self-hosted**, ou Parquet direto se o time preferir notebook | Onda 3 |
| **T4** | Cobertura de paradas da SPTrans | **Adotar GTFS da SPTrans** se paradas virarem requisito; hoje não são críticas | Se surgir requisito |

---

## 12. Próximos passos

### 12.1 O que precisamos do cliente

| O quê | Por quê | Quando |
|---|---|---|
| **Definir "região" (N1)** | Insumo direto da camada de enriquecimento | Antes da Onda 1 |
| **Confirmar escopo de trens (N3)** | Pode adicionar um discovery inteiro ao projeto | Antes da Onda 2 |
| **Confirmar o modelo de decisão do anúncio (N2)** | Se for centralizada, a arquitetura muda | Antes da Onda 2 |
| Acesso à nuvem ou infraestrutura (T1) | Bloqueia a Onda 1 | Antes da Onda 1 |
| Rotacionar o token da SPTrans (R13) | Risco de segurança aberto | **Imediato** |
| Valor do orçamento anual (N6) | Confirma a margem de escolha arquitetural | Antes da Onda 1 |

### 12.2 Recomendação de arranque

O projeto **pode começar imediatamente**, desde que **N1** seja respondida — é o único
insumo sem o qual a camada de enriquecimento não pode ser construída, e ela entra já na
Onda 1 justamente por ser o núcleo do produto.

Duas questões podem redefinir o escopo e devem ser tratadas em paralelo à Onda 1, não
depois dela: **trens** (**N3**) e **modelo de decisão do anúncio** (**N2**).

A única ação imediata independente de qualquer decisão é a **rotação da credencial**
(**R13**).

---

## Anexo — Base de evidências

Todos os números vêm de chamadas reais executadas em 14/08/2026. Reprodutível com:

```bash
make run-sptrans      # 2.688 linhas · 10.769 veículos · 4.888 paradas  (~2min25s)
make run-rio          # 498 linhas · 3.378 veículos · 52.505 pontos     (~7s)
make run-fortaleza    # 539 linhas · 19.398 trechos de itinerário       (~2min12s)
make run-all          # as três praças em sequência
```

Saídas em `output/<cidade>/`. Detalhes de cada API em [README.md](README.md).

**Verificações específicas feitas para este documento:**

- **Cobertura modal:** os tipos de rota do GTFS do Rio foram contados (498 rotas: 440 tipo
  700, 30 tipo 702, 28 tipo 200 — todos rodoviários) e as categorias de linha de Fortaleza
  tabuladas (Convencional, Complementar, Alimentadora, Troncal). Nenhum registro
  ferroviário nas duas fontes.
- **Cobertura de paradas da SPTrans:** medida sobre os 2.688 códigos coletados; as linhas
  sem parada foram re-testadas individualmente, com pausa, para descartar throttling.
- **Formato de data do Rio:** confirmado por comparação entre `MM-dd-yyyy` e `dd-MM-yyyy`
  no mesmo intervalo — o segundo retorna `[]` com HTTP 200.
- **Deduplicação do Rio:** verificada contando registros brutos contra identificadores de
  veículo distintos na mesma janela.
- **Volumes de custo:** derivados dos veículos medidos × 48 janelas diárias, não de
  estimativa de mercado.
