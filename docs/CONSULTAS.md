# Consultando os dados (Athena)

Há **duas camadas** no catálogo Glue, e qual usar depende do que você quer.

| Banco | O que é | Use quando |
|---|---|---|
| `onibus_tempo_real_dev_gold` | modelo dimensional: fato, dimensões e geoespacial | **quase sempre** |
| `onibus_tempo_real_dev` | a silver crua: todo o histórico, como foi coletado | auditar, reprocessar, investigar |

```bash
make query-gold SQL="SELECT praca, count(*) FROM dim_linhas GROUP BY praca"
make query      SQL="SELECT praca, count(*) FROM linhas GROUP BY praca"
```

No console: Athena → workgroup `onibus-tempo-real-dev` → escolha o banco.

---

# Camada dimensional (dbt)

Construída com **dbt**, em [`transform/models/`](../transform/models/).

```bash
make dbt-deps     # primeira vez
make dbt-build    # roda os modelos E os testes
make dbt-docs     # catálogo navegável com o grafo de linhagem
```

O dbt descobre a ordem sozinho pelo grafo de dependência — não há numeração
de arquivo. Modelo novo que referencie outro com `{{ ref() }}` entra no lugar
certo automaticamente.

| Modelo | Tipo | Materialização | O que é |
|---|---|---|---|
| `dim_linhas` | dimensão | view | uma linha por linha de ônibus, versão mais recente |
| `dim_pontos` | dimensão | view | par (linha, parada), com geometria |
| `dim_data` | dimensão | tabela | calendário gerado |
| `fato_posicoes` | **fato** | tabela | um veículo num instante, com medidas geoespaciais |

**Por que materializações diferentes:** as dimensões são pequenas e mudam
pouco — view basta. O `fato_posicoes` calcula a distância de cada veículo até
a parada mais próxima da sua linha, que é uma junção com agregação; não vale
repetir a cada consulta. A `dim_data` é gerada, não derivada — recalcular
sempre não faz sentido.

## Tratamento geoespacial

| Coluna | Onde | O que é |
|---|---|---|
| `geometria_wkt` | `dim_pontos`, `fato_posicoes` | ponto em WKT, que QGIS e a maioria dos BIs leem |
| `tile_z14` | `dim_pontos`, `fato_posicoes` | tile do Bing no zoom 14 (~2 km); agrega por região com `GROUP BY` |
| `metros_ate_parada_mais_proxima` | `fato_posicoes` | **medida**: distância até a parada mais próxima da própria linha |

Medido em SP: mediana de **46 m**, p90 de 123 m, máximo de 708 m. Responde
"o ônibus está num ponto ou no meio do caminho?" sem precisar de mapa.

**Use `great_circle_distance`, não `ST_Distance`.** O primeiro devolve
quilômetros (verificado: SP→Rio = 360,7). O segundo devolve **graus**, que
não é distância — é o erro mais comum com geo no Athena.

```sql
-- densidade espacial: onde estão os ônibus agora
SELECT tile_z14, count(*) AS veiculos, round(avg(velocidade), 1) AS vel_media
FROM fato_posicoes
WHERE praca = 'sp'
GROUP BY tile_z14
ORDER BY veiculos DESC
LIMIT 10;

-- ônibus parados longe de qualquer ponto (possível congestionamento)
SELECT codigo_publico, id_veiculo, metros_ate_parada_mais_proxima, velocidade
FROM fato_posicoes
WHERE praca = 'sp'
  AND metros_ate_parada_mais_proxima > 300
  AND velocidade = 0
ORDER BY metros_ate_parada_mais_proxima DESC;
```

Fortaleza fica sem geometria: a ETUFOR entrega logradouro, não coordenada. O
Rio fica sem `metros_ate_parada_mais_proxima` enquanto o `rio_cadastro`
estava quebrado — hoje funciona.

## Os testes avisam o que está errado

`make dbt-build` roda 16 testes. **14 passam e 2 avisam**, de propósito:

| Aviso | O que significa |
|---|---|
| 1.104 resultados em `(praca, codigo_base)` único | o letreiro base de SP não distingue variantes: 2,44 linhas por base |
| 242 posições sem linha correspondente | linhas que circulam mas não constam no cadastro mais recente |

Ficam como **aviso e não erro** por um motivo prático: teste que falha sempre
e bloqueia o pipeline acaba sendo desligado — e aí deixa de avisar qualquer
coisa. Como aviso, aparece em todo `dbt build` até a dívida ser paga.

**Consequência do primeiro:** `count(*)` e `sum()` sobre o join
`fato_posicoes × dim_linhas` contam ~2,4 vezes em SP. `count(DISTINCT)` é
seguro. Ver "Dívidas do modelo" em [MODELAGEM.md](MODELAGEM.md).

## Exemplos

```sql
-- as três cidades numa consulta
SELECT praca,
       count(DISTINCT id_veiculo) AS veiculos,
       round(avg(velocidade), 1)  AS velocidade_media,
       round(avg(metros_ate_parada_mais_proxima)) AS dist_media_parada
FROM fato_posicoes
GROUP BY praca;

-- dia útil contra fim de semana, usando a dimensão de data
SELECT d.nome_do_dia, count(DISTINCT f.id_veiculo) AS veiculos
FROM fato_posicoes f
JOIN dim_data d ON d.data = date(f.instante_utc)
GROUP BY d.nome_do_dia;

-- origem e destino das linhas com mais veículos (SP)
SELECT f.codigo_publico, max(l.origem) AS origem, max(l.destino) AS destino,
       count(DISTINCT f.id_veiculo) AS veiculos
FROM fato_posicoes f
JOIN dim_linhas l ON l.chave_linha = f.chave_linha
WHERE f.praca = 'sp'
GROUP BY f.codigo_publico
ORDER BY veiculos DESC
LIMIT 10;
```

Repare no `chave_linha` em vez de `codigo_base`: ela embute a praça. Sem
isso, 1.202 posições do Rio casavam falsamente com linhas de SP de mesmo
número.

---

# Dashboards (Metabase local)

```bash
make metabase        # sobe em http://localhost:3000, ja conectado
make metabase-stop   # para; dashboards ficam salvos
```

Roda **na sua máquina**, não na AWS. O Athena é acessível de fora, então não
há motivo para pagar um container 24/7 na nuvem enquanto só você usa — um
Metabase hospedado seria o item mais caro do projeto, que hoje custa ~US$ 4/mês.

O `make metabase` já deixa tudo pronto: sobe o container, cria a conta de
administrador local e configura as duas conexões (gold e silver). Comece pela
**Onibus - gold**.

## Rodando na AWS, para outras pessoas acessarem

```bash
make metabase-aws-ligar      # liga e libera o SEU IP atual
make metabase-aws-conexao    # mostra os valores da conexão
make metabase-aws-desligar   # desliga; dashboards ficam
```

Uma EC2 `t4g.small` que liga e desliga sob demanda. **Ligar e desligar não
destrói nada** — o disco EBS persiste, e com ele dashboards, usuários e
conexões.

### A diferença que importa: nada de chave de acesso

No Metabase local foi preciso guardar access key no banco dele, porque a
cadeia de credenciais não funcionou no container. Na EC2 isso some: a
instância tem um **instance profile**, e o driver pega credencial temporária
sozinho pelo IMDS.

Ao configurar a conexão, marque *"Use Default Credentials Provider Chain"* e
**não preencha chave nenhuma**.

### Custo

| | Sempre ligado | Só horário comercial (~220h/mês) |
|---|---:|---:|
| `t4g.small` | US$ 12,26 | US$ 3,70 |
| EBS 20 GB gp3 | US$ 1,60 | US$ 1,60 (cobrado mesmo parado) |
| IPv4 público | US$ 3,60 | US$ 1,10 (devolvido no stop) |
| **Total** | **US$ 17,46** | **US$ 6,40** |

Por que EC2 e não Fargate: lá o container pode ser substituído a qualquer
momento, então o banco de metadados precisaria de RDS — ~US$ 13/mês que
**não desligam**, porque a AWS religa um RDS parado depois de 7 dias.

### Segurança

A porta 3000 fica fechada por padrão. O `metabase-aws-ligar` descobre o seu
IP público do momento e libera **só ele** (`/32`). Metabase aberto para a
internet, com conta de administrador, enxerga o data lake inteiro.

Se o seu IP mudar (rede nova, IP dinâmico), rode o `ligar` de novo — ele
atualiza a regra.

## Em SQL nativo, qualifique o schema

Montando perguntas pela interface, o Metabase resolve o nome sozinho. Mas se
você escrever SQL direto, precisa do schema na frente:

```sql
-- CERTO
SELECT praca, count(DISTINCT id_veiculo)
FROM onibus_tempo_real_dev_gold.fato_posicoes
WHERE dt = '2026-10-09' GROUP BY praca;

-- ERRADO: "SCHEMA_NOT_FOUND: Schema 'default' does not exist"
FROM fato_posicoes
```

## Sobre a credencial

A conexão usa chave de acesso explícita, não a cadeia de credenciais da AWS.
Foi tentativa e erro: mesmo com `~/.aws/credentials` montado, corrigido de
CRLF para LF e com `AWS_SHARED_CREDENTIALS_FILE` apontando para ele, o driver
continuou reportando `ProfileFile(sections=[])`. A cadeia simplesmente não
funciona nessa combinação de imagem e driver.

A chave fica guardada no banco local do Metabase — a mesma chave que já está
em texto plano no seu `~/.aws/credentials`, na mesma máquina. Se um dia isso
for hospedado, troque por um perfil de instância (IAM role), que elimina a
chave de vez.

Uma descoberta de lado: o CRLF em `~/.aws/credentials` quebra **qualquer**
ferramenta AWS escrita em Java, não só o Metabase. O `boto3` tolera; o SDK
Java não reconhece a seção `[default]
`.

## Para apagar e recomeçar

```bash
make metabase-limpar   # remove o container E todos os dashboards (pede confirmação)
```

---

# Camada silver (a crua)

## As tabelas

| Tabela | Uma linha é | Colunas |
|---|---|---|
| `posicoes` | um veículo num instante | `id_veiculo`, `id_linha`, `codigo_publico`, `latitude`, `longitude`, `velocidade`, `timestamp_veiculo`, `coletado_em` |
| `linhas` | uma linha cadastrada | `id_linha`, `codigo_publico`, `nome`, `origem`, `destino`, `coletado_em` |
| `pontos` | uma parada de uma linha | `id_ponto`, `id_linha`, `codigo_publico`, `nome`, `latitude`, `longitude`, `coletado_em` |

**Uma tabela por entidade, não por cidade.** É o que a camada canônica compra:
posições de SP, Rio e Fortaleza têm o mesmo schema, então `praca` é só uma
partição. Comparar as três cidades é um `GROUP BY`, não um `UNION ALL`.

Partições de todas: `praca`, `entidade`, `dt` (data UTC), `hh` (hora UTC).

## Antes de escrever a primeira query: a chave de junção

**`codigo_publico` não tem o mesmo formato em todas as tabelas.** Isso não é
bug do Athena, é uma limitação do mapeamento da silver — cada endpoint de
origem usa um formato diferente para o mesmo conceito:

| Tabela (SP) | Exemplo | O que é |
|---|---|---|
| `posicoes` | `273G-10` | letreiro **com** sentido |
| `pontos` | `1012-10` | letreiro **com** sentido (GTFS) |
| `linhas` | `1012` | letreiro **sem** sentido |

Na prática:

- `posicoes` ↔ `pontos` → junta **direto**
- `posicoes` ↔ `linhas` → precisa de `split_part(codigo_publico, '-', 1)`

```sql
-- CERTO
JOIN linhas l ON l.praca = p.praca
             AND l.codigo_publico = split_part(p.codigo_publico, '-', 1)

-- ERRADO: devolve zero linhas, silenciosamente
JOIN linhas l ON l.codigo_publico = p.codigo_publico
```

**Isso já está resolvido na gold** (`codigo_base`). Esta seção descreve a
silver crua, para quem precisa consultá-la direto.

## Nem toda coluna vem preenchida

Campo que a fonte não tem fica **nulo de propósito** — nulo honesto é melhor
que valor inventado. O que cada praça entrega:

| Coluna | SP | Rio | Fortaleza |
|---|:--:|:--:|:--:|
| `posicoes.velocidade` | — | ✅ | sem posições |
| `linhas.nome` | — | ✅ | ✅ |
| `linhas.origem` / `destino` | ✅ | — | — |
| `pontos.latitude` / `longitude` | ✅ | ✅ | — |

Fortaleza não tem posições (a ETUFOR não expõe GPS em tempo real) e seus
pontos não têm coordenada (só a sequência de logradouros).

O Rio ficou semanas sem `linhas` nem `pontos` porque o GTFS mudou de
endereço sem aviso. Já corrigido — as três praças têm cadastro hoje.

## `timestamp_veiculo` do Rio está 3 horas adiantado

**A API do Data.Rio devolve horário de Brasília com sufixo `Z`**, que significa
UTC. Medido: às 23:50 UTC a origem respondeu `20:49:45Z` — o relógio de
Brasília. É um defeito da origem, não do pipeline: a bronze registra
fielmente o que chegou.

Consequência: `timestamp_veiculo` **não é comparável entre praças**. SP está em
UTC de verdade; o Rio, três horas atrás.

```sql
-- Medindo o frescor, isto dá ~42s para SP e ~10.800s para o Rio.
-- Os 10.800 são as 3 horas de fuso, não atraso de coleta.
SELECT praca, approx_percentile(date_diff('second',
         from_iso8601_timestamp(timestamp_veiculo),
         from_iso8601_timestamp(coletado_em)), 0.5) AS mediana_s
FROM posicoes WHERE dt = '2026-10-09' GROUP BY praca;
```

Enquanto não for corrigido, some 3 horas ao valor do Rio:

```sql
CASE WHEN praca = 'rio'
     THEN from_iso8601_timestamp(timestamp_veiculo) + INTERVAL '3' HOUR
     ELSE from_iso8601_timestamp(timestamp_veiculo)
END AS instante_utc
```

**Isso já está corrigido na camada dimensional** (`fato_posicoes.instante_utc`). A silver
preserva o valor como a origem mandou de propósito: se a fonte consertar o
fuso do lado dela, dá para perceber comparando as duas camadas.

## Exemplos (na silver crua)

### As três cidades numa consulta

```sql
WITH ultima AS (SELECT max(dt) AS d FROM posicoes)
SELECT p.praca,
       count(DISTINCT p.id_veiculo)     AS veiculos,
       count(DISTINCT p.codigo_publico) AS linhas_circulando,
       round(avg(p.velocidade), 1)      AS velocidade_media
FROM posicoes p, ultima
WHERE p.dt = ultima.d
GROUP BY p.praca
ORDER BY veiculos DESC;
```

### Linhas com mais veículos, e quantas paradas têm

```sql
SELECT p.codigo_publico,
       count(DISTINCT p.id_veiculo) AS veiculos,
       count(DISTINCT pt.id_ponto)  AS paradas
FROM posicoes p
JOIN pontos pt ON pt.praca = p.praca
              AND pt.codigo_publico = p.codigo_publico
WHERE p.praca = 'sp' AND p.dt = date_format(current_date, '%Y-%m-%d')
GROUP BY p.codigo_publico
ORDER BY veiculos DESC
LIMIT 10;
```

### Origem e destino de uma linha em circulação (SP)

```sql
SELECT DISTINCT p.codigo_publico, l.origem, l.destino
FROM posicoes p
JOIN linhas l ON l.praca = p.praca
             AND l.codigo_publico = split_part(p.codigo_publico, '-', 1)
WHERE p.praca = 'sp' AND p.dt = '2026-10-09'
LIMIT 20;
```

### Frescor do dado: distância entre o ping do veículo e a coleta

```sql
SELECT praca,
       approx_percentile(date_diff('second',
            from_iso8601_timestamp(timestamp_veiculo),
            from_iso8601_timestamp(coletado_em)), 0.5) AS mediana_s
FROM posicoes
WHERE dt = '2026-10-09' AND timestamp_veiculo IS NOT NULL
GROUP BY praca;
```

## Custo, e como não desperdiçar

O Athena cobra **US$ 5,00 por TB varrido**. A silver inteira tem dezenas de
MB, então uma consulta custa frações de centavo — mas a disciplina vale desde
já, porque é a mesma que segura a conta quando o volume cresce.

**Filtre por partição.** `WHERE praca = 'sp' AND dt = '2026-10-09'` faz o
Athena ler só aquele prefixo. Sem filtro, ele lê tudo.

**Selecione colunas.** Parquet é colunar: `SELECT id_veiculo` lê só aquela
coluna; `SELECT *` lê todas.

O workgroup tem um corte em **1 GB por consulta**. No tamanho atual isso nunca
dispara por uso legítimo — é freio contra o acidente de varrer tudo, não
limite de uso. Resultados de consulta são apagados do S3 após 7 dias.

## Por que não há Glue Crawler

As tabelas são **declaradas** em [`infra/terraform/athena.tf`](../infra/terraform/athena.tf),
não descobertas. Um crawler cobra por execução (mínimo de 10 minutos a cada
passada) e **infere** o schema — e o schema já é conhecido, porque a silver
grava a partir de [`schemas/canonico.py`](../schemas/canonico.py). Pagar para
uma ferramenta adivinhar o que já está declarado em código adiciona custo e
incerteza ao mesmo tempo.

Pelo mesmo motivo não existe `MSCK REPAIR TABLE` aqui: as tabelas usam
**projeção de partição**, que calcula as partições a partir do padrão do
caminho. Sem isso seria preciso registrar partição nova a cada hora — ou a
cada minuto, durante a janela de posições.
