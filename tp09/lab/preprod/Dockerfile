# "Serveur" du TP (préprod et prod) : un moteur Docker (dind) joignable en SSH par l'utilisateur deploy.
FROM docker:27.3.1-dind
RUN apk add --no-cache openssh-server=9.7_p1-r5 openssh-client-default=9.7_p1-r5 rsync=3.4.3-r0 \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh deploy \
 && sed -i 's/^deploy:!/deploy:*/' /etc/shadow \
 && addgroup deploy docker \
 && mkdir -p /home/deploy/.ssh /srv/shop \
 && chown deploy:deploy /home/deploy/.ssh /srv/shop \
 && chmod 700 /home/deploy/.ssh \
 && printf 'PasswordAuthentication no\nPermitRootLogin no\nAllowUsers deploy\n' >> /etc/ssh/sshd_config
COPY --chmod=755 start.sh /usr/local/bin/start.sh
ENTRYPOINT ["start.sh"]
