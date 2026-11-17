---- MODULE TCC ----
EXTENDS Integers, FiniteSets

VARIABLES mailbox, receive_can, state, resource, v_nodes, sended_try, sended_confrim, sended_cancel

CONSTANTS NODES

vars ≜ ⟨mailbox, receive_can, state, resource, v_nodes, sended_try, sended_confrim, sended_cancel⟩

Null ≜ "Null"
Try ≜ "Try"
Confrim ≜ "Confrim"
Cancel ≜ "Cancel"

Init ≜
    ∧ v_nodes = NODES
    ∧ mailbox = [node ∈ v_nodes ↦ {}]
    ∧ receive_can = {}
    ∧ state = [node ∈ v_nodes ↦ Null]
    ∧ resource = [node ∈ v_nodes ↦ 0]
    ∧ sended_try = FALSE
    ∧ sended_confrim = FALSE
    ∧ sended_cancel = FALSE

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
        ∧ UNCHANGED ⟨receive_can, state, resource, v_nodes, sended_confrim, sended_cancel⟩

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
            ∧ resource' = [resource EXCEPT ![node] = @ - 1]
            ∧ UNCHANGED ⟨mailbox, v_nodes⟩
    ∧ UNCHANGED ⟨sended_try, sended_confrim, sended_cancel⟩

RequestConfrim ≜
    ∧ receive_can = v_nodes
    ∧ sended_try = TRUE ∧ sended_cancel = FALSE
    ∧ mailbox' = [node ∈ v_nodes ↦ mailbox[node] ∪ {Confrim}]
    ∧ sended_confrim' = TRUE
    ∧ UNCHANGED ⟨receive_can, state, resource, v_nodes, sended_try, sended_cancel⟩

ResponseConfrim(node) ≜
    ∧ state[node] = Try
    ∧ Confrim ∈ mailbox[node]
    ∧ state' = [state EXCEPT ![node] = Confrim]
    ∧ resource' = [resource EXCEPT ![node] = @ + 1]
    ∧ UNCHANGED ⟨receive_can, mailbox, v_nodes, sended_try, sended_confrim, sended_cancel⟩

RequestCancel ≜
    ∧ sended_try = TRUE ∧ sended_confrim = FALSE
    ∧ mailbox' = [node ∈ v_nodes ↦ mailbox[node] ∪ {Cancel}]
    ∧ sended_cancel = TRUE
    ∧ UNCHANGED ⟨receive_can, state, resource, v_nodes, sended_try, sended_confrim⟩

ResponseCancel(node) ≜
    ∧ Cancel ∈ mailbox[node]
    ∧ state[node] = Try
    ∧ state' = [state EXCEPT ![node] = Cancel]
    ∧ resource' = [resource EXCEPT ![node] = @ + 1]
    ∧ UNCHANGED ⟨receive_can, mailbox, v_nodes, sended_try, sended_confrim, sended_cancel⟩

ResourceBounded ≜ ∀ node ∈ v_nodes: resource[node] >= -1 /\ resource[node] <= 0

StateStable ≜
    ∀ node ∈ NODES:
        IF node ∈ v_nodes
        THEN (state[node] = Confrim ⇒ □(state[node] = Confrim))
             ∧ (state[node] = Cancel ⇒ □(state[node] = Cancel))
        ELSE TRUE

Liveness ≜
    ∧ ◇□(∀ node ∈ v_nodes: resource[node] = 0)
    ∧ ∨ ◇□(∀ node ∈ v_nodes: state[node] = Confrim)
      ∨ ◇□(∀ node ∈ v_nodes: state[node] = Cancel)

Next ≜
    ∨ RequestTry ∨ RequestConfrim ∨ RequestCancel
    ∨ ∃ node ∈ v_nodes:
        ∨ ResponseTry(node)
        ∨ ResponseConfrim(node)
        ∨ ResponseCancel(node)

Spec ≜
    ∧ Init
    ∧ [][Next]_vars
    ∧ WF_vars(RequestTry)
    ∧ WF_vars(RequestConfrim)
    ∧ WF_vars(RequestCancel)
    ∧ WF_vars(∃ node ∈ v_nodes: ResponseTry(node))
    ∧ WF_vars(∃ node ∈ v_nodes: ResponseConfrim(node))
    ∧ WF_vars(∃ node ∈ v_nodes: ResponseCancel(node))
====
