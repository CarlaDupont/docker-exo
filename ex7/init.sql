SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS kennelDB;
USE kennelDB;

CREATE TABLE clients (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nom VARCHAR(100),
    prenom VARCHAR(100),
    date_naissance DATE,
    pseudonyme VARCHAR(100)
);

CREATE TABLE adresses (
    id INT AUTO_INCREMENT PRIMARY KEY,
    numero INT,
    rue VARCHAR(150),
    code_postal VARCHAR(10),
    commune VARCHAR(100)
);

CREATE TABLE clients_adresses (
    client_id INT,
    adresse_id INT,
    PRIMARY KEY (client_id, adresse_id),
    FOREIGN KEY (client_id) REFERENCES clients(id),
    FOREIGN KEY (adresse_id) REFERENCES adresses(id)
);

CREATE TABLE chiens (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nom VARCHAR(100),
    date_naissance DATE,
    race VARCHAR(100),
    sterilise BOOLEAN
);

CREATE TABLE chats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nom VARCHAR(100),
    date_naissance DATE,
    race VARCHAR(100),
    sterilise BOOLEAN
);

INSERT INTO clients (nom, prenom, date_naissance, pseudonyme) VALUES
('Dupont', 'Alice', '1998-05-12', 'alice98'),
('Martin', 'Lucas', '1995-08-20', 'lucas95'),
('Bernard', 'Emma', '2000-03-15', 'emma2000');

INSERT INTO adresses (numero, rue, code_postal, commune) VALUES
(12, 'Rue de Paris', '59000', 'Lille'),
(25, 'Rue Nationale', '59300', 'Valenciennes'),
(8, 'Rue Victor Hugo', '62000', 'Arras');

INSERT INTO clients_adresses (client_id, adresse_id) VALUES
(1, 1),
(2, 2),
(3, 3);

INSERT INTO chiens (nom, date_naissance, race, sterilise) VALUES
('Rex', '2020-04-10', 'Berger Allemand', TRUE),
('Max', '2021-06-15', 'Labrador', FALSE),
('Rocky', '2019-09-22', 'Cocker', TRUE);

INSERT INTO chats (nom, date_naissance, race, sterilise) VALUES
('Milo', '2022-02-14', 'Maine Coon', FALSE),
('Luna', '2021-07-08', 'Siamois', TRUE),
('Nala', '2023-01-25', 'Européen', FALSE);
