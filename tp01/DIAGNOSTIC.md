# Diagnostic de shopapi:legacy

Image construite avec l'ancien Dockerfile (`shopapi/Dockerfile.legacy`).

## Taille / performance

**1. Image de 1,09 Go**
```
$ docker image ls shopapi:legacy
shopapi:legacy 1.09GB
```
C'est ce qui sature le registre, et chaque déploiement tire plus d'1 Go.

**2. Base ubuntu + Node installé à la main**
```
$ docker history shopapi:legacy
393MB   RUN apt-get install -y curl wget vim git build-essential python3
173MB   RUN apt-get install -y nodejs
87.7MB  ubuntu:22.04
```
L'image officielle `node` fait déjà tout ça, en bien plus léger, et le build dépend en plus de deb.nodesource.com.

**3. Outils inutiles en prod**
```
$ docker run --rm shopapi:legacy which vim git gcc python3 wget
/usr/bin/vim /usr/bin/git /usr/bin/gcc /usr/bin/python3 /usr/bin/wget
```
Du poids en plus, et un compilateur et wget à disposition d'un attaquant.

**4. Caches laissés dans l'image**
```
$ docker run --rm shopapi:legacy du -sh /var/lib/apt/lists /root/.npm
78M   /var/lib/apt/lists
34M   /root/.npm
```

**5. Cache de build invalidé à chaque commit**
```
$ echo "// commentaire" >> src/server.js && docker build -t shopapi:legacy .
[8/9] COPY . /app
[9/9] RUN npm install
```
4 s sans changement, 17 s après un simple commentaire (environ 4 min en CI) : `npm install` est rejoué à chaque fois.

**6. Dépendances de dev dans l'image**
```
$ docker run --rm shopapi:legacy sh -c 'ls node_modules | grep -E "^(eslint|nodemon)$"'
eslint
nodemon
```
En plus de `npm install -g nodemon` et de `NODE_ENV=development`.

**7. Rien n'est figé**
Pas de `package-lock.json`, et `apt-get install` comme `npm install -g` sans versions (hadolint DL3008, DL3016). Deux builds à quelques jours d'écart n'installent pas la même chose.

## Sécurité

**8. Tourne en root**
```
$ docker run --rm shopapi:legacy id
uid=0(root) gid=0(root) groups=0(root)
```

**9. Mot de passe de la base en ENV**
```
$ docker run --rm shopapi:legacy env | grep -i database
DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop
```
Visible aussi dans `docker history`. Toute personne qui tire l'image a le mot de passe de prod.

**10. Le .env est copié dans l'image**
```
$ docker run --rm shopapi:legacy cat /app/.env
AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE
```
`COPY . /app` sans `.dockerignore`.

**11. Dump de prod et fichiers inutiles**
```
$ docker run --rm shopapi:legacy ls /app
.env  .gitignore  Dockerfile  dump-prod-2024.sql  node_modules  package.json  src  test
```
Un dump de prod peut contenir des données clients.

## Exploitabilité

**12. Pas d'arrêt propre**
```
$ docker exec legacy-test ps -o pid,cmd -p 1
      1 /bin/sh -c npm start
$ docker stop legacy-test     -> 10,5 s, exit code 137
```
`CMD npm start` en forme shell : `sh` est le PID 1 et ne transmet pas SIGTERM à node. Docker attend 10 s puis tue le processus. D'où les rolling updates lentes.

**13. Pas de HEALTHCHECK**
```
$ docker inspect shopapi:legacy -f '{{json .Config.Healthcheck}}'
null
```
Alors que la route `/health` existe.

**14. Pas de labels OCI**
```
$ docker inspect shopapi:legacy -f '{{json .Config.Labels}}'
{"org.opencontainers.image.version":"22.04"}
```
Le seul label vient d'ubuntu, et sa version est fausse.

**15. hadolint : 6 warnings**
```
DL3008 x2  pin versions in apt-get install
DL4006     set -o pipefail (curl ... | bash -)
DL3016     pin versions in npm
DL3025     use JSON notation for CMD
```

dive (`CI=true dive shopapi:legacy`) ne trouve que 4 Mo de fichiers en double entre couches. Le problème n'est pas là, il est dans ce qui est installé et jamais nettoyé (points 3, 4 et 6).
