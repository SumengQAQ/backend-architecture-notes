---- MODULE TwoWorkers ----
EXTENDS Integers, FiniteSets

VARIABLES queue, a, b

Init ≜ ∧ queue = {1, 2}
       ∧ a = {}
       ∧ b = {}

LookA ≜ ∧ a = {}
        ∧ a' = queue
        ∧ UNCHANGED ⟨queue, b⟩

TakeA ≜ ∧ a ≠ {}
        ∧ queue' = queue \ a
        ∧ UNCHANGED ⟨a, b⟩

LookB ≜ ∧ b = {}
        ∧ b' = queue
        ∧ UNCHANGED ⟨queue, a⟩

TakeB ≜ ∧ b ≠ {}
        ∧ queue' = queue \ b
        ∧ UNCHANGED ⟨a, b⟩

Next ≜ ∨ LookA ∨ TakeA ∨ LookB ∨ TakeB

Spec ≜ Init ∧ □[Next]_⟨queue, a, b⟩

OnlyOnce ≜ ∀ j ∈ {1, 2}: ¬(j ∈ a ∧ j ∈ b)
====
