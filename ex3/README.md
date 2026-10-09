# Exercice 3 — Site web avec NGINX

## 1. Construire l'image
```bash
docker build -t exercice3 .
```

## 2. Lancer le conteneur
```bash
docker run -d --name exercice3-container -p 8080:80 exercice3
```

Si le port 8080 est déjà utilisé :
```bash
docker run -d --name exercice3-container -p 8081:80 exercice3
```

## 3. Vérifier
```bash
docker ps
```
http://localhost:8080

## Arrêter / supprimer
```bash
docker rm -f exercice3-container
```
