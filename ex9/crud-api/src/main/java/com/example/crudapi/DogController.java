package com.example.crudapi;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {

    private final DogRepository repository;

    public DogController(DogRepository repository) {
        this.repository = repository;
    }

    @GetMapping
    public List<Dog> getAllDogs() {
        return repository.findAll();
    }

    @GetMapping("/{dogId}")
    public Dog getDog(@PathVariable Long dogId) {
        return findDog(dogId);
    }

    @PostMapping
    public Dog createDog(@RequestBody Dog dog) {
        dog.id = null;
        return repository.save(dog);
    }

    @PutMapping("/{dogId}")
    public Dog updateDog(@PathVariable Long dogId, @RequestBody Dog dog) {
        Dog existing = findDog(dogId);
        existing.name = dog.name;
        existing.breed = dog.breed;
        existing.birthDate = dog.birthDate;
        existing.sterilized = dog.sterilized;
        return repository.save(existing);
    }

    @DeleteMapping("/{dogId}")
    public ResponseEntity<Void> deleteDog(@PathVariable Long dogId) {
        repository.delete(findDog(dogId));
        return ResponseEntity.noContent().build();
    }

    private Dog findDog(Long dogId) {
        return repository.findById(dogId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Chien " + dogId + " introuvable"));
    }
}
