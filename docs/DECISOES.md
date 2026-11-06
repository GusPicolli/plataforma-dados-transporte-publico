# Decisões de arquitetura e FinOps

Registro das escolhas estruturais: o que foi decidido, contra o que, e com
que critério. Números medidos, não estimados.

---

# Data warehouse, data lake ou híbrido?

**Decisão: data lake com catálogo e consulta SQL por cima** — S3 + Glue Data
Catalog + Athena, com modelagem dimensional em dbt.

## O que foi comparado

| Opção | O que seria | Custo mensal |
|---|---|---|
| **Data warehouse gerenciado** | Redshift ou Snowflake; dado carregado em tabelas proprietárias | US$ 200+ (menor nó Redshift, 24/7) |
| **Data lake puro** | S3 + Athena, sem modelagem | ~US$ 2 |
| **Híbrido (escolhido)** | S3 + catálogo + modelo dimensional em dbt, consultado por Athena | ~US$ 2,56 (medido) |

## Por que não o data warehouse

**O volume não justifica.** A silver inteira tem dezenas de MB. Um Redshift
do menor tamanho custaria ~100× o projeto inteiro para processar o que o
Athena responde em segundos.

**O formato das fontes não ajuda.** Duas das três entregam GTFS — zip com CSV
dentro — e uma entrega JSON de API não-oficial que muda sem aviso. Carregar
isso num schema rígido significa quebrar a carga toda vez que a origem mexe
numa coluna. O lake absorve a mudança: a bronze guarda como veio, e a quebra
aparece na validação, não na ingestão.

**O padrão de consulta é analítico e esparso.** Ninguém consulta de segundo
em segundo; são perguntas pontuais sobre partições recentes. Pagar por um
cluster ligado 24/7 para isso é pagar ociosidade.

## Por que não o data lake puro

Data lake sem modelagem vira pântano. Sem a camada dimensional, cada consulta
teria que redescobrir que o cadastro é refotografado a cada coleta (medido:
13.478 registros para 2.698 linhas reais) e que o fuso do Rio está três horas
adiantado. Esse conhecimento tem que morar no modelo, não na cabeça de quem
consulta.

## O que nos dá o híbrido

| Propriedade | Como |
|---|---|
| Esquema na leitura | o Glue descreve, a bronze não valida na escrita |
| Modelo confiável para consumo | dbt, com testes que falham quando a premissa quebra |
| Custo proporcional ao uso | Athena cobra por byte varrido; parado custa zero |
| Sem lock-in | Parquet no S3 — qualquer motor lê |

**Quando reconsiderar:** se a concorrência de leitura crescer a ponto de a
latência do Athena incomodar, ou se o volume passar a exigir atualização
incremental complexa. Nenhum dos dois está perto.

---

# FinOps

## O princípio

**O custo é definido mais pelo que se recusa do que pelo que se otimiza.**
Negociar preço de instância rende centavos; não escolher a arquitetura errada
rende ordens de grandeza.

## O que foi recusado, e quanto evitou

| Não contratado | Custo anual evitado | Por quê |
|---|---:|---|
| Data warehouse gerenciado | ~US$ 2.400 | o volume cabe no Athena |
| Airflow gerenciado (MWAA) | ~US$ 4.200 | Step Functions resolve o mesmo fan-out a custo ~zero |
| Metabase hospedado 24/7 | ~US$ 200 | roda local; o Athena é acessível de fora da AWS |
| Glue Crawler | ~US$ 100 | o schema já é conhecido — a silver grava a partir dele |
| Plataforma de observabilidade paga | ~US$ 600 | CloudWatch com alarmes bem desenhados basta |
| **Total evitado** | **~US$ 7.500/ano** | |

A maior economia não está em nenhuma linha de fatura — está em decisões que
nunca viraram linha.

## Estimado vs. real

Dado real do AWS Cost Explorer, 01/10 a 22/10/2026, na planilha
[`custos_estimado_vs_real.xlsx`](custos_estimado_vs_real.xlsx).

| | Estimado (proposta) | Real projetado |
|---|---:|---:|
| Total mensal | US$ 17,65 | **US$ 2,56** |

**O desvio de −US$ 15,09 é quase inteiramente o Metabase.** A proposta previa
um container 24/7 na AWS; decidimos rodar local, e o custo foi a zero sem
perder nada — o Athena atende de qualquer lugar.

O que de fato custa:

| Serviço | Real (21 dias) | Observação |
|---|---:|---|
| S3 | US$ 1,5425 | 86% do total |
| Impostos | US$ 0,2100 | |
| ECR | US$ 0,0206 | imagem do container |
| CloudWatch | US$ 0,0161 | |
| Athena | US$ 0,0026 | |
| Lambda, EventBridge, Step Functions, SSM | US$ 0,00 | dentro do free tier permanente |

**S3 é o único custo que importa, e é o único que cresce sozinho.**

## A alavanca que realmente mexe no custo

Medido: cada coleta das duas praças grava **4,15 MB**. Na janela de
8h–16h59 a cada minuto, de segunda a sexta, são ~11.700 coletas/mês =
**~48 GB/mês de dado novo**.

| Cenário | Mês 1 | Mês 12 |
|---|---:|---:|
| Sem retenção | US$ 1,09 | **US$ 13,10** (e subindo) |
| Com retenção de 30 dias no bronze de posições | US$ 1,09 | **US$ 1,09** (estável) |

A regra de ciclo de vida é o que transforma um custo que cresce todo mês num
custo fixo. Ela expira **só o bronze de posições**: a silver é 93% menor,
guarda o mesmo dado já normalizado, e é o que as consultas usam.

## Sensibilidade

| Mudança | Efeito |
|---|---|
| Cadência 1 min → 30 min (como no plano original) | custo de S3 cai ~30× |
| Ampliar a janela para 5h–23h, todo dia | ~2,8× o volume; a Lambda chega perto do limite do free tier |
| Incluir os picos (6h–9h e 17h–19h) | +55% de volume — é a mudança mais provável de ser pedida |
| Entrar uma quarta praça | +50% de volume e de execuções |
| Hospedar o Metabase | +US$ 16–18/mês — dobraria o projeto várias vezes |

Com a janela de horário comercial a Lambda consome **~129 mil dos 400 mil
GB-s** gratuitos — folga confortável. Na janela anterior (5h–23h, todo dia)
eram ~356 mil, perto demais do limite.

---

# Plano de contingência de orçamento

## Os gatilhos

| Nível | Condição | Ação |
|---|---|---|
| **Atenção** | custo mensal projetado > US$ 10 | investigar o que mudou antes de agir |
| **Ação** | > US$ 25 | aplicar as alavancas 1 e 2 abaixo |
| **Emergência** | > US$ 50 | `make tf-desligar` e diagnosticar com a coleta parada |

Hoje o custo é US$ 2,56/mês — o gatilho de atenção é ~4× o atual, folga
suficiente para não disparar por ruído.

## As alavancas, em ordem de impacto por esforço

**1. Reduzir a cadência das posições.** Uma variável, um apply:

```bash
# de 1 minuto para 5 minutos: corta o volume em 5x
terraform apply -var 'agenda_posicoes=cron(0/5 8-16 ? * MON-FRI *)'
```

É reversível, não perde dado histórico e não mexe em arquitetura.

**2. Encurtar a retenção do bronze.** De 30 para 7 dias corta o
armazenamento de posições em ~4×. A silver continua guardando tudo.

**3. Estreitar a janela.** A janela já é horário comercial (8h–17h, seg-sex);
cortar para só as pontas do expediente (8h–10h e 15h–17h) reduz o volume pela
metade.

**4. Desligar tudo.** `make tf-desligar` para a coleta sem destruir nada. Os
dados ficam, as consultas seguem funcionando.

A ordem importa: as três primeiras preservam a operação; a quarta a
interrompe. Nenhuma exige recriar infraestrutura.

## Como acompanhar

- `make status` — se os pipelines estão entregando
- AWS Cost Explorer, agrupado por serviço — onde o dinheiro está indo
- A planilha de estimado vs. real, atualizada mensalmente

**O que ainda falta:** um AWS Budget com alerta automático por e-mail. Hoje o
acompanhamento depende de alguém olhar — o mesmo problema que o heartbeat
resolveu para o pipeline, e que aqui continua aberto.
