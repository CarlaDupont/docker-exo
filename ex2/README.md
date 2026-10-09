# Exercice 2 — Jeu 2048 depuis DockerHub

Énoncé : `docker_support/docker_ynov_10_26/02_exercices_sujet/exercice-02.md`

> L'image `alexwhen/docker-2048` est trop ancienne :
> Docker 27+ refuse de la télécharger. On utilise l'image DockerHub `evilroot/docker-2048`

## 1. Trouver une image sur DockerHub

```bash
docker search 2048
```

ou sur https://hub.docker.com/r/evilroot/docker-2048

## 2. Récupérer l'image localement

```bash
docker pull evilroot/docker-2048
```

## 3. Lancer le conteneur sur le port hôte 8080

```bash
docker run -d --name jeu-2048 -p 8080:80 evilroot/docker-2048
```

Si le port 8080 est déjà utilisé :

```bash
docker run -d --name jeu-2048 -p 8090:80 evilroot/docker-2048
```

## 4. Ouvrir le jeu dans le navigateur de l'ordinateur

http://localhost:8080 (ou http://localhost:8090)

## Arrêter / supprimer

```bash
docker rm -f jeu-2048
```
