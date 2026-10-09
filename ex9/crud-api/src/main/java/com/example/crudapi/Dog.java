package com.example.crudapi;

import jakarta.persistence.*;
import java.time.LocalDate;

@Entity
@Table(name = "dogs")
public class Dog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    public Long id;

    public String name;
    public String breed;
    public LocalDate birthDate;
    public boolean sterilized;
}
