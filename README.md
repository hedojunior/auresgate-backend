# AuResgate — servidor de buscas colaborativas

Backend em Vapor para o protótipo do TCC. Mantém as buscas ativas, a contagem
de participantes, o rastro do tutor e as detecções reportadas.

Armazenamento **em memória**: reiniciar o processo zera o estado. É suficiente
para o teste de campo e mantém o deploy sem dependência de banco. Trocar o
`SearchStore` por um repositório com Fluent não exigiria mudança nos
controladores.

## Chave de API

Todas as rotas sob `/api`, exceto `/api/health`, exigem o header
`X-AuResgate-Key`, conferido contra a variável de ambiente `AURESGATE_API_KEY`.

Gere uma chave:

```bash
openssl rand -hex 24
```

O mesmo valor vai em três lugares: na variável de ambiente do servidor, em
`ServerConfig.apiKey` no app iOS, e em `AURESGATE_API_KEY` ao rodar o script de
teste.

Sem a variável definida, o servidor **recusa iniciar em produção** — para não
subir uma API aberta por descuido. Localmente ele inicia com um aviso.

O que isso protege e o que não protege: a chave viaja dentro do app, então quem
conseguir ler o binário a extrai. Ela impede que a API responda a quem apenas
descobriu a URL, o que importa porque os endpoints carregam dados de
localização — coordenadas de cada detecção e o rastro do tutor. Não é
autenticação de usuário, e isso fica registrado como limitação no TCC.

## Rodar local

```bash
# sem chave, só para desenvolvimento
swift run App serve --hostname 0.0.0.0 --port 8080

# com chave
AURESGATE_API_KEY=sua-chave swift run App serve --hostname 0.0.0.0 --port 8080

curl http://localhost:8080/api/health
```

## Testar o fluxo

```bash
./testar-fluxo.sh                                    # servidor local sem chave
AURESGATE_API_KEY=sua-chave ./testar-fluxo.sh        # local com chave
BASE=https://seu-dominio AURESGATE_API_KEY=sua-chave ./testar-fluxo.sh
```

## Deploy

O `Dockerfile` serve para Railway, Fly.io, Render ou qualquer host que aceite
container. A porta vem da variável `PORT`, injetada pelo provedor.

**Railway**, caminho mais curto:

1. Suba este diretório como repositório no GitHub
2. railway.app → New Project → Deploy from GitHub repo
3. O Railway detecta o `Dockerfile` e constrói sozinho
4. Variables → adicione `AURESGATE_API_KEY` com a chave gerada
5. Settings → Networking → Generate Domain
6. Confira: `curl https://SEU-DOMINIO/api/health`

A primeira construção leva uns 5 a 8 minutos, porque compila o Swift inteiro.

Depois de ter o domínio, substitua em `ServerConfig.baseURL`, no app iOS.
**Os dois aparelhos precisam apontar para o mesmo valor** — se um ficar com o
placeholder, ele nunca enxerga o outro e o teste falha sem erro visível.

## Rotas

| Método | Rota | Função |
| --- | --- | --- |
| GET | `/api/health` | Verificação de disponibilidade |
| POST | `/api/searches` | Tutor inicia uma busca |
| GET | `/api/searches/nearby?lat=&lon=&radius=` | Buscas ativas num raio |
| GET | `/api/searches/:id` | Estado completo de uma busca |
| POST | `/api/searches/:id/join` | Entrar numa busca; serve de heartbeat |
| POST | `/api/searches/:id/leave` | Sair da busca |
| POST | `/api/searches/:id/detections` | Reportar detecção do sinal |
| POST | `/api/searches/:id/trail` | Acrescentar ponto ao rastro do tutor |
| POST | `/api/searches/:id/close` | Tutor encerra a busca |
| GET | `/api/searches/all` | Diagnóstico: tudo que o servidor guarda |

### Exercitar sem o app

```bash
BASE=https://SEU-DOMINIO
OWNER=$(uuidgen)

# Tutor inicia a busca
SEARCH=$(curl -s -X POST "$BASE/api/searches" \
  -H 'Content-Type: application/json' \
  -d "{\"pet\":{\"name\":\"Sol\",\"breed\":\"Beagle\",\"nicknames\":[\"Solzinho\"],\"note\":\"medroso\",\"major\":1,\"minor\":1},
       \"ownerId\":\"$OWNER\",\"ownerLabel\":\"Tutor\",
       \"origin\":{\"latitude\":-30.0207,\"longitude\":-51.1632}}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

# Quem está por perto encontra a busca
curl -s "$BASE/api/searches/nearby?lat=-30.0210&lon=-51.1635"

# Participante entra e reporta uma detecção
P=$(uuidgen)
curl -s -X POST "$BASE/api/searches/$SEARCH/join" \
  -H 'Content-Type: application/json' \
  -d "{\"participantId\":\"$P\",\"label\":\"Ajudante\"}" > /dev/null

curl -s -X POST "$BASE/api/searches/$SEARCH/detections" \
  -H 'Content-Type: application/json' \
  -d "{\"participantId\":\"$P\",\"participantLabel\":\"Ajudante\",
       \"coordinate\":{\"latitude\":-30.0209,\"longitude\":-51.1634},
       \"radiusMeters\":16.3,\"rssi\":-82}"
```

## Decisões de projeto registradas no código

**Participantes não têm posição transmitida.** O servidor guarda id, rótulo e
instante do último contato — nada de coordenada. A posição de um participante
só chega ao servidor no momento em que ele detecta o sinal, e chega como raio
de incerteza derivado do RSSI, não como ponto exato.

**Só o tutor tem rastro.** Ele expõe a própria posição por escolha explícita,
já que foi ele quem pediu ajuda. Pontos a menos de 10 m do anterior são
descartados, para o mapa mostrar área coberta e não um aglomerado de pontos.

**Participante expira em 90 s sem contato.** Sem isso, quem fechasse o app
inflaria a contagem de "X pessoas ajudando" indefinidamente.

**Chave compartilhada, não autenticação.** Há uma chave única para todo o
sistema, que impede acesso casual à URL pública mas não identifica usuários
nem autoriza por busca. Numa versão real a autenticação por usuário seria
indispensável, inclusive porque qualquer um capaz de iniciar uma busca dispara
notificação para todos os usuários próximos — vetor de abuso registrado no TCC
em vez de resolvido aqui.

**Encerre o serviço depois do teste.** O estado é em memória e não há o que
preservar; sem o servidor no ar não há superfície exposta.
