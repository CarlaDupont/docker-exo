# Exercice 5 — MySQL et Adminer

Port 8080 occupé, Adminer est sur le 8082.

## 1. Créer le réseau et le volume
```bash
docker network create reseau-ex5
docker volume create mysql-data
```

## 2. MySQL
```bash
docker run -d --name mysql-ex5 --network reseau-ex5 --restart always -v mysql-data:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=root123 -e MYSQL_DATABASE=exercice5 -e MYSQL_USER=user5 -e MYSQL_PASSWORD=pass123 mysql:8.0
```

## 3. Adminer
```bash
docker run -d --name adminer-ex5 --network reseau-ex5 --restart always -p 8082:8080 adminer
```

## 4. Vérifier
```bash
docker ps
docker network inspect reseau-ex5
```

## 5. Connexion à Adminer
http://localhost:8082

- Système : MySQL
- Serveur : mysql-ex5
- Utilisateur : user5
- Mot de passe : pass123
- Base de données : exercice5

## 6. Créer une table et insérer des données
Dans Commande SQL :
```sql
CREATE TABLE utilisateurs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nom VARCHAR(100),
    email VARCHAR(150)
);

INSERT INTO utilisateurs (nom, email) VALUES
('Alice', 'alice@test.fr'),
('Bob', 'bob@test.fr'),
('Charlie', 'charlie@test.fr');

SELECT * FROM utilisateurs;
```

## 7. Persistance des données
```bash
docker rm -f mysql-ex5
docker run -d --name mysql-ex5 --network reseau-ex5 --restart always -v mysql-data:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=root123 -e MYSQL_DATABASE=exercice5 -e MYSQL_USER=user5 -e MYSQL_PASSWORD=pass123 mysql:8.0
```
Puis `SELECT * FROM utilisateurs;` dans Adminer.

## 8. Redémarrage automatique
`docker kill` est vu comme un arrêt manuel, le conteneur ne redémarre pas. On arrête donc le processus depuis le conteneur :
```bash
docker exec mysql-ex5 sh -c "kill 1"
docker inspect -f '{{.State.Status}} {{.RestartCount}}' mysql-ex5
```

## Bonus — Docker Compose
```bash
docker rm -f mysql-ex5 adminer-ex5
docker compose up -d
docker compose ps
```
Dans Adminer, le serveur est `mysql`.

```bash
docker compose down
docker compose up -d
```

## Nettoyage
```bash
docker compose down -v
docker network rm reseau-ex5
docker volume rm mysql-data
```
