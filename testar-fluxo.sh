#!/usr/bin/env bash
#
# Exercises the whole collaborative flow against a running server.
#
# Usage:
#   Terminal 1:  swift run App serve --hostname 0.0.0.0 --port 8080
#   Terminal 2:  ./testar-fluxo.sh
#
# Against a deployed server:  BASE=https://seu-dominio ./testar-fluxo.sh

set -uo pipefail

BASE="${BASE:-http://localhost:8080}"
# Must match AURESGATE_API_KEY on the server. Empty exercises the unprotected
# local mode, which the server allows outside production.
KEY="${AURESGATE_API_KEY:-}"
PASS=0
FAIL=0

# Porto Alegre, roughly the coordinates from the field logs.
LAT=-30.020707
LON=-51.163201
# ~40 m away, standing in for a participant nearby.
PLAT=-30.021050
PLON=-51.163340

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32mok\033[0m    %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31mFALHOU\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

# Reads one top-level field out of a JSON payload.
field() { python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(''); raise SystemExit
k='$1'.split('.')
for part in k:
    if isinstance(d,list): d=d[int(part)]
    else: d=d.get(part) if isinstance(d,dict) else None
    if d is None: print(''); raise SystemExit
print(d)"; }

get()  { curl -s -H "X-AuResgate-Key: $KEY" "$BASE/$1"; }
post() { curl -s -X POST "$BASE/$1" \
           -H 'Content-Type: application/json' \
           -H "X-AuResgate-Key: $KEY" -d "$2"; }

bold "Servidor: $BASE"
echo

# ---------------------------------------------------------------- 1
bold "1. Disponibilidade"
HEALTH=$(curl -s --max-time 5 "$BASE/api/health")
if [ -z "$HEALTH" ]; then
  bad "sem resposta — o servidor está rodando?"
  echo
  echo "  Abra outro terminal e rode:"
  echo "    cd $(dirname "$0") && swift run App serve --hostname 0.0.0.0 --port 8080"
  exit 1
fi
[ "$(echo "$HEALTH" | field ok)" = "True" ] && ok "/api/health respondeu" || bad "resposta inesperada: $HEALTH"

# ---------------------------------------------------------------- 2
echo
bold "2. Tutor inicia a busca"
OWNER=$(uuidgen)
CREATED=$(post "api/searches" "{
  \"pet\": {\"name\":\"Sol\",\"breed\":\"Beagle\",
            \"nicknames\":[\"Solzinho\",\"Sol\"],
            \"note\":\"medroso com barulho\",\"major\":1,\"minor\":1},
  \"ownerId\": \"$OWNER\", \"ownerLabel\": \"Tutor\",
  \"origin\": {\"latitude\": $LAT, \"longitude\": $LON}}")

SEARCH=$(echo "$CREATED" | field id)
if [ -n "$SEARCH" ]; then
  ok "busca criada: $SEARCH"
else
  bad "não criou — resposta: $CREATED"; exit 1
fi
[ "$(echo "$CREATED" | field isOpen)" = "True" ] && ok "isOpen = true" || bad "isOpen deveria ser true"
[ "$(echo "$CREATED" | field pet.name)" = "Sol" ] && ok "pet decodificado" || bad "pet veio errado"
[ "$(echo "$CREATED" | field ownerTrail.0.coordinate.latitude)" = "$LAT" ] \
  && ok "rastro já tem o ponto de partida" || bad "rastro inicial ausente"

# nome do campo validado: o servidor recusa busca sem nome
REJECT=$(post "api/searches" "{
  \"pet\": {\"name\":\"  \",\"breed\":\"x\",\"nicknames\":[],\"note\":\"\",\"major\":1,\"minor\":1},
  \"ownerId\": \"$OWNER\", \"ownerLabel\": \"Tutor\",
  \"origin\": {\"latitude\": $LAT, \"longitude\": $LON}}")
echo "$REJECT" | grep -q "obrigat" && ok "recusa busca sem nome do animal" || bad "aceitou nome vazio"

# ---------------------------------------------------------------- 3
echo
bold "3. Quem está por perto encontra a busca"
NEARBY=$(get "api/searches/nearby?lat=$PLAT&lon=$PLON")
COUNT=$(echo "$NEARBY" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
[ "${COUNT:-0}" -ge 1 ] && ok "busca aparece na lista ($COUNT)" || bad "não apareceu: $NEARBY"

DIST=$(echo "$NEARBY" | field 0.distanceMeters)
if [ -n "$DIST" ]; then
  printf "  distância calculada: %.0f m (esperado ~40)\n" "$DIST"
  python3 -c "import sys; sys.exit(0 if 20 < $DIST < 70 else 1)" \
    && ok "haversine plausível" || bad "distância fora do esperado: $DIST"
fi

FAR=$(get "api/searches/nearby?lat=-23.5505&lon=-46.6333")
[ "$(echo "$FAR" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" = "0" ] \
  && ok "busca não aparece para quem está em São Paulo" || bad "raio não filtrou"

# ---------------------------------------------------------------- 4
echo
bold "4. Participante entra"
PART=$(uuidgen)
JOINED=$(post "api/searches/$SEARCH/join" "{\"participantId\":\"$PART\",\"label\":\"Ajudante\"}")
[ "$(echo "$JOINED" | field participantCount)" = "1" ] \
  && ok "contagem de participantes = 1" || bad "contagem errada: $(echo "$JOINED" | field participantCount)"

# entrar de novo com o mesmo id não deve duplicar
AGAIN=$(post "api/searches/$SEARCH/join" "{\"participantId\":\"$PART\",\"label\":\"Ajudante\"}")
[ "$(echo "$AGAIN" | field participantCount)" = "1" ] \
  && ok "reentrada não duplica (serve de heartbeat)" || bad "duplicou o participante"

# ---------------------------------------------------------------- 5
echo
bold "5. Detecção do sinal"
# -82 dBm: pelos dados de campo, ~10 m de estimativa e raio ~16 m
DETECTED=$(post "api/searches/$SEARCH/detections" "{
  \"participantId\":\"$PART\",\"participantLabel\":\"Ajudante\",
  \"coordinate\":{\"latitude\":$PLAT,\"longitude\":$PLON},
  \"radiusMeters\":16.3,\"rssi\":-82}")

[ "$(echo "$DETECTED" | field detections.0.rssi)" = "-82" ] \
  && ok "detecção registrada" || bad "não registrou: $DETECTED"
[ "$(echo "$DETECTED" | field detections.0.participantLabel)" = "Ajudante" ] \
  && ok "atribuída ao participante certo" || bad "rótulo errado"

NEG=$(post "api/searches/$SEARCH/detections" "{
  \"participantId\":\"$PART\",\"participantLabel\":\"Ajudante\",
  \"coordinate\":{\"latitude\":$PLAT,\"longitude\":$PLON},
  \"radiusMeters\":0,\"rssi\":-82}")
echo "$NEG" | grep -q "positivo" && ok "recusa raio não positivo" || bad "aceitou raio zero"

# segunda detecção: a mais recente deve vir primeiro
sleep 1
post "api/searches/$SEARCH/detections" "{
  \"participantId\":\"$PART\",\"participantLabel\":\"Ajudante\",
  \"coordinate\":{\"latitude\":-30.021400,\"longitude\":-51.163600},
  \"radiusMeters\":9.0,\"rssi\":-75}" > /dev/null
STATE=$(get "api/searches/$SEARCH")
[ "$(echo "$STATE" | field detections.0.rssi)" = "-75" ] \
  && ok "mais recente vem primeiro (vira o círculo no mapa)" || bad "ordenação errada"

# ---------------------------------------------------------------- 6
echo
bold "6. Rastro do tutor"
# ponto a ~5 m: deve ser descartado por estar perto demais do anterior
NEARPOINT=$(post "api/searches/$SEARCH/trail" "{
  \"ownerId\":\"$OWNER\",
  \"coordinate\":{\"latitude\":-30.020730,\"longitude\":-51.163220}}")
[ "$(echo "$NEARPOINT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['ownerTrail']))")" = "1" ] \
  && ok "descarta ponto a menos de 10 m" || bad "não descartou ponto próximo"

FARPOINT=$(post "api/searches/$SEARCH/trail" "{
  \"ownerId\":\"$OWNER\",
  \"coordinate\":{\"latitude\":-30.021200,\"longitude\":-51.163500}}")
[ "$(echo "$FARPOINT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['ownerTrail']))")" = "2" ] \
  && ok "aceita ponto distante" || bad "não acrescentou ao rastro"

INTRUDER=$(post "api/searches/$SEARCH/trail" "{
  \"ownerId\":\"$(uuidgen)\",
  \"coordinate\":{\"latitude\":$PLAT,\"longitude\":$PLON}}")
echo "$INTRUDER" | grep -q "tutor" && ok "só o tutor altera o rastro" || bad "outro usuário mexeu no rastro"

# ---------------------------------------------------------------- 7
echo
bold "7. Encerramento"
NOTOWNER=$(post "api/searches/$SEARCH/close" "{\"ownerId\":\"$(uuidgen)\",\"found\":true}")
echo "$NOTOWNER" | grep -q "tutor" && ok "participante não encerra a busca" || bad "qualquer um encerrou"

CLOSED=$(post "api/searches/$SEARCH/close" "{\"ownerId\":\"$OWNER\",\"found\":true}")
[ "$(echo "$CLOSED" | field isOpen)" = "False" ] && ok "tutor encerrou" || bad "não encerrou: $CLOSED"

GONE=$(get "api/searches/nearby?lat=$PLAT&lon=$PLON")
echo "$GONE" | grep -q "$SEARCH" && bad "busca encerrada ainda aparece como próxima" \
  || ok "busca encerrada sai da lista"

AFTER=$(post "api/searches/$SEARCH/detections" "{
  \"participantId\":\"$PART\",\"participantLabel\":\"Ajudante\",
  \"coordinate\":{\"latitude\":$PLAT,\"longitude\":$PLON},
  \"radiusMeters\":16.3,\"rssi\":-82}")
echo "$AFTER" | grep -q "encerrada\|não encontrada" \
  && ok "não aceita detecção em busca encerrada" || bad "aceitou detecção pós-encerramento"

# ---------------------------------------------------------------- 8
echo
bold "8. Erros tratados"
get "api/searches/$(uuidgen)" | grep -q "não encontrada" \
  && ok "404 para busca inexistente" || bad "id inexistente não retornou 404"
get "api/searches/nao-e-uuid" | grep -q "inválido" \
  && ok "400 para id malformado" || bad "id malformado não foi recusado"
get "api/searches/nearby" | grep -q "lat e lon" \
  && ok "400 quando falta lat/lon" || bad "aceitou nearby sem coordenadas"

# ---------------------------------------------------------------- 9
echo
bold "9. Chave de API"
if [ -z "$KEY" ]; then
  printf "  \033[33mpulado\033[0m servidor sem chave (modo local). "
  printf "Rode com AURESGATE_API_KEY=... para testar.\n"
else
  curl -s -H "X-AuResgate-Key: chave-errada" \
    "$BASE/api/searches/nearby?lat=$LAT&lon=$LON" | grep -q "inválida" \
    && ok "recusa chave errada" || bad "aceitou chave errada"
  curl -s "$BASE/api/searches/nearby?lat=$LAT&lon=$LON" | grep -q "inválida" \
    && ok "recusa requisição sem chave" || bad "aceitou requisição sem chave"
  [ "$(curl -s "$BASE/api/health" | field ok)" = "True" ] \
    && ok "/api/health continua aberto" || bad "health exigiu chave"
fi

# ---------------------------------------------------------------- fim
echo
bold "Resultado: $PASS ok, $FAIL falha(s)"
[ "$FAIL" -eq 0 ] || exit 1
