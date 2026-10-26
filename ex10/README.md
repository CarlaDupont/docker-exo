# Exercice 10 — Docker Compose : variables d'environnement et volumes

Application de notes en Spring Boot avec PostgreSQL. J'ai ajouté le `.env`, le `docker-compose.yml` et le `Dockerfile`.

Le port 8080 étant déjà pris, l'application est sur le 8087 (`APP_PORT` dans le `.env`).

Les commandes `curl` sont à lancer dans Git Bash, dans PowerShell `curl` ne marche pas pareil.

Il n'y a pas de page d'accueil, il faut aller sur http://localhost:8087/api/notes.

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
