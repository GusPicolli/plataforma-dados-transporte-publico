# O que procurar na conta AWS

Roteiro para conferir, pelo console, que o projeto está de pé — e para
entender o que cada recurso é. Serve tanto para quem nunca viu a conta quanto
para quem precisa diagnosticar algo que parou.

Todos os recursos têm o prefixo **`onibus-tempo-real`** e vivem na região
**N. Virginia (`us-east-1`)**. Se o console abrir em outra região, a lista
aparece vazia — é o erro mais comum de todos.

> Nos nomes abaixo, `<ID-DA-CONTA>` é o número de 12 dígitos da conta. Ele
> aparece no canto superior direito do console.

---

## Começando pelo mais rápido

Antes de abrir o console, o terminal responde em um comando:

```bash
make status
```

Ele diz, por pipeline, se o dado está fresco e quando foi a última coleta. Se
o resultado estiver verde, o resto deste roteiro é só para entender o que
existe. Se estiver vermelho, siga para [Diagnóstico](#diagnóstico-quando-algo-parou).

---

## Roteiro, serviço por serviço

### 1. Step Functions — o orquestrador

**Console → Step Functions → State machines → `onibus-tempo-real-coleta`**

É o melhor lugar para começar, porque é onde o pipeline inteiro aparece numa
tela só. Abra uma execução e você vê o grafo: o fan-out para cada fonte, o
resultado de cada uma, e a chamada da normalização no fim.

| O que olhar | O que significa |
|---|---|
| Aba **Executions** | cada linha é uma coleta. Verde = terminou, vermelho = falhou |
| Clique numa execução | o grafo, com entrada e saída de cada passo |
| Um passo em **laranja** | aquela fonte degradou; as outras seguiram — é o comportamento desejado |

**Não existe execução nenhuma?** Os agendamentos estão desligados. Veja o
próximo item.

### 2. EventBridge Scheduler — os gatilhos

**Console → Amazon EventBridge → Scheduler → Schedules**

Três agendamentos:

| Nome | Quando | O que dispara |
|---|---|---|
| `onibus-tempo-real-coleta-posicoes` | `cron(* 8-16 ? * MON-FRI *)` — a cada minuto, 8h às 16h59, seg–sex | o fluxo, com a lista das fontes de posição |
| `onibus-tempo-real-coleta-cadastro` | `cron(0 7 ? * MON-FRI *)` — 7h, seg–sex | o fluxo, com a lista das fontes de cadastro |
| `onibus-tempo-real-heartbeat` | `rate(1 hour)` | a função que mede a idade do dado |

**Olhe a coluna `State`.** `DISABLED` significa que nada coleta sozinho — é
assim que a infraestrutura nasce, de propósito, para não gerar custo sem
alguém pedir. Ligar: `make tf-ligar`.

O fuso é `America/Sao_Paulo`. Sem ele o EventBridge assumiria UTC, e a janela
de 8h–17h rodaria de fato das 5h às 14h.

### 3. Lambda — as funções

**Console → Lambda → Functions**

Sete funções, todas rodando a **mesma imagem de container**:

| Função | Memória | Timeout | Papel |
|---|---:|---:|---|
| `onibus-tempo-real-sp-posicoes` | 256 MB | 30 s | posições de São Paulo |
| `onibus-tempo-real-rio-posicoes` | 256 MB | 30 s | posições do Rio |
| `onibus-tempo-real-sp-cadastro` | 512 MB | 60 s | linhas e pontos de SP |
| `onibus-tempo-real-rio-cadastro` | 512 MB | 60 s | linhas e pontos do Rio |
| `onibus-tempo-real-fortaleza-cadastro` | 512 MB | 420 s | linhas e pontos de Fortaleza |
| `onibus-tempo-real-silver` | 1024 MB | 300 s | bronze → Parquet canônico + H3 |
| `onibus-tempo-real-heartbeat` | 256 MB | 120 s | publica a idade do dado como métrica |

O timeout de Fortaleza é 7× o das outras porque a ETUFOR não publica GTFS
utilizável: é preciso uma chamada HTTP por linha para montar o itinerário.

Para ver o log de uma função: aba **Monitor → View CloudWatch logs**. Cada
função tem o próprio grupo de log, e o log é **JSON estruturado** — dá para
filtrar por campo.

### 4. S3 — onde o dado mora

**Console → S3 → `onibus-tempo-real-dev-<ID-DA-CONTA>`**

A estrutura de pastas é a arquitetura:

```
bronze/   NDJSON, como a fonte entregou. Expira em 30 dias (só posições)
silver/   Parquet particionado, schema canônico, com H3
gold/     as tabelas dimensionais construídas pelo dbt
athena-results/   resultado das consultas. Expira em 7 dias
```

Navegue até `silver/` e você verá o particionamento: `praca=sp/ano=2026/...`.
É isso que faz uma consulta por data ler só os arquivos daquele dia.

Existe um segundo bucket, `onibus-tempo-real-dev-auditoria-<ID-DA-CONTA>`, com
os logs do CloudTrail. Não há dado de negócio nele.

### 5. Athena e Glue — consultar em SQL

**Console → Athena → Query editor**

No seletor de workgroup, escolha **`onibus-tempo-real-dev`** (não o `primary`).
O workgroup carrega o local de resultado e um **corte de 1 GB por consulta** —
um erro de SQL não vira uma fatura.

Dois bancos no catálogo:

| Banco | Tabelas | Use quando |
|---|---|---|
| `onibus_tempo_real_dev_gold` | `dim_data`, `dim_linhas`, `dim_pontos`, `fato_posicoes` | **comece por aqui** — é o modelo pronto para análise |
| `onibus_tempo_real_dev` | `linhas`, `pontos`, `posicoes` | a silver crua, quando precisar do dado sem modelagem |

Uma consulta para confirmar que há dado:

```sql
SELECT praca, count(*) AS posicoes
FROM onibus_tempo_real_dev.posicoes
GROUP BY praca;
```

**Console → AWS Glue → Data catalog → Tables** mostra o schema de cada tabela.
Não há crawler: as tabelas são declaradas no Terraform e usam *partition
projection*, então nunca é preciso rodar `MSCK REPAIR`.

### 6. CloudWatch — saúde do pipeline

**Console → CloudWatch → Dashboards → `onibus-tempo-real-dev`**

O painel reúne execuções, erros e idade do dado por pipeline.

**Console → CloudWatch → Alarms** — são **15**, de três tipos, porque são três
modos de falha diferentes:

| Sufixo | Pergunta que responde |
|---|---|
| `-erro` | a função quebrou? (métrica `Errors`) |
| `-dado-velho` | a função **nem rodou**? (idade do dado, via heartbeat) |
| `-volume-baixo` | rodou sem erro, mas o dado veio ruim? (métrica extraída do log) |

O tipo `-dado-velho` existe porque a abordagem óbvia **não funcionou**: um
alarme sobre `Invocations` nunca disparava. A métrica é esparsa — sem
invocação não há ponto algum, e o CloudWatch, em vez de tratar a ausência como
zero, buscava para trás e encontrava um dado de dois dias antes, reportando
`OK` com a função parada havia 26 horas. A solução foi uma função que publica
de hora em hora uma métrica **densa** com a idade do dado.

### 7. EC2 — o Metabase

**Console → EC2 → Instances → `onibus-tempo-real-metabase`**

Uma `t4g.small` que **liga e desliga sob demanda**. Parada, custa só o disco
(~US$ 1,60/mês); ligada, ~US$ 0,017/hora.

**O IP público dela não atende a nada.** O Metabase escuta em `127.0.0.1` e o
security group não tem regra de entrada. O acesso passa por túnel SSM ou
Cloudflare Tunnel — ver [`CONSULTAS.md`](CONSULTAS.md).

Repare que a instância **não tem chave SSH** e usa um *instance profile*: a
credencial da AWS é temporária e rotacionada sozinha, e nenhuma chave de
acesso é digitada ou guardada.

O usuário e a senha de administrador **do Metabase** (que são outra coisa, e
diferentes dos do Metabase local) estão em
[`CONSULTAS.md`](CONSULTAS.md#1-túnel-ssm--para-você-mesmo).

### 8. Segurança da conta

| Onde olhar | O que deve estar lá |
|---|---|
| **CloudTrail → Trails** | `onibus-tempo-real-dev`, multi-região, com validação de integridade |
| **Billing → Budgets** | `onibus-tempo-real-dev`, teto de US$ 25, com alerta em 40%, 100% e na *previsão* |
| **S3 → Block Public Access (account settings)** | os quatro bloqueios ligados, no nível da **conta** |
| **EC2 → EBS encryption by default** | ligado |
| **Systems Manager → Parameter Store** | `/onibus-tempo-real/dev/sptrans-token` como `SecureString` |

O orçamento `My Zero-Spend Budget` é criado pela própria AWS em contas novas;
não é deste projeto.

---

## Diagnóstico: quando algo parou

Na ordem, do mais provável para o menos:

**1. Os agendamentos estão ligados?**
EventBridge Scheduler → coluna `State`. Se `DISABLED`, nada coleta. Ligue com
`make tf-ligar`.

**2. O fluxo executou?**
Step Functions → Executions. Sem execução recente, o problema está no gatilho,
não no código.

**3. Executou e falhou?**
Abra a execução: o passo vermelho mostra a exceção. Se um passo está laranja
(degradado) e os outros verdes, **só aquela fonte** quebrou — normalmente é a
origem fora do ar, não o pipeline.

**4. Executou, passou, mas não tem dado?**
Veja o log da função no CloudWatch. O log é JSON: procure `total_valido`. Se
vier zero, a fonte respondeu vazio ou mudou o formato.

### Alarmes vermelhos que são esperados

Se os agendamentos estiverem **desligados**, os cinco alarmes `-dado-velho`
ficam vermelhos em poucas horas. Isso é o sistema **funcionando**: ele foi
feito justamente para avisar que o dado parou de chegar. Não é uma falha a
investigar — é a consequência de ter desligado a coleta.

Para distinguir: alarme `-erro` vermelho é problema de verdade. Alarme
`-dado-velho` vermelho com agendamento desligado é consequência esperada.

---

## Onde o dinheiro vai

**Console → Billing → Cost Explorer**, agrupado por serviço.

Custo medido do projeto: **~US$ 2,56/mês**, dos quais ~86% é S3. Lambda,
EventBridge, Step Functions e SSM ficam dentro do nível gratuito permanente.

Os dois itens que podem crescer sozinhos:

- **S3**, se a regra de expiração de 30 dias do bronze for removida. Sem ela,
  o custo cresce todo mês em vez de estabilizar.
- **EC2 do Metabase**, se ficar ligada. Esquecida ligada o mês inteiro, custa
  mais que o resto do projeto somado.

Detalhes, cenários de sensibilidade e o plano de contingência estão em
[`DECISOES.md`](DECISOES.md).

---

## Sinais de alerta

Se encontrar algo desta lista, há algo errado:

- Um **security group com a porta 3000 aberta** para `0.0.0.0/0`. O Metabase
  nunca deve estar exposto — ele enxerga o data lake inteiro atrás de uma
  senha só.
- Um **bucket S3 público**. O bloqueio no nível da conta deveria impedir;
  se passou, alguém o desligou.
- Uma **chave de acesso** em variável de ambiente de Lambda, no user data da
  EC2 ou na conexão do Metabase. O projeto inteiro funciona sem nenhuma.
- **Execuções do Step Functions fora da janela** de 8h–17h em dia útil.
- Uma **função Lambda sem o prefixo** `onibus-tempo-real` nesta conta.

---

## Equivalentes no terminal

Para quem prefere não abrir o console:

```bash
make status                  # o pipeline está entregando?
make query SQL="..."         # consulta a silver
make query-gold SQL="..."    # consulta o modelo dimensional
make metabase-aws-ligar      # liga a EC2 do Metabase
make metabase-aws-tunel      # abre o túnel -> http://localhost:3000
make metabase-aws-desligar   # desliga
make tf-ligar / tf-desligar  # liga e desliga os agendamentos
```
