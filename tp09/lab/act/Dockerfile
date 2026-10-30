# act (nektos/act) dans un conteneur : rien à installer sur le poste.
# Il lance les jobs du workflow dans des conteneurs, via la socket Docker.
FROM alpine:3.20.3
ARG ACT_VERSION=0.2.92
RUN apk add --no-cache git=2.45.4-r0 \
 && cd /tmp \
 && wget -q "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_x86_64.tar.gz" \
 && wget -q "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/checksums.txt" \
 && grep ' act_Linux_x86_64.tar.gz$' checksums.txt | sha256sum -c \
 && tar xzf act_Linux_x86_64.tar.gz -C /usr/local/bin act \
 && rm act_Linux_x86_64.tar.gz checksums.txt
WORKDIR /repo
ENTRYPOINT ["act"]
