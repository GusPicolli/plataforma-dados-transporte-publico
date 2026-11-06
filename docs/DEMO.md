# Roteiro de demonstração

Ordem para percorrer o projeto inteiro na AWS e **ver o dado andando**, do
disparo até o dashboard. Serve tanto para apresentar quanto para você mesmo
entender o fluxo de ponta a ponta.

Tempo: ~10 min no caminho curto, ~25 min no completo.

---

## Antes de começar

### 1. Dispare uma coleta

```bash
make trigger
```

**Este passo não é opcional.** A coleta automática só roda das 8h às 16h59 em
dia útil; fora dessa janela o Step Functions aparece **vazio** e não há nada
para mostrar. O `make trigger` starta o mesmo fluxo que o agendamento starta,
com a mesma entrada — no histórico, a execução é indistinguível de uma
agendada.

Ele imprime o link direto da execução. Leva ~10 segundos.

Para disparar o cadastro (linhas e pontos) em vez das posições:

```bash
make trigger GRUPO=cadastro
```

### 2. Se for mostrar o Metabase, ligue a instância agora

```bash
make metabase-aws-ligar
```

A primeira subida leva ~3 minutos. Ligue no começo para ela estar pronta
quando você chegar na etapa 6.

### 3. Confira que está tudo verde

```bash
make status
```

---

## O percurso

A ordem abaixo **segue o dado**: cada tela mostra o que a anterior produziu.

### 1. Step Functions — a visão geral

**Console → Step Functions → State machines → `onibus-tempo-real-coleta` →
Executions**

Comece aqui: é a única tela que mostra o pipeline inteiro de uma vez. Abra a
execução que você acabou de disparar.

O que apontar:

- O **grafo**: o fan-out para as fontes (cada praça em paralelo) e o fan-in
  chamando a normalização no fim.
- Clique num passo → **Input/Output**. A saída traz as chaves gravadas no S3.
- A execução inteira levou ~10 segundos.

A frase que resume: *"existe um sinal de conclusão — dá para responder 'a
coleta das 14h32 terminou?', o que um agendamento solto nunca respondeu."*

Se uma fonte estivesse fora do ar, o passo dela ficaria laranja e **os outros
seguiriam**. Isso aconteceu de verdade: o GTFS do Rio ficou semanas fora do
ar e SP e Fortaleza continuaram carregando.

### 2. Lambda — quem fez o trabalho

**Console → Lambda → Functions → `onibus-tempo-real-sp-posicoes` → Monitor →
View CloudWatch logs → o fluxo mais recente**

O que apontar:

- O log é **JSON estruturado**, não texto solto. Procure `total_valido` — é o
  número de registros que passaram na validação de schema.
- Sete funções, **uma única imagem de container**. O que muda entre elas é a
  variável de ambiente `FONTE` (aba *Configuration → Environment variables*).

A frase: *"a lógica de coleta existe uma vez só; ela roda local e na AWS sem
ser duplicada."*

### 3. S3 — onde o dado caiu

**Console → S3 → `onibus-tempo-real-dev-<ID-DA-CONTA>`**

Navegue nesta ordem, que é a arquitetura:

```
bronze/praca=sp/entidade=posicoes/dt=.../hh=...   NDJSON, como a fonte entregou
silver/praca=sp/entidade=posicoes/dt=.../hh=...   Parquet, schema canônico
gold/                                              as tabelas dimensionais
```

O que apontar:

- O **particionamento** (`praca=`, `dt=`, `hh=`) é o que faz uma consulta por
  data ler só os arquivos daquele dia, em vez do bucket inteiro.
- Compare o tamanho de um arquivo bronze com o silver equivalente: o Parquet
  é ~93% menor e já está normalizado.
- O bronze de posições **expira em 30 dias**. É isso que transforma um custo
  que cresceria todo mês num custo fixo.

A frase: *"o bronze guarda exatamente como veio. Se a origem mudar um campo,
o histórico continua íntegro e reprocessável."*

### 4. Glue — o catálogo

**Console → AWS Glue → Data catalog → Databases → Tables**

Dois bancos: `onibus_tempo_real_dev` (silver) e `onibus_tempo_real_dev_gold`.

O que apontar:

- Clique numa tabela → **Schema**. Os campos têm os mesmos nomes para as três
  cidades — é o schema canônico.
- **Não há crawler.** As tabelas são declaradas no Terraform e usam *partition
  projection*, então nunca é preciso rodar `MSCK REPAIR TABLE`, e não há custo
  nem atraso de descoberta.

### 5. Athena — consultar em SQL

**Console → Athena → Query editor**

Escolha o workgroup **`onibus-tempo-real-dev`** (não o `primary`) no seletor
do canto superior direito.

Comece pela silver, para mostrar que as três praças viraram **uma** tabela:

```sql
SELECT praca, count(*) AS posicoes, count(DISTINCT id_veiculo) AS veiculos
FROM onibus_tempo_real_dev.posicoes
GROUP BY praca
ORDER BY posicoes DESC;
```

```
praca   posicoes   veiculos
sp         22867       9070
rio        10395       3728
```

Depois o **modelo estrela**, juntando o fato com a dimensão de data — é o que
alguém de negócio usaria:

```sql
SELECT d.data_texto, d.nome_do_dia, f.praca,
       count(DISTINCT f.id_veiculo) AS veiculos,
       count(*)                     AS posicoes,
       round(avg(f.velocidade), 1)  AS vel_media
FROM onibus_tempo_real_dev_gold.fato_posicoes f
JOIN onibus_tempo_real_dev_gold.dim_data     d ON f.dt = d.data_texto
GROUP BY d.data_texto, d.nome_do_dia, f.praca
ORDER BY d.data_texto DESC, f.praca;
```

A velocidade vem nula para São Paulo: a API da SPTrans não publica esse campo,
e o modelo não inventa valor. Para o Rio ela vem (~15 km/h).

E o **geoespacial**, que costuma ser o que mais chama atenção — onde os ônibus
se concentram, agregados por hexágono H3, com a distância média até a parada
mais próxima:

```sql
SELECT h3_r8,
       count(*)                                  AS posicoes,
       count(DISTINCT id_veiculo)                AS veiculos,
       round(avg(metros_ate_parada_mais_proxima)) AS metros_ate_parada
FROM onibus_tempo_real_dev_gold.fato_posicoes
WHERE praca = 'sp' AND h3_r8 IS NOT NULL
GROUP BY h3_r8
ORDER BY posicoes DESC
LIMIT 10;
```

O que apontar:

- O workgroup tem **corte de 1 GB por consulta** — um `SELECT *` sem filtro
  não vira uma fatura. Repare no rodapé: cada consulta dessas varre menos de
  0,3 MB.
- O H3 é calculado na **Lambda silver**, não no Athena: o Athena não tem
  função H3 nativa. Decidir isso na ingestão é o que torna a agregação
  espacial um `GROUP BY` comum.
- `metros_ate_parada_mais_proxima` é uma medida geoespacial já calculada —
  responde "o veículo está num ponto ou no meio do caminho?".

**Pergunta provável:** *"por que a data da partição é o dia seguinte?"* As
partições usam **UTC**. Uma coleta às 23h de quinta em São Paulo cai na
partição de sexta. O campo `instante_utc` é o instante real; a partição é só
organização física de arquivo.

Pelo terminal, o equivalente é `make query` e `make query-gold`.

### 6. Metabase — o dashboard

```bash
make metabase-aws-tunel      # depois abra http://localhost:3000
```

O que apontar — e este é o ponto mais forte de segurança do projeto:

- **A instância não tem endereço público.** O Metabase escuta em `127.0.0.1` e
  o security group não tem regra de entrada. O acesso passa por um túnel SSM:
  cifrado, autorizado por IAM, registrado no CloudTrail, **sem porta aberta**.
- Em *Admin → Databases*, a conexão do Athena está com *"Use Default
  Credentials Provider Chain"* e **nenhuma chave preenchida** — a credencial
  vem do instance profile da EC2 e é rotacionada sozinha.
- A instância **liga e desliga sob demanda**. Parada custa só o disco.

Monte ali uma pergunta simples sobre `fato_posicoes` para fechar o ciclo:
o dado que você viu sendo coletado há 10 minutos aparecendo num gráfico.

Ao terminar: `make metabase-aws-desligar`.

### 7. CloudWatch — como se sabe que está funcionando

**Console → CloudWatch → Dashboards → `onibus-tempo-real-dev`**

Depois **→ Alarms**: são 15, de três tipos, porque são três modos de falha
diferentes:

| Sufixo | Pergunta que responde |
|---|---|
| `-erro` | a função quebrou? |
| `-dado-velho` | a função **nem rodou**? |
| `-volume-baixo` | rodou sem erro, mas o dado veio ruim? |

**Prepare-se para esta pergunta:** alguns alarmes `-dado-velho` estarão
vermelhos. Isso **não é falha** — é o sistema avisando que o dado parou de
chegar, porque os agendamentos estão desligados. É exatamente o que ele foi
feito para fazer.

A história que vale contar: a abordagem óbvia para "a função não rodou" seria
um alarme sobre `Invocations`. Ela **não funciona**. A métrica é esparsa — sem
invocação não existe ponto nenhum — e o CloudWatch, em vez de tratar a
ausência como zero, busca para trás e encontra um dado antigo. O alarme
reportava `OK` com a função parada havia 26 horas. A solução foi uma função
que publica de hora em hora uma métrica **densa** com a idade do dado.

É o tipo de coisa que só aparece operando, não projetando.

### 8. Governança — custo e segurança

Rápido, para fechar:

- **Billing → Budgets** → `onibus-tempo-real-dev`: teto de US$ 25, com alerta
  em 40%, em 100% e na **previsão** do mês — esse último é o que chega a tempo
  de agir.
- **Billing → Cost Explorer**, agrupado por serviço: o projeto custa
  **~US$ 2,56/mês**, dos quais ~86% é S3.
- **CloudTrail → Trails** → `onibus-tempo-real-dev`: multi-região, com
  validação de integridade.
- **S3 → Block Public Access (account settings)**: os quatro bloqueios ligados
  no nível da **conta**, não só do bucket.

A frase que amarra: *"o custo não foi otimizado, foi recusado — o maior ganho
está nas arquiteturas que nunca viraram linha de fatura."* O detalhamento está
em [`DECISOES.md`](DECISOES.md).

---

## Caminho curto (10 minutos)

Se o tempo for pouco, faça só estas quatro paradas:

1. **Step Functions** — o grafo de uma execução (a visão geral)
2. **S3** — bronze e silver lado a lado (as camadas)
3. **Athena** — a consulta das três praças e a do H3 (o resultado)
4. **CloudWatch Alarms** — os três tipos de alarme (como se sabe que funciona)

---

## O que dizer sobre o que falta

Vale dizer antes de perguntarem — mostra critério, e todas são decisões
conscientes, não esquecimentos:

| Falta | Por quê, e o que seria preciso |
|---|---|
| **Testes automatizados e CI** | é a lacuna mais relevante. Quatro regras deste projeto já quebraram na prática e seriam testes óbvios |
| **State do Terraform remoto** | hoje é local, sem lock. Dois `apply` simultâneos corromperiam o state |
| **Deploy versionado** | as funções apontam para a tag `latest`; o certo seria fixar o digest |
| **Agendamento ligado** | fica desligado de propósito, para não gerar custo sem alguém pedir |

---

## Depois da demonstração

```bash
make metabase-aws-desligar   # se tiver ligado a instância
make status                  # confirma que nada ficou rodando à toa
```

Os agendamentos continuam desligados a menos que você rode `make tf-ligar`.
