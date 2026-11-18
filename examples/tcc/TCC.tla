---- MODULE TCC ----
\* TCC 规约：Try 冻结资源，Confirm 扣掉，Cancel 解冻。
\*
\* 三个设计点：
\*   1. 不建模超时。Cancel 可以在 Try 之后任意时刻发出，
\*      超时、业务失败、人工干预都归到这一条上。
\*   2. 消息按节点独立发送。A 可能是 Try 先到，B 可能是 Cancel 先到。
\*   3. 响应动作只看 mailbox 里有什么，不看消息到达的顺序。

EXTENDS Integers, FiniteSets

VARIABLES mailbox, state, resource, v_nodes, cost, tx_type

CONSTANTS NODES

vars ≜ ⟨mailbox, state, resource, v_nodes, cost, tx_type⟩

Null ≜ "Null"
Try ≜ "Try"
Confirm ≜ "Confirm"
Cancel ≜ "Cancel"

\* 初始：每个节点有 2 个单位资源，全部可用，没有冻结。
\* tx_type 表示这次全局事务最终要走 Confirm 还是 Cancel。
Init ≜
    ∧ v_nodes = NODES
    ∧ tx_type ∈ {"Confirm", "Cancel"}
    ∧ mailbox = [node ∈ v_nodes ↦ {}]
    ∧ state = [node ∈ v_nodes ↦ Null]
    ∧ resource = [node ∈ v_nodes ↦ [available ↦ 2, frozen ↦ 0]]
    ∧ cost = 0

--------------------------------------------------------------------------
\* 请求侧：协调者发消息，每个节点独立，顺序不限
--------------------------------------------------------------------------

\* 向某个节点发 Try。Try ∉ mailbox 保证同一节点只发一次
RequestTry(node) ≜
    ∧ Try ∉ mailbox[node]
    ∧ mailbox' = [mailbox EXCEPT ![node] = @ ∪ {Try}]
    ∧ UNCHANGED ⟨state, resource, v_nodes, cost, tx_type⟩

\* 向某个节点发 Cancel。只在 Cancel 分支，且不要求 Try 已经发过
RequestCancel(node) ≜
    ∧ tx_type = "Cancel"
    ∧ mailbox' = [mailbox EXCEPT ![node] = @ ∪ {Cancel}]
    ∧ UNCHANGED ⟨state, resource, v_nodes, cost, tx_type⟩

\* 向某个节点发 Confirm。只在 Confirm 分支，
\* 并且要求所有节点都已经收到 Try
RequestConfirm(node) ≜
    ∧ tx_type = "Confirm"
    ∧ (∀ n ∈ v_nodes: Try ∈ mailbox[n])
    ∧ mailbox' = [mailbox EXCEPT ![node] = @ ∪ {Confirm}]
    ∧ UNCHANGED ⟨state, resource, v_nodes, cost, tx_type⟩

--------------------------------------------------------------------------
\* 响应侧：节点处理 mailbox 里的消息
--------------------------------------------------------------------------

\* 响应 Try：available 挪 1 到 frozen。
\* guard 里的 state = Null 挡住两种情况：
\*   - 已经 Try 过（幂等）
\*   - 已经 Cancel 过（悬挂，Try 迟到不能再冻结）
ResponseTry(node) ≜
    ∧ Try ∈ mailbox[node]
    ∧ state[node] = Null
    ∧ state' = [state EXCEPT ![node] = Try]
    ∧ resource' = [resource EXCEPT
          ![node].available = @ - 1,
          ![node].frozen    = @ + 1]
    ∧ UNCHANGED ⟨mailbox, v_nodes, cost, tx_type⟩

\* 响应 Confirm：frozen 真正扣掉，记进 cost。
\* guard 要求 state = Try，没 Try 过的节点不会 Confirm
ResponseConfirm(node) ≜
    ∧ Confirm ∈ mailbox[node]
    ∧ state[node] = Try
    ∧ state' = [state EXCEPT ![node] = Confirm]
    ∧ cost' = cost + resource[node].frozen
    ∧ resource' = [resource EXCEPT ![node].frozen = 0]
    ∧ UNCHANGED ⟨mailbox, v_nodes, tx_type⟩

\* 响应 Cancel：frozen 还回 available。
\* guard 放宽到 state ∈ {Null, Try}：
\*   - state = Try：正常解冻
\*   - state = Null：Cancel 比 Try 先到，frozen 是 0，加 0 等于没动，
\*     只把状态改成 Cancel。这就是空回滚
ResponseCancel(node) ≜
    ∧ Cancel ∈ mailbox[node]
    ∧ state[node] ∈ {Null, Try}
    ∧ state' = [state EXCEPT ![node] = Cancel]
    ∧ resource' = [resource EXCEPT
          ![node].available = @ + resource[node].frozen,
          ![node].frozen    = 0]
    ∧ UNCHANGED ⟨mailbox, v_nodes, cost, tx_type⟩

--------------------------------------------------------------------------
\* 不变式与活性
--------------------------------------------------------------------------

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

\* 每个节点的资源不越界
ResourceBounded ≜
    ∀ node ∈ v_nodes:
        ∧ resource[node].available ∈ 1‥2
        ∧ resource[node].frozen ∈ 0‥1

\* 守恒：花掉的 + 能用的 + 冻结的 = 初始总量
ResourceConservation ≜
    cost + SumAvailable(v_nodes) + SumFrozen(v_nodes) = Cardinality(v_nodes) * 2

\* 终态不再变化
StateStable ≜
    ∀ node ∈ NODES:
        node ∈ v_nodes ⇒
            ∧ (state[node] = Confirm ⇒ □(state[node] = Confirm))
            ∧ (state[node] = Cancel  ⇒ □(state[node] = Cancel))

\* 最终所有节点收敛到同一个终态
Liveness ≜
    ∨ ◇□(∀ node ∈ v_nodes: state[node] = Confirm)
    ∨ ◇□(∀ node ∈ v_nodes: state[node] = Cancel)

--------------------------------------------------------------------------
\* 下一步关系
--------------------------------------------------------------------------

Next ≜
    ∃ node ∈ v_nodes:
        ∨ RequestTry(node)
        ∨ RequestConfirm(node)
        ∨ RequestCancel(node)
        ∨ ResponseTry(node)
        ∨ ResponseConfirm(node)
        ∨ ResponseCancel(node)

\* WF 用 NODES 而不是 v_nodes，因为时序公式里的量词域必须是常量
Spec ≜
    ∧ Init
    ∧ [][Next]_vars
    ∧ ∀ node ∈ NODES: WF_vars(RequestTry(node))
    ∧ ∀ node ∈ NODES: WF_vars(RequestConfirm(node))
    ∧ ∀ node ∈ NODES: WF_vars(RequestCancel(node))
    ∧ ∀ node ∈ NODES: WF_vars(ResponseTry(node))
    ∧ ∀ node ∈ NODES: WF_vars(ResponseConfirm(node))
    ∧ ∀ node ∈ NODES: WF_vars(ResponseCancel(node))
====
