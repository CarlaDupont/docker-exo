# TP06 - Réseau Docker et dépannage

Fichiers : `compose.yml` et `nginx/default.conf` corrigés, `INCIDENT.md` (rapport d'incident), `.env.example`. Les fichiers d'origine sont dans `starter/`.

```bash
cp .env.example .env      # puis mettre deux mots de passe (openssl rand -hex 16)
docker compose up -d --wait
curl -i localhost:8081/products   # deux fois : X-Cache MISS puis HIT
```

Le starter construit l'API depuis `tp04-compose-entreprise/solution/`, qui n'est pas fourni. J'utilise `../tp01/shopapi` et `../tp04/db/init.sql`. C'est la seule modification faite avant de commencer le diagnostic (avec le passage des fins de ligne en LF).

## Partie 1 - Rappels réseau

- `docker run --name a` est refusé : `Invalid container name (a)`, un nom doit faire au moins 2 caractères. Ensuite `docker exec a` prend `a` pour un début d'ID (`multiple IDs found with provided prefix`). J'ai utilisé `a1` et `b1`.
- Bridge par défaut : `ping b1` donne `bad address`, alors que le ping par IP passe. `resolv.conf` pointe vers le DNS de la VM Docker Desktop (`192.168.65.7`).
- Réseau `demo` créé par l'utilisateur : `ping b1` passe, `resolv.conf` contient `nameserver 127.0.0.11`. Avec netshoot en `--network container:a1`, `ss -tlnp` montre le DNS embarqué qui écoute sur `127.0.0.11` (port aléatoire), et on voit les deux interfaces de `a1` (`172.17.0.2` et `192.168.128.2`).
- `none` : seulement `lo`. `internal` : pas d'accès à Internet (`bad address 'example.com'`). `host` : le conteneur voit les interfaces de la VM (`eth0`, `docker0`, les bridges) et son nom d'hôte est `docker-desktop`.
- `--expose 80` seul : `docker port` est vide, rien n'est joignable depuis l'hôte. Avec `-p 8089:80`, Docker ajoute dans la VM la règle `-A DOCKER -p tcp --dport 8089 -j DNAT --to-destination 172.17.0.5:80`. On ne peut pas la voir avec l'`iptables` de netshoot, qui utilise nftables : je l'ai lue avec `nsenter` dans l'espace réseau de `dockerd`.

## Partie 2

Voir `INCIDENT.md` : 15 anomalies, corrigées une par une en partant du port 8081. Résultat final, après un `down -v` pour repartir de zéro : les 5 services sont `healthy` en 21 s, `/products` renvoie le catalogue avec `X-Cache: MISS` puis `HIT`, et les ports 5432, 6379 et 3000 ne répondent pas depuis l'hôte.

Pièges rencontrés pendant le dépannage :
- après avoir changé `internal` sur un réseau, `docker compose up -d` ne recrée pas le réseau. Il faut un `docker compose down` (sans `-v`, pour garder la base).
- changer `POSTGRES_PASSWORD` ne change pas le mot de passe d'une base déjà initialisée. J'ai fait un `ALTER USER`, en passant la requête par l'entrée standard pour que le mot de passe n'apparaisse pas dans une ligne de commande.
- pour vérifier que l'ancien mot de passe ne marche plus, il faut tester depuis un autre conteneur : dans le conteneur de la base, `127.0.0.1` est en `trust` et accepte n'importe quel mot de passe.
- le mot de passe Redis est toujours visible dans `docker inspect` (il est dans la commande). Pour l'éviter, il faudrait un fichier de configuration Redis monté en secret.

## Partie 3

Classement des anomalies et garde-fous : voir la fin de `INCIDENT.md`.
