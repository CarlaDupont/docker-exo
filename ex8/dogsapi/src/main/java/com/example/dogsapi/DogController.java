package com.example.dogsapi;

import org.springframework.web.bind.annotation.*;
import org.springframework.http.ResponseEntity;
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
    public ResponseEntity<Dog> getDog(@PathVariable Long dogId) {
        return repository.findById(dogId)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @PostMapping
    public Dog createDog(@RequestBody Dog dog) {
        dog.id = null;
        return repository.save(dog);
    }

    @PutMapping("/{dogId}")
    public ResponseEntity<Dog> updateDog(
            @PathVariable Long dogId,
            @RequestBody Dog dog) {

        return repository.findById(dogId)
                .map(existing -> {
                    existing.name = dog.name;
                    existing.breed = dog.breed;
                    existing.birthDate = dog.birthDate;
                    existing.sterilized = dog.sterilized;
                    return ResponseEntity.ok(repository.save(existing));
                })
                .orElse(ResponseEntity.notFound().build());
    }

    @DeleteMapping("/{dogId}")
    public ResponseEntity<Void> deleteDog(@PathVariable Long dogId) {

        if (!repository.existsById(dogId)) {
            return ResponseEntity.notFound().build();
        }

        repository.deleteById(dogId);
        return ResponseEntity.noContent().build();
    }
}
