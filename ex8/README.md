# Exercice 8 — API Spring Boot avec MySQL

Port 8080 occupé, l'API est sur le 8084. Projet en Java 17.

## 1. Réseau et MySQL
```bash
docker network create reseau-ex8
docker volume create mysql-ex8-data
docker run -d --name mysql-ex8 --network reseau-ex8 -p 3307:3306 -v mysql-ex8-data:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=root123 -e MYSQL_DATABASE=dogsdb -e MYSQL_USER=doguser -e MYSQL_PASSWORD=pass123 --restart always mysql:8.0
```

## 2. Tester l'API en local
```bash
cd dogsapi
mvn spring-boot:run -Dspring-boot.run.arguments=--server.port=8084
```
http://localhost:8084/api/v1/dogs

Arrêter l'API locale (Ctrl+C) avant la suite.

## 3. Construire l'image
```bash
docker build -t dogs-api .
```

## 4. Lancer l'API avec Docker
```bash
docker run -d --name dogs-api-container --network reseau-ex8 -p 8084:8080 -e DB_URL=jdbc:mysql://mysql-ex8:3306/dogsdb -e DB_USER=doguser -e DB_PASSWORD=pass123 dogs-api
```

## 5. Vérifier
```bash
docker ps
docker logs dogs-api-container
```

## 6. Tester les endpoints
```powershell
$u = "http://localhost:8084/api/v1/dogs"

# GET liste
Invoke-RestMethod -Uri $u

# POST
$dog = @{ name = "Rex"; breed = "Labrador"; birthDate = "2021-05-10"; sterilized = $true } | ConvertTo-Json
Invoke-RestMethod -Uri $u -Method POST -ContentType "application/json" -Body $dog

# GET un chien
Invoke-RestMethod -Uri "$u/1"

# PUT
$dog = @{ name = "Max"; breed = "Golden Retriever"; birthDate = "2021-05-10"; sterilized = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$u/1" -Method PUT -ContentType "application/json" -Body $dog

# DELETE
Invoke-RestMethod -Uri "$u/1" -Method DELETE
```

## 7. Vérifier dans MySQL
```bash
docker exec -it mysql-ex8 mysql -u doguser -p dogsdb
```
Mot de passe : `pass123`
```sql
SELECT * FROM dogs;
```

## Nettoyage
```bash
docker rm -f dogs-api-container mysql-ex8
docker network rm reseau-ex8
docker volume rm mysql-ex8-data
docker rmi dogs-api
```
