# foundational principles

* Encapsulation protects, abstraction hides, composition empowers.
* Inheritance and polymorphism enable extensibility


## Objects
* object has data (state) and behavior (methods).
* classes as contracts for collaboration.
![alt text](image.png)

## Encapsulation
* Protect What Matters - bundling data + logic and hiding internals
![alt text](image-1.png)

## Inheritance
* Reuse Through Extension
* Defines “is-a” relationship — a subclass extends base behavior

![alt text](image-2.png)

* Risk: tight coupling and fragile hierarchies.
* Keep inheritance shallow and meaningful

## Composition 
* Reuse Through Collaboration - use delegation!
* “Has-a” relationship — objects work together instead of inheriting.

![alt text](image-3.png)

![alt text](image-4.png)

* Encourages loose coupling and flexibility.
* Easier to modify or replace parts.

## Abstraction 
* Simplify the Complex
* Hides unnecessary detail; focuses on what, not how.
* Supports the Open/Closed Principle — extend without modifying.

![alt text](image-5.png)

![alt text](image-6.png)

## Polymorphism
* One Interface, Many Behaviors
* Allows different objects to respond differently to the same call.
* Decouples client code from concrete implementations.

![alt text](image-7.png)

## Relationships
* Association: one class uses another (temporary link).
* Aggregation: “has-a” but independent lifecycles.
* Composition: “owns” the part — lifecycle bound together.

![alt text](image-8.png)