---- MODULE Allocation ----
\* M 个物品分给 N 个人：每人至少一件，每件恰好分到一个人手里
EXTENDS Integers, FiniteSets, Bags

VARIABLES allocation
CONSTANTS Item, People

RECURSIVE MergeFuncRangeSetToBag(_)
MergeFuncRangeSetToBag(f) ≜
    IF DOMAIN f = {}
    THEN EmptyBag
    ELSE LET k ≜ CHOOSE k ∈ DOMAIN f: TRUE
         IN  SetToBag(f[k]) (+) MergeFuncRangeSetToBag([rest ∈ DOMAIN f \ {k} ↦ f[rest]])

Init ≜
    ∧ allocation ∈ [People → SUBSET Item]
    ∧ ∀ p ∈ People: allocation[p] ≠ {}
    ∧ LET allocation_bag ≜ MergeFuncRangeSetToBag(allocation)
      IN  ∧ DOMAIN allocation_bag = Item
          ∧ ∀ item ∈ Item: allocation_bag[item] = 1

Next ≜ UNCHANGED allocation

Spec ≜ Init ∧ □[Next]_allocation

\* 和 Init 里的约束说的是同一件事，换一种写法验证
StateOk ≜
    ∧ ∀ people ∈ People: allocation[people] ≠ {}
    ∧ ∀ item ∈ Item: ∀ p1 ∈ People: ∀ p2 ∈ People \ {p1}:
        ∨(item ∈ allocation[p1] ∧ item ∉ allocation[p2])
        ∨(item ∉ allocation[p1] ∧ item ∈ allocation[p2])
====
