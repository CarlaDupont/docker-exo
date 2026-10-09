# Exercice 9 — API CRUD + API Logs

- `crud-api` : CRUD des chiens (MySQL), envoie un log à `logs-api` à chaque appel (RestTemplate)
- `logs-api` : stocke les logs dans un fichier (`/data/logs.jsonl`, volume Docker)

Niveaux : `INFO` appel réussi, `WARN` erreur client (404, 400), `ERR` erreur serveur (500).

Ports : crud-api 8085, logs-api 8086, MySQL 3308.

## 1. Réseau, volumes et MySQL
```bash
docker network create reseau-ex9
docker volume create mysql-ex9-data
docker volume create logs-ex9-data
docker run -d --name mysql-ex9 --network reseau-ex9 -p 3308:3306 -v mysql-ex9-data:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=root123 -e MYSQL_DATABASE=dogsdb -e MYSQL_USER=doguser -e MYSQL_PASSWORD=pass123 --restart always mysql:8.0
```

## 2. Tester en local
Dans deux terminaux :
```bash
cd logs-api
mvn spring-boot:run -Dspring-boot.run.arguments=--server.port=8086
```
```bash
cd crud-api
mvn spring-boot:run -Dspring-boot.run.arguments=--server.port=8085
```
Arrêter les deux (Ctrl+C) avant la suite.

## 3. Construire les images
```bash
cd logs-api
docker build -t logs-api .
cd ../crud-api
docker build -t crud-api .
```

## 4. Lancer les APIs
```bash
docker run -d --name logs-api-container --network reseau-ex9 -p 8086:8080 -v logs-ex9-data:/data logs-api
docker run -d --name crud-api-container --network reseau-ex9 -p 8085:8080 -e DB_URL=jdbc:mysql://mysql-ex9:3306/dogsdb -e DB_USER=doguser -e DB_PASSWORD=pass123 -e LOGS_API_URL=http://logs-api-container:8080 crud-api
```

## 5. Tester le CRUD
```powershell
$u = "http://localhost:8085/api/v1/dogs"

Invoke-RestMethod -Uri $u

$dog = @{ name = "Rex"; breed = "Labrador"; birthDate = "2021-05-10"; sterilized = $true } | ConvertTo-Json
Invoke-RestMethod -Uri $u -Method POST -ContentType "application/json" -Body $dog

Invoke-RestMethod -Uri "$u/1"

$dog = @{ name = "Max"; breed = "Golden Retriever"; birthDate = "2021-05-10"; sterilized = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$u/1" -Method PUT -ContentType "application/json" -Body $dog

Invoke-RestMethod -Uri "$u/1" -Method DELETE
```

Provoquer des erreurs :
```powershell
Invoke-RestMethod -Uri "$u/99"     # WARN 404
Invoke-RestMethod -Uri "$u/abc"    # WARN 400
docker stop mysql-ex9
Invoke-RestMethod -Uri $u          # ERR 500
docker start mysql-ex9
```

## 6. Consulter les logs
```powershell
Invoke-RestMethod -Uri http://localhost:8086/api/v1/logs | Format-Table
```

Ajouter un log à la main :
```powershell
$log = @{ message = "test"; source = "[Manuel] POST"; level = "INFO" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:8086/api/v1/logs -Method POST -ContentType "application/json" -Body $log
```

## Nettoyage
```bash
docker rm -f crud-api-container logs-api-container mysql-ex9
docker network rm reseau-ex9
docker volume rm mysql-ex9-data logs-ex9-data
docker rmi crud-api logs-api
```
