# Exercice 4 — Communication entre deux conteneurs

## 1. Créer un réseau
```bash
docker network create reseau-ex4
```

## 2. Créer le premier conteneur
```bash
docker run -dit --name conteneur1 --network reseau-ex4 ubuntu bash
```

## 3. Installer ping
```bash
docker exec -it conteneur1 bash
apt update
apt install iputils-ping -y
exit
```

## 4. Sauvegarder l'image
```bash
docker commit conteneur1 ubuntu-ping
```

## 5. Créer le deuxième conteneur
```bash
docker run -dit --name conteneur2 --network reseau-ex4 ubuntu-ping bash
```

## 6. Vérifier le réseau
```bash
docker network inspect reseau-ex4
```
Si besoin : `docker network connect reseau-ex4 conteneur2`

## 7. Tester la communication
```bash
docker exec -it conteneur1 ping -c 4 conteneur2
docker exec -it conteneur2 ping -c 4 conteneur1
```

## Nettoyage
```bash
docker rm -f conteneur1 conteneur2
docker network rm reseau-ex4
docker rmi ubuntu-ping
```
