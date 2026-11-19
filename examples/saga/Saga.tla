---- MODULE Saga ----
\* Saga 规约：正向按序执行，失败后逆序补偿。
\*
\* 三个要点：
\*   1. 空回滚、悬挂、幂等是"某一步"的异常，不是"某个节点"的，所以状态必须按 step 记
\*   2. 补偿的发起是逆序的，消息的到达是乱序的
\*   3. 判断一个 step 做没做过，只能看 step_state，不能看 inbox

EXTENDS Integers, FiniteSets, Bags

VARIABLES tx_type, last_step, node_to_step, order_to_step,
          inbox, cost, step_state, resource, will_do, will_undo, period

CONSTANTS NODES, STEPS

CanDoAll ≜ "CanDoAll"
NeedUndo ≜ "NeedUndo"

Doing ≜ "Doing"
Undoing ≜ "Undoing"
Finish ≜ "Finish"

Do ≜ "Do"
Undo ≜ "Undo"

Null ≜ "Null"
Done ≜ "Done"
Undone ≜ "Undone"

vars ≜ ⟨tx_type, last_step, node_to_step, order_to_step,
         inbox, cost, step_state, resource, will_do, will_undo, period⟩

RECURSIVE MergeSetToBag(_)
MergeSetToBag(nodes) ≜
    IF nodes = {}
    THEN EmptyBag
    ELSE LET node ≜ CHOOSE x ∈ nodes: TRUE
         IN SetToBag(node_to_step[node]) (+) MergeSetToBag(nodes \ {node})

RECURSIVE Enumerate(_, _)
Enumerate(S, i) ≜
    IF S = {}
    THEN ⟨⟩
    ELSE LET choice ≜ CHOOSE x ∈ S: TRUE
         IN  i :> choice @@ Enumerate(S \ {choice}, i + 1)

Range(f) ≜ {f[x]: x ∈ DOMAIN f}

\* 被节点认领的步骤。STEPS 里可以有没人认领的，等于这个场景用不到它
UsedSteps ≜ DOMAIN MergeSetToBag(NODES)

\* 按步骤找节点。能从 node_to_step 推出来，不单独占一个变量
StepToNode ≜ [s ∈ UsedSteps ↦ CHOOSE n ∈ NODES: s ∈ node_to_step[n]]

Init ≜
    \* 每个步骤最多属于一个节点，也可以谁都不属于；节点可以有零个或多个步骤
    ∧ node_to_step ∈ [NODES → SUBSET STEPS]
    ∧ MergeSetToBag(NODES) ≠ EmptyBag
    ∧ ∀ count ∈ Range(MergeSetToBag(NODES)): count = 1

    \* 只给用到的步骤标号
    ∧ order_to_step = Enumerate(UsedSteps, 1)

    \* 结局前置：要么全部成功，要么在第 last_step 步之后失败
    ∧ tx_type ∈ {CanDoAll, NeedUndo}
    ∧ IF    tx_type = NeedUndo
      THEN  ∧ last_step ∈ 1‥Cardinality(UsedSteps)
            ∧ will_undo = last_step
      ELSE  ∧ last_step = Cardinality(UsedSteps)
            ∧ will_undo = 0

    ∧ inbox = [node ∈ NODES ↦ {}]
    ∧ step_state = [step ∈ STEPS ↦ Null]
    ∧ resource = [step ∈ STEPS ↦ 2]
    ∧ cost = 0
    ∧ period = Doing
    ∧ will_do = 1

--------------------------------------------------------------------------
\* 协调者：按序发 Do，失败后逆序发 Undo
--------------------------------------------------------------------------

AdvanceDoing ≜
    \* ∧ period = Doing
    ∧ will_do ≤ last_step
    \* 上一步做完才能发下一步，第一步不用检查
    ∧ IF will_do = 1
        THEN TRUE
        ELSE step_state[order_to_step[will_do - 1]] ∈ {Done, Undone}
    ∧ LET step ≜ order_to_step[will_do]
      IN  ∧ ¬(∃ x ∈ inbox[StepToNode[step]]: x.type = Undo)
          ∧ inbox' = [inbox EXCEPT ![StepToNode[step]] =
              @ ∪ {[type |-> Do, step |-> step]}]
          ∧ will_do' = will_do + 1
          ∧ UNCHANGED ⟨tx_type, last_step, node_to_step,
                       order_to_step, cost, step_state, resource,
                       will_undo, period⟩

AdvanceUndoing ≜
    \* ∧ period ∈ {Doing, Undoing}
    ∧ tx_type = NeedUndo
    ∧ will_undo ≥ 1
    ∧ (will_do = last_step ∨ will_do = last_step + 1)
    \* 补偿也必须是串行的
    ∧ IF will_undo = last_step
        THEN TRUE
        ELSE step_state[order_to_step[will_undo + 1]] = Undone
    ∧ LET step ≜ order_to_step[will_undo]
      IN  ∧ ¬(∃ x ∈ inbox[StepToNode[step]]: x.type = Do)
          ∧ inbox' = [inbox EXCEPT ![StepToNode[step]] =
                @ ∪ {[type |-> Undo, step |-> step]}]
          ∧ will_undo' = will_undo - 1
          \* ∧ period' = Undoing
          ∧ UNCHANGED ⟨tx_type, last_step, node_to_step,
                       order_to_step, cost, step_state, resource, will_do, period⟩

AdvanceFinish ≜
    ∧ period ≠ Finish
    ∧ will_do = last_step + 1
    ∧ will_undo = 0
    ∧ ∀ node ∈ NODES: inbox[node] = {}
    ∧ period' = Finish
    ∧ UNCHANGED ⟨tx_type, last_step, node_to_step, order_to_step,
                 inbox, cost, step_state, resource,
                 will_do, will_undo⟩

--------------------------------------------------------------------------
\* 节点：处理收到的 Do / Undo
--------------------------------------------------------------------------

\* 响应对应 step 的 Do。
\* step_state = Null 才真正执行；Done 是重复消息（幂等），Undone 是悬挂。
ResponseDo(node) ≜
    ∃ row ∈ inbox[node]:
        ∧ row.type = Do
        ∧ inbox' = [inbox EXCEPT ![node] = @ \ {row}]
        ∧ IF step_state[row.step] = Null
            THEN ∧ step_state' = [step_state EXCEPT ![row.step] = Done]
                 ∧ resource' = [resource EXCEPT ![row.step] = @ - 1]
                 ∧ cost' = cost + 1
            ELSE ∧ UNCHANGED ⟨step_state, resource, cost⟩
        ∧ UNCHANGED ⟨tx_type, last_step, node_to_step, order_to_step,
                     will_do, will_undo, period⟩

\* 响应对应 step 的 Undo。
\* step_state = Done 时真正补偿；Null 是空回滚；Undone 是重复消息（幂等）。
ResponseUndo(node) ≜
    ∃ row ∈ inbox[node]:
        ∧ row.type = Undo
        ∧ inbox' = [inbox EXCEPT ![node] = @ \ {row}]
        ∧ IF step_state[row.step] = Done
            THEN ∧ step_state' = [step_state EXCEPT ![row.step] = Undone]
                 ∧ resource' = [resource EXCEPT ![row.step] = @ + 1]
                 ∧ cost' = cost - 1
            ELSE ∧ step_state' = [step_state EXCEPT ![row.step] = Undone]
                 ∧ UNCHANGED ⟨resource, cost⟩
        ∧ UNCHANGED ⟨tx_type, last_step, node_to_step, order_to_step,
                     will_do, will_undo, period⟩

--------------------------------------------------------------------------
\* 不变式
--------------------------------------------------------------------------

\* 每个步骤的资源不越界，而且和状态严格对应
ResourceBounded ≜
    ∀ step ∈ STEPS:
        ∧ resource[step] ∈ 1‥2
        ∧ (step_state[step] = Done ⇒ resource[step] = 1)
        ∧ (step_state[step] ≠ Done ⇒ resource[step] = 2)

\* 记账准确：cost 就是此刻处于 Done 的步骤数
CostExact ≜
    cost = Cardinality({step ∈ STEPS: step_state[step] = Done})

\* 走到 Finish 时，每个用到的步骤终态必须符合预选的结局
FinishShape ≜
    period = Finish ⇒
        ∀ i ∈ 1‥Cardinality(UsedSteps):
            LET step ≜ order_to_step[i]
            IN  IF tx_type = CanDoAll
                THEN step_state[step] = Done
                ELSE IF i ≤ last_step
                     THEN step_state[step] = Undone
                     ELSE step_state[step] = Null

\* 最终一定会走到 Finish
EventuallyFinish ≜ ◇(period = Finish)

Next ≜
    ∨ AdvanceDoing
    ∨ AdvanceUndoing
    ∨ AdvanceFinish
    ∨ ∃ node ∈ NODES:
        ∨ ResponseDo(node)
        ∨ ResponseUndo(node)

Spec ≜
    ∧ Init
    ∧ [][Next]_vars
    ∧ WF_vars(AdvanceDoing)
    ∧ WF_vars(AdvanceUndoing)
    ∧ WF_vars(AdvanceFinish)
    ∧ ∀ node ∈ NODES: WF_vars(ResponseDo(node))
    ∧ ∀ node ∈ NODES: WF_vars(ResponseUndo(node))

\* 看看是否有do和undo都到了，但是没处理的情况
\* 对于所有的node和step，这个step的do和undo不可能在Null的状态下同时存在
NoHandleDoAndUndo ≜
    ∀ node ∈ NODES: ∀ step ∈ STEPS: 
        ¬({[type ↦ Do, step ↦ step], [type ↦ Undo, step ↦ step]} ⊆ inbox[node] ∧ step_state[step] = Null)
\* State 3: <AdvanceUndoing line 99, col 5 to line 109, col 74 of module Saga>
\* /\ will_undo = 0
\* /\ tx_type = "NeedUndo"
\* /\ will_do = 2
\* /\ resource = [S1 |-> 2, S2 |-> 2, S3 |-> 2]
\* /\ period = "Undoing"
\* /\ cost = 0
\* /\ last_step = 1
\* /\ step_state = [S1 |-> "Null", S2 |-> "Null", S3 |-> "Null"]
\* /\ node_to_step = [N1 |-> {}, N2 |-> {"S1"}]
\* /\ inbox = [ N1 |-> {}, N2 |-> {[step |-> "S1", type |-> "Do"], [step |-> "S1", type |-> "Undo"]} ]
\* /\ order_to_step = <<"S1">>

\* S1怎么会收到了do和undo，但是一个都没处理呢？这和现实不符
\* 现在是do和undo可以同时到，但是可以选择先处理do或者先处理undo
====
