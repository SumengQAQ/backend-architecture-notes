# TLA+ 中的语法与技巧

这个仓库不是教程，最基础的语法就不说了，直接说几个常用的手段。

## 常量转变量

比如想把常量变成可以枚举的变量：

```tla
VARIABLES Subset

CONSTANTS CompleteCollection

Init ≜
    ∧ Subset ∈ (SUBSET CompleteCollection) \ {{}}
```

读作 Subset 属于 CompleteCollection 的非空子集的集合，也就是 CompleteCollection 的一个非空子集。

注意是 `\ {{}}` 不是 `\ {}`。`\ {}` 减的是空集，等于没减，空集本身还是会被选中。要减掉"装着空集的那个集合"，得写 `{{}}`。

这样不用改常量，就能检验任意数量、任意配置的情况。

完整文件：[examples/tla+/Subset.tla](../examples/tla+/Subset.tla)

## 把 M 个物品分给 N 个人

每件物品只能分配一次，每个人至少要拿到一件，每件物品都必须分出去。

多重集可以约束这一点：

```tla
EXTENDS Bags

VARIABLES allocation

CONSTANTS Item, People

RECURSIVE MergeFuncRangeSetToBag(_)
MergeFuncRangeSetToBag(f) ≜
    IF DOMAIN f = {}
    THEN EmptyBag
    ELSE LET k ≜ CHOOSE k ∈ DOMAIN f: TRUE
         IN  SetToBag(f[k]) (+) MergeFuncRangeSetToBag([rest ∈ DOMAIN f \ {k} ↦ f[rest]])

Init ≜
    ∧ allocation ∈ [People → SUBSET Item / {{}}]
    ∧ LET allocation_bag ≜ MergeFuncRangeSetToBag(allocation)
      IN  ∧ DOMAIN allocation_bag = Item
          ∧ ∀ item ∈ Item: allocation_bag[item] = 1
```

`allocation` 是一个映射，键是 People，值是 Item 的子集。三条约束：

1. 每个人对应的值不为空集合
2. 按值域合并成多重集之后，定义域等于 Item，也就是全部 Item 都分出去了
3. 每个 item 在多重集里只出现一次，也就是没有两个人拿到同一个 item

换个写法直接检查：

```tla
StateOk ≜
    ∧ ∀ people ∈ People: allocation[people] ≠ {}
    ∧ ∀ item ∈ Item: ∃ p1 ∈ People:
        item ∈ allocation[p1] ∧ ∀ p2 ∈ People \ {p1}: item ∉ allocation[p2]
```

每个 item 找到一个人拿着它，其他所有人都不拿。

中间试过一版写成"任意两个人里恰好一个人拿"：

```tla
∀ item ∈ Item: ∀ p1 ∈ People: ∀ p2 ∈ People \ {p1}:
    ∨ (item ∈ allocation[p1] ∧ item ∉ allocation[p2])
    ∨ (item ∉ allocation[p1] ∧ item ∈ allocation[p2])
```

两个人时碰巧对，三个人就崩了。物品分给 A 之后，B 和 C 这一对谁都没拿，两个分支全假，不变式直接违反。

"恰好一个人拿"这件事，得先把那个人找出来，再排除其他人。`∃` 负责找，`∀` 负责排除。

更早还写过 `¬(∃ item: ∃ p1, p2: item ∈ allocation[p1] ∧ item ∈ allocation[p2])`，那个只挡住"两个人同时拿"，没挡住"谁都没拿"。

`Init` 里那三条约束和 `StateOk` 是同一件事的两种写法。前者在构造初始状态时限制取值，后者拿来当不变式检查。它们限制的是同一个集合，所以互换也成立。

完整文件：[examples/tla+/Allocation.tla](../examples/tla+/Allocation.tla)

## 状态空间切分

写规约的时候经常碰到这种情况：

> 这个东西可能成功也可能失败，如果成功的话就要……如果失败的话就要……

这时候可以把结局在 Init 里固定下来，分几次验证，复杂度会低不少。

以 TCC 为例：

- 成功的时候，事务管理器只需要向所有节点先发 Try，再发 Confirm
- 失败的时候，Try 和 Cancel 的到达顺序任意。先 Try 后 Cancel 对应正常冻结解冻，先 Cancel 后 Try 对应空回滚和悬挂

这样复杂度一下子就降下来了，不用建模怎么超时、怎么重试、怎么从 Success 变成 Fail。

```text
Success ≜ "Success"
Fail ≜ "Fail"

Init ≜
    ∧ tx_type ∈ {Success, Fail}

SendTry(node) ≜       # 无条件地向 node 发送 Try
SendCancel(node) ≜    # 仅当 tx_type = Fail 时，向 node 发送 Cancel
SendConfirm(node) ≜   # 当 tx_type = Success ∧ ∀ n ∈ NODES: state[n] = Try 时，向 node 发送 Confirm
```

`tx_type = Fail` 的时候，SendTry 和 SendCancel 之间没有顺序限制，模型检查器会把两种交错都跑一遍，于是正常冻结解冻、空回滚、悬挂三条路径都覆盖到了。

前提是这些状态互斥（按 `tx_type` 分支之后）且穷尽。

如果像 Outbox 那样，状态之间是连续的，很难切开，就别用这个办法。

而且切分只降低建模的复杂度。公共前缀会被重复搜索，总状态数不一定更少。

具体实现见 [TCC：用状态机处理三类异常](../02-distributed-tx/01-tcc.md)。

## 强弱公平性

这块确实比较难理解，先看定义：

```tla
SF(func, var) ≜ □◇(ENABLE ⟨func⟩_var) ⇒ □◇(⟨func⟩_var)
WF(func, var) ≜ ◇□(ENABLE ⟨func⟩_var) ⇒ □◇(⟨func⟩_var)
```

SF 说的是，如果一个动作能无限多次地执行，那它就必须无限多次地执行。

WF 说的是，如果一个动作从某一刻起一直可执行，那它就必须无限多次地执行。

所以 SF ⇒ WF。

公平性不是在推动状态往前走，它是对路径的过滤。比如：

```tla
AddOne ≜
    ∧ a ≤ 10
    ∧ a' = a + 1
```

一条路径上只要前置条件满足过、却一直不触发 AddOne，这条路径就被 WF 滤掉了。

```tla
Once ≜
    ∧ flag = FALSE
    ∧ flag' = TRUE
```

同理。只要是从某个时间点开始一直可以执行、却一直不执行，都受 WF 约束。

再看一个例子：

```tla
Reversal ≜ flag' = ~flag

Run ≜
    ∧ flag
    ∧ count' = count + 1
```

对 Run 施加 WF，意思是 flag 一直为 True 的话，Run 至少要执行一次。

对 Run 施加 SF，意思是即使 flag 一直在翻转，Run 也至少要执行一次。

当然这只是规约上的写法，实际还要靠工程手段去实现。

## 探针

> 我期望在 A 的情况下，系统还能保持 B（安全性/活性）。但是 no errors 是真的出现了 A 状态且系统还能保持 B，还是根本没出现 A 状态？

所以要写反向不变式，去检验 A 到底存不存在。

比如 [Saga：补偿不是回滚](../02-distributed-tx/02-saga.md) 里，用反向不变式检验最后一步有没有空回滚和悬挂，期望它被违反。

## 超组合

> 这块我只是了解，没有实现过。

以上在只有一个实例的时候都跑得通，但是一个系统不可能只有一个实例。多个实例配合工作会不会互相打架？配合之后对外呈现的行为和单个实例一样吗？这就是超组合要解决的问题。

举个最小的例子。两个 worker 共用一个任务队列。

单个 worker 的规约里，"看一眼"和"拿走"是一个原子动作，每个任务只会被取一次。可现实里这两个动作是分开的，中间隔着网络和调度。

```tla
LookA ≜ ∧ a = {}
        ∧ a' = queue
        ∧ UNCHANGED ⟨queue, b⟩

TakeA ≜ ∧ a ≠ {}
        ∧ queue' = queue \ a
        ∧ UNCHANGED ⟨a, b⟩
```

两个 worker 交错跑一遍：

```
A 看：queue = {1, 2}   a = {1, 2}
B 看：queue 还是 {1, 2}  b = {1, 2}
A 拿：queue = {}
B 拿：queue 还是 {}
```

任务 1 和 2 都被做了两遍。不变量 `∀ j: ¬(j ∈ a ∧ j ∈ b)` 被违反。

单个 worker 是对的，两个拼起来就不对了。验证一个实例的性质，推不出组合之后的性质，所以组合得单独看。

完整文件：[examples/tla+/TwoWorkers.tla](../examples/tla+/TwoWorkers.tla)。`OnlyOnce` 是故意拿来被违反的，跑起来应该报错。

超组合其实不难想到。要支持水平扩容，就一定会有多个协程同时跑，那就得考虑怎么编排它们。

## 函数与操作符

函数用方括号，操作符用圆括号。看着只是写法不同，行为差挺多。

| 特性 | 函数 `Factorial[n \in Nat]` | 操作符 `Factorial(n)` |
|---|---|---|
| 语法 | 方括号，必须带 `\in 集合` | 圆括号，只接变量名 |
| `DOMAIN` | 有，`DOMAIN Factorial = Nat` | 没有 |
| 越界调用 | TLC 报错，不在定义域内 | 照常代入公式展开 |
| 递归 | 原生支持 | 必须显式写 `RECURSIVE` |
| 缓存 | 有限域会预计算 | 每次重新展开 |

要"定义域"这个概念就用函数，只是想把公式抽出来复用就用操作符。

## CHOOSE 与 ∃

写状态迁移的时候，这两个选错了会漏状态。

| | `CHOOSE x \in S : P(x)` | `\E x \in S : P(x)` |
|---|---|---|
| 本质 | 表达式，返回一个具体的值 | 布尔公式，判断存不存在 |
| 会不会探索分支 | 不会，只走选中的那条 | 会，所有满足条件的 x 都展开 |
| 用在哪 | 辅助函数、提取唯一解 | 并发竞争、随机选择、丢包 |

`S = {1, 2}`，要让系统随便选一个赋给 `v`：

```tla
\* 只检查 v = 1，v = 2 那个分支整个丢了
v' = CHOOSE x \in S : TRUE

\* 两个分支都生成
\E x \in S : v' = x
```

