FROM mysql:8.0

ENV MYSQL_ROOT_PASSWORD=root123
ENV MYSQL_DATABASE=kennelDB

COPY init.sql /docker-entrypoint-initdb.d/

EXPOSE 3306
