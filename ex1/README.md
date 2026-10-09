# Exercice 1 — Ubuntu + NGINX

## 1. Créer un conteneur Ubuntu et entrer dedans
```bash
docker run -it --name ubuntu-ex1 ubuntu bash
```

## 2. Mettre à jour les paquets et installer NGINX
```bash
apt-get update
apt-get install -y nginx
nginx -v
```

## 3. Sortir du conteneur
```bash
exit
```

## 4. Sauvegarder le conteneur en image
```bash
docker commit ubuntu-ex1 ubuntu-nginx
docker images ubuntu-nginx
```

## 5. Tester l'image
```bash
docker run -d --name test-ubuntu-nginx -p 8081:80 ubuntu-nginx nginx -g "daemon off;"
```
http://localhost:8081

## Nettoyage
```bash
docker rm -f ubuntu-ex1 test-ubuntu-nginx
```

## Variante avec Dockerfile
```bash
docker build -t ubuntu-nginx-dockerfile .
```
