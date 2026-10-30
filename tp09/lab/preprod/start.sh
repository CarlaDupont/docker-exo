#!/bin/sh
# clé publique autorisée, montée en lecture seule par le compose du labo
install -o deploy -g deploy -m 600 /run/lab/authorized_keys /home/deploy/.ssh/authorized_keys
/usr/sbin/sshd
# socket unix seulement (sans --host, l'image ouvre aussi le port 2375 sans authentification),
# au groupe docker : deploy pilote le moteur sans être root
exec dockerd-entrypoint.sh dockerd --host=unix:///var/run/docker.sock --group docker
