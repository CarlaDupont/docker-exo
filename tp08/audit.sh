#!/usr/bin/env bash
# Audit de durcissement des conteneurs en cours d'exécution.
# usage : ./audit.sh [projet compose]      (sans argument : tous les conteneurs)
# Code retour 1 s'il y a au moins un écart.
#
# Écarts relevés :
#   root      utilisateur vide, root ou 0
#   priv      conteneur --privileged
#   capdrop   les capabilities ne sont pas toutes retirées (cap_drop: [ALL])
#   capadd    capability dangereuse ajoutée (SYS_ADMIN, NET_ADMIN, SYS_PTRACE, SYS_MODULE, DAC_READ_SEARCH, ALL)
#   rw        système de fichiers racine en écriture
#   mem       pas de limite mémoire
#   pids      pas de limite de processus
#   nnp       pas de no-new-privileges
#   socket    socket Docker montée
set -uo pipefail

if [ $# -gt 0 ]; then
  IDS=$(docker ps -q --filter "label=com.docker.compose.project=$1")
else
  IDS=$(docker ps -q)
fi
[ -n "$IDS" ] || { echo "aucun conteneur en cours d'exécution${1:+ pour le projet $1}"; exit 1; }

FORMAT='{{.Name}}|{{.Config.User}}|{{.HostConfig.Privileged}}|{{join .HostConfig.CapAdd ","}}|{{join .HostConfig.CapDrop ","}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Memory}}|{{.HostConfig.PidsLimit}}|{{join .HostConfig.SecurityOpt ","}}|{{range .Mounts}}{{.Source}} {{end}}'

printf '%-21s %-12s %-5s %-24s %-8s %-5s %-7s %-6s %-4s %-6s %s\n' \
  CONTENEUR UTILISATEUR PRIV CAP_ADD CAP_DROP RO_FS MEMOIRE PIDS NNP SOCKET ECARTS
total=0
# shellcheck disable=SC2086
while IFS='|' read -r name user priv capadd capdrop ro mem pids secopt mounts; do
  name=${name#/}
  ecarts=""
  case "${user%%:*}" in ""|root|0) ecarts+="root " ;; esac
  [ "$priv" = true ] && ecarts+="priv "
  echo ",$capdrop," | grep -qi ',all,' || ecarts+="capdrop "
  echo ",$capadd," | grep -qiE ',(CAP_)?(SYS_ADMIN|NET_ADMIN|SYS_PTRACE|SYS_MODULE|DAC_READ_SEARCH|ALL),' && ecarts+="capadd "
  [ "$ro" = true ] || ecarts+="rw "
  [ "$mem" -gt 0 ] 2>/dev/null || ecarts+="mem "
  [ "$pids" -gt 0 ] 2>/dev/null || ecarts+="pids "
  echo "$secopt" | grep -q 'no-new-privileges' || ecarts+="nnp "
  socket=non
  echo "$mounts" | grep -q 'docker.sock' && { socket=oui; ecarts+="socket "; }

  mem_aff=-; [ "$mem" -gt 0 ] 2>/dev/null && mem_aff="$((mem / 1024 / 1024))M"
  pids_aff=-; [ "$pids" -gt 0 ] 2>/dev/null && pids_aff=$pids
  nnp=non; echo "$secopt" | grep -q 'no-new-privileges' && nnp=oui
  n=$(echo "$ecarts" | wc -w)
  total=$((total + n))
  printf '%-21s %-12s %-5s %-24s %-8s %-5s %-7s %-6s %-4s %-6s %s\n' \
    "$name" "${user:-root}" "$priv" "${capadd:--}" "${capdrop:--}" "$ro" "$mem_aff" "$pids_aff" "$nnp" "$socket" "${ecarts:-OK}"
done < <(docker inspect --format "$FORMAT" $IDS | sort)

echo
echo "écarts : $total"
[ "$total" -eq 0 ]
