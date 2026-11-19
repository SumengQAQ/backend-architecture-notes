---- MODULE Outbox ----
EXTENDS Integers, FiniteSets, TLC

VARIABLES table, uid, before, after

vars ≜ ⟨table, uid, before, after⟩

CONSTANTS GOROUTINES 

Unprocessed ≜ "Unprocessed"
Fail ≜ "Fail"
Success ≜ "Success"
Dead ≜ "Dead"

MaxRetry ≜ 3

Constraint ≜ uid ≤ 5

Init ≜
    ∧ table = {}
    ∧ uid = 1
    ∧ before = [g ∈ GOROUTINES ↦ {}]
    ∧ after = [g ∈ GOROUTINES ↦ {}]

WriteEventToTable ≜
    ∧ table' = table ∪ {[uid ↦ uid, state ↦ Unprocessed, retry ↦ 0]}
    ∧ uid' = uid + 1
    ∧ UNCHANGED ⟨before, after⟩

ReadFromTable(goroutine) ≜
    \* 先把自己读过的处理完了也写完了，再来读下一波
    ∧ before[goroutine] = {} ∧ after[goroutine] = {}
    \* 等同于跳过加锁的行，只要Unprocessed或者Fail状态的事件
    ∧ before' = [before EXCEPT ![goroutine] = 
            {event ∈ table: 
                ¬(∃ g ∈ GOROUTINES:
                    (∃ x ∈ before[g]: x.uid = event.uid)
                    ∨ (∃ x ∈ after[g]: x.uid = event.uid))
                ∧ event.state ∈ {Unprocessed, Fail}
            }
        ]
    ∧ UNCHANGED ⟨table, uid, after⟩

Submit(goroutine) ≜
    ∧ before[goroutine] ≠ {}
    ∧ ∃ event ∈ before[goroutine]: 
        ∧ before' = [before EXCEPT ![goroutine] = @ \ {event}]
        ∧ ∃ ok ∈ BOOLEAN:
            ∧ IF    ok
              THEN  after' = [after EXCEPT ![goroutine] = @ ∪ {[event EXCEPT !.state = Success]}]
              ELSE  IF event.retry = MaxRetry
                    THEN  after' = [after EXCEPT ![goroutine] = @ ∪ {[event EXCEPT !.state = Dead]}]
                    ELSE  after' = [after EXCEPT ![goroutine] = @ ∪ {[event EXCEPT !.state = Fail, !.retry = @ + 1]}]
            ∧ UNCHANGED ⟨table, uid⟩

UpdateEventToTable(goroutine) ≜
    ∧ before[goroutine] = {} ∧ after[goroutine] ≠ {}
    \* 用新的状态换掉旧的状态
    ∧ table' = (table \ {event_in_table ∈ table: ∃ event_in_after ∈ after[goroutine]: event_in_table.uid = event_in_after.uid}) ∪ after[goroutine]
    ∧ after' = [after EXCEPT ![goroutine] = {}]
    ∧ UNCHANGED ⟨uid, before⟩


Next ≜
    ∨ WriteEventToTable
    ∨ ∃ g ∈ GOROUTINES:
        ∨ ReadFromTable(g)
        ∨ Submit(g)
        ∨ UpdateEventToTable(g)

Spec ≜
    ∧ Init
    ∧ [][Next]_vars
    ∧ WF_vars(WriteEventToTable)
    ∧ ∀ g ∈ GOROUTINES: WF_vars(ReadFromTable(g))
    ∧ ∀ g ∈ GOROUTINES: WF_vars(Submit(g))
    ∧ ∀ g ∈ GOROUTINES: WF_vars(UpdateEventToTable(g))

CannotReadTheSameOne ≜
    ∧ ∀ g1 ∈ GOROUTINES: ∀ g2 ∈ GOROUTINES \ {g1}: {x.uid: x ∈ before[g1]} ∩ {x.uid: x ∈ before[g2]} = {}
    ∧ ∀ g1 ∈ GOROUTINES: ∀ g2 ∈ GOROUTINES \ {g1}: {x.uid: x ∈ before[g1]} ∩ {x.uid: x ∈ after[g2]} = {}
    ∧ ∀ g1 ∈ GOROUTINES: ∀ g2 ∈ GOROUTINES \ {g1}: {x.uid: x ∈ after[g1]} ∩ {x.uid: x ∈ before[g2]} = {}
    ∧ ∀ g1 ∈ GOROUTINES: ∀ g2 ∈ GOROUTINES \ {g1}: {x.uid: x ∈ after[g1]} ∩ {x.uid: x ∈ after[g2]} = {}

SuccessOrDead ≜ ◇□(∀ event ∈ table: event.state ∈ {Success, Dead})
====
