---- MODULE TCC ----
EXTENDS Integers, FiniteSets

VARIABLES mailbox, receive_can, state, resource, v_nodes, sended_try, sended_confirm, sended_cancel, cost

CONSTANTS NODES

vars ≜ ⟨mailbox, receive_can, state, resource, v_nodes, sended_try, sended_confirm, sended_cancel, cost⟩

Null ≜ "Null"
Try ≜ "Try"
Confirm ≜ "Confirm"
Cancel ≜ "Cancel"

Init ≜
    ∧ v_nodes = NODES
    ∧ mailbox = [node ∈ v_nodes ↦ {}]
    ∧ receive_can = {}
    ∧ state = [node ∈ v_nodes ↦ Null]
    ∧ resource = [node ∈ v_nodes ↦ [available ↦ 2, frozen ↦ 0]]
    ∧ sended_try = FALSE
    ∧ sended_confirm = FALSE
    ∧ sended_cancel = FALSE
    ∧ cost = 0


RECURSIVE SumAvailable(_), SumFrozen(_)

SumAvailable(nodes) ≜
    IF nodes = {} 
    THEN 0
    ELSE LET node ≜ CHOOSE n ∈ nodes: TRUE
         IN resource[node].available + SumAvailable(nodes \ {node})

SumFrozen(nodes) ≜
    IF nodes = {} 
    THEN 0
    ELSE LET node ≜ CHOOSE n ∈ nodes: TRUE
         IN resource[node].frozen + SumFrozen(nodes \ {node})

RequestTry ≜
    LET not_receive_can ≜ v_nodes \ receive_can
    IN
        ∧ not_receive_can ≠ {}
        ∧ mailbox' = [
                node ∈ v_nodes ↦ 
                IF node ∈ not_receive_can
                THEN mailbox[node] ∪ {Try}
                ELSE mailbox[node]
            ]
        ∧ sended_try' = TRUE
        ∧ UNCHANGED ⟨receive_can, state, resource, v_nodes, sended_confirm, sended_cancel, cost⟩

ResponseTry(node) ≜
    ∧ Try ∈ mailbox[node]
    ∧ state[node] = Null
    ∧ IF Cancel ∈ mailbox[node]
      THEN
            ∧ state' = [state EXCEPT ![node] = Cancel]
            ∧ UNCHANGED ⟨mailbox, receive_can, resource, v_nodes⟩
      ELSE
            ∧ receive_can' = receive_can ∪ {node}
            ∧ state' = [state EXCEPT ![node] = Try]
            ∧ resource' = [resource EXCEPT ![node].available = @ - 1, ![node].frozen = @ + 1]
            ∧ UNCHANGED ⟨mailbox, v_nodes⟩
    ∧ UNCHANGED ⟨sended_try, sended_confirm, sended_cancel, cost⟩

RequestConfirm ≜
    ∧ receive_can = v_nodes
    ∧ sended_try = TRUE ∧ sended_cancel = FALSE
    ∧ mailbox' = [node ∈ v_nodes ↦ mailbox[node] ∪ {Confirm}]
    ∧ sended_confirm' = TRUE
    ∧ UNCHANGED ⟨receive_can, state, resource, v_nodes, sended_try, sended_cancel, cost⟩

ResponseConfirm(node) ≜
    ∧ state[node] = Try
    ∧ Confirm ∈ mailbox[node]
    ∧ state' = [state EXCEPT ![node] = Confirm]
    ∧ cost' = cost + resource[node].frozen
    ∧ resource' = [resource EXCEPT ![node].frozen = 0]
    ∧ UNCHANGED ⟨receive_can, mailbox, v_nodes, sended_try, sended_confirm, sended_cancel⟩

RequestCancel ≜
    ∧ sended_try = TRUE ∧ sended_confirm = FALSE
    ∧ mailbox' = [node ∈ v_nodes ↦ mailbox[node] ∪ {Cancel}]
    ∧ sended_cancel' = TRUE
    ∧ UNCHANGED ⟨receive_can, state, resource, v_nodes, sended_try, sended_confirm, cost⟩

ResponseCancel(node) ≜
    ∧ Cancel ∈ mailbox[node]
    ∧ state[node] = Try
    ∧ state' = [state EXCEPT ![node] = Cancel]
    ∧ resource' = [resource EXCEPT ![node].available = @ + resource[node].frozen, ![node].frozen = 0]
    ∧ UNCHANGED ⟨receive_can, mailbox, v_nodes, sended_try, sended_confirm, sended_cancel, cost⟩

ResourceBounded ≜ 
    ∀ node ∈ v_nodes:
        ∧ resource[node].available ∈ 1‥2
        ∧ resource[node].frozen ∈ 0‥1

ResourceConservation ≜
    cost + SumAvailable(v_nodes) + SumFrozen(v_nodes) = Cardinality(v_nodes) * 2

StateStable ≜
    ∀ node ∈ NODES:
        node ∈ v_nodes ⇒ 
            ∧ (state[node] = Confirm   ⇒   □(state[node] = Confirm))
            ∧ (state[node] = Cancel    ⇒   □(state[node] = Cancel))

Liveness ≜
    ∨ ◇□(∀ node ∈ v_nodes: state[node] = Confirm)
    ∨ ◇□(∀ node ∈ v_nodes: state[node] = Cancel)

Next ≜
    ∨ RequestTry ∨ RequestConfirm ∨ RequestCancel
    ∨ ∃ node ∈ v_nodes:
        ∨ ResponseTry(node)
        ∨ ResponseConfirm(node)
        ∨ ResponseCancel(node)

Spec ≜
    ∧ Init
    ∧ [][Next]_vars
    ∧ WF_vars(RequestTry)
    ∧ WF_vars(RequestConfirm)
    ∧ WF_vars(RequestCancel)
    ∧ WF_vars(∃ node ∈ v_nodes: ResponseTry(node))
    ∧ WF_vars(∃ node ∈ v_nodes: ResponseConfirm(node))
    ∧ WF_vars(∃ node ∈ v_nodes: ResponseCancel(node))
====
