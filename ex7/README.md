# Exercice 7 — MySQL et kennelDB

## 1. Construire l'image
```bash
docker build -t kennel-mysql .
```

## 2. Lancer le conteneur
```bash
docker run -d --name kennel-container kennel-mysql
```

## 3. Vérifier
```bash
docker ps
docker logs kennel-container
```

## 4. Se connecter à MySQL
```bash
docker exec -it kennel-container mysql -u root -p
```
Mot de passe : `root123`

## 5. Vérifier la base
```sql
SHOW DATABASES;
USE kennelDB;
SHOW TABLES;

SELECT * FROM clients;
SELECT * FROM adresses;
SELECT * FROM clients_adresses;
SELECT * FROM chiens;
SELECT * FROM chats;
```

## 6. Vérifier les associations clients-adresses
```sql
SELECT c.nom, c.prenom, a.numero, a.rue, a.code_postal, a.commune
FROM clients c
JOIN clients_adresses ca ON c.id = ca.client_id
JOIN adresses a ON ca.adresse_id = a.id;
```

## Nettoyage
```bash
docker rm -f kennel-container
docker rmi kennel-mysql
```
