# Exercice 6 — NGINX avec un volume

Port 8080 occupé, le site est sur le 8083.

## 1. Télécharger l'image
```bash
docker pull nginx:alpine
```

## 2. Lancer le conteneur depuis le dossier site-web
```powershell
cd site-web
docker run -d --name nginx-ex6 -p 8083:80 -v "${PWD}:/usr/share/nginx/html:ro" nginx:alpine
```

## 3. Vérifier
```bash
docker ps
```
http://localhost:8083

## 4. Modifier le site
Modifier `site-web/index.html` :
```html
<h1>Exercice Docker #6</h1>
<p>Mon site a été modifié sans reconstruire l'image Docker !</p>
```
Actualiser la page.

## 5. Arrêter
```bash
docker rm -f nginx-ex6
```
