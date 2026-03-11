# low level design

High-level design shapes architecture — but low-level design shapes quality

![alt text](image.png)

![alt text](image-1.png)

LLD translates high-level architecture into class-level, method-level, and
interaction-level design.

![alt text](image-2.png)

## core blocks

* Components: Logical groupings that deliver a cohesive function.
* Modules: Collections of related classes forming functional units.
* Interfaces: Define contracts; separate behavior from implementation.
* Abstraction Layers: Manage complexity and isolate change.
* Responsibilities: Each unit should have one clear reason to change (SRP).


![alt text](image-3.png)

## Relationships

* Dependency: One module uses another — minimize directionality.
* Association & Composition: Define ownership and lifecycle strength.
* Coupling: Keep modules loosely connected via abstractions.
* Cohesion: Group related logic tightly within the same module.

![alt text](image-4.png)

![alt text](image-5.png)