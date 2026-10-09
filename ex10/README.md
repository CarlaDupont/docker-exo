# Exercice 10 — Docker Compose : variables d'environnement et volumes

Application Spring Boot de notes + PostgreSQL.

Fichiers ajoutés :
- [.env](.env) : variables d'environnement
- [docker-compose.yml](docker-compose.yml) : services `app` et `db`, volumes `pg_data` et `uploads`
- [Dockerfile](Dockerfile) : image de l'application

Port 8080 occupé, l'application est sur le 8087 (`APP_PORT` dans le `.env`).

Commandes `curl` à lancer dans Git Bash (dans PowerShell, `curl` est un alias d'`Invoke-WebRequest`).

## Test 1 : Démarrage
```bash
docker compose up -d --build
docker compose ps
```

## Test 2 : Variables d'environnement
```bash
curl http://localhost:8087/api/info/env
```

## Test 3 : Créer des données
```bash
curl -X POST http://localhost:8087/api/notes -H "Content-Type: application/json" -d '{"title":"Test persistance","content":"Cette note doit survivre","category":"WORK","priority":"HIGH"}'
curl http://localhost:8087/api/notes
```

## Test 4 : Persistance des données
```bash
docker compose down
docker compose up -d
curl http://localhost:8087/api/notes
```
La note "Test persistance" est toujours là.

## Test 5 : Perte des données
```bash
docker compose down -v
docker compose up -d
curl http://localhost:8087/api/notes
```
Seules les 3 notes du script `init-db` restent.

## Test 6 : Modifier une variable
Dans `.env` :
```
APP_NAME=Mon Application Modifiée
```
```bash
docker compose up -d app
curl http://localhost:8087/api/info/app
```
`docker compose restart` ne suffit pas : il faut recréer le conteneur pour relire le `.env`.

## Les 3 méthodes d'injection utilisées
```yaml
APP_NAME: ${APP_NAME}             # depuis le .env
DB_HOST: db                       # valeur en dur
LOG_LEVEL: ${LOG_LEVEL:-INFO}     # avec valeur par défaut
```

## Nettoyage
```bash
docker compose down -v
docker rmi ex10-app
```
